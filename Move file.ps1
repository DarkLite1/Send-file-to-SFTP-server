﻿#Requires -Version 7
#Requires -Modules Posh-SSH

<#
.SYNOPSIS
    Move files to or from an SFTP server.

.DESCRIPTION
    Move files to or from an SFTP server.

    To avoid file locks:
    1. Rename the source file on the SFTP server
       from 'a.txt' to 'a.txt.PartialFileExtension'
        > when a file can't be renamed it is locked
        > then we wait a few seconds for an unlock and try again
    2. Download 'a.txt.PartialFileExtension' from the SFTP server
    3. Remove the file on the SFTP server
    4. Rename the file from 'a.txt.PartialFileExtension' to 'a.txt'
       in the download folder

.PARAMETER Paths
    Lost of source and destination folders.

.PARAMETER SftpComputerName
    The URL where the SFTP server can be reached.

.PARAMETER SftpPath
    Path to th folder on the SFTP server.

.PARAMETER SftpUserName
    The user name used to authenticate to the SFTP server.

.PARAMETER SftpPassword
    The password used to authenticate to the SFTP server.

.PARAMETER SftpOpenSshKeyFile
    The password used to authenticate to the SFTP server. This is an
    SSH private key file in the OpenSSH format converted to an array of strings.

.PARAMETER FileExtensions
    Only the files with a matching file extension will be downloaded. If blank,
    all files will be downloaded.

.PARAMETER OverwriteFile
    When a file that is being downloaded is already present with the same name
    it will be overwritten when OverwriteFile is TRUE.

.PARAMETER RemoveFailedPartialFiles
    When the download process is interrupted, it is possible that files are not
    completely downloaded and that there are sill partial files present on the
    SFTP server or in the local folder.

    When RemoveFailedPartialFiles is TRUE these partial files will be removed
    before the script starts. When RemoveFailedPartialFiles is FALSE, manual
    intervention will be required to decide to still download the partial file
    found on the SFTP server, to rename the partial file on the local system,
    or to simply remove the partial file(s).
#>

[CmdLetBinding()]
Param (
    [Parameter(Mandatory)]
    [String]$SftpComputerName,
    [Parameter(Mandatory)]
    [String]$SftpUserName,
    [Parameter(Mandatory)]
    [HashTable[]]$Paths,
    [Parameter(Mandatory)]
    [Int]$MaxConcurrentJobs,
    [SecureString]$SftpPassword,
    [String[]]$SftpOpenSshKeyFile,
    [String[]]$FileExtensions,
    [Boolean]$OverwriteFile,
    [Boolean]$RemoveFailedPartialFiles,
    [Int]$RetryCountOnLockedFiles = 3,
    [Int]$RetryWaitSeconds = 3,
    [hashtable]$PartialFileExtension = @{
        Upload   = 'UploadInProgress'
        Download = 'DownloadInProgress'
    }
)

try {
    #region Set defaults
    # workaround for https://github.com/PowerShell/PowerShell/issues/16894
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'
    #endregion

    Function Open-SftpSessionHM {
        <#
        .SYNOPSIS
            Open an SFTP session to the SFTP server
        #>

        try {
            #region Create credential
            Write-Verbose 'Create SFTP credential'

            $params = @{
                TypeName     = 'System.Management.Automation.PSCredential'
                ArgumentList = $SftpUserName, $SftpPassword
            }
            $sftpCredential = New-Object @params
            #endregion

            #region Open SFTP session
            Write-Verbose 'Open SFTP session'

            $params = @{
                ComputerName = $SftpComputerName
                Credential   = $sftpCredential
                AcceptKey    = $true
                Force        = $true
            }

            if ($SftpOpenSshKeyFile) {
                $params.KeyString = $SftpOpenSshKeyFile
            }

            New-SFTPSession @params
            #endregion
        }
        catch {
            $M = "Failed creating an SFTP session to '$SftpComputerName': $_"
            $Error.RemoveAt(0)
            throw $M
        }
    }

    $downloadPaths, $uploadPaths = $Paths.where(
        { $_.Source -like 'sftp*' }, 'Split'
    )

    if ($downloadPaths) {
        Write-Verbose "Paths.Source contains $($downloadPaths.Count) SFTP folders to download files"

        $sftpSession = Open-SftpSessionHM
    }

    if ($uploadPaths) {
        Write-Verbose "Paths.Source contains $($uploadPaths.Count) folders to upload files"

        $pathsWithFilesToUpload = @()

        foreach ($path in $uploadPaths) {
            Write-Verbose "Source folder '$($path.Source)'"

            #region Test source folder exists
            Write-Verbose 'Test if source folder exists'

            if (-not (
                    Test-Path -LiteralPath $path.Source -PathType 'Container')
            ) {
                [PSCustomObject]@{
                    Source      = $path.Source
                    Destination = $path.Destination
                    FileName    = $null
                    FileLength  = $null
                    DateTime    = Get-Date
                    Action      = @()
                    Error       = "Source folder '$($path.Source)' not found"
                }

                Continue
            }
            #endregion

            #region Test if there are files to upload
            Write-Verbose 'Test if there are files in the source folder'

            $filesToUpload = Get-ChildItem -LiteralPath $path.Source -File

            if ($FileExtensions) {
                $filesToUpload = $filesToUpload | Where-Object {
                    $FileExtensions -contains $_.Extension
                }
            }

            if ($filesToUpload) {
                Write-Verbose "Found $($filesToUpload.Count) files to upload"
                $pathsWithFilesToUpload += $path
            }
            #endregion
        }

        if (-not $pathsWithFilesToUpload) {
            Write-Verbose 'No files in source folder'
            Write-Verbose 'Exit script'
            exit
        }

        if (-not $sftpSession) {
            $sftpSession = Open-SftpSessionHM
        }

        $scriptBlock = {
            try {
                $path = $_

                #region Declare variables for code running in parallel
                if (-not $MaxConcurrentJobs) {
                    $ErrorActionPreference = $using:ErrorActionPreference
                    $ProgressPreference = $using:ProgressPreference
                    $sftpSession = $using:sftpSession
                    $FileExtensions = $using:FileExtensions
                }
                #endregion

                #region Get files to upload
                Write-Verbose "Get files in folder '$($path.Source)'"

                $allFiles = Get-ChildItem -LiteralPath $path.Source -File

                $filesToUpload = if ($FileExtensions) {
                    Write-Verbose "Only include files with extension '$FileExtensions'"

                    $allFiles.where({ $FileExtensions -contains $_.Extension })
                }
                else {
                    $allFiles
                }

                if (-not $filesToUpload) {
                    Write-Verbose 'No files to upload'
                    Continue
                }
                #endregion

                $sessionParams = @{
                    SessionId = $sftpSession.SessionID
                }

                $sftpPath = $path.Destination.TrimStart('sftp:')

                #region Test SFTP path exists
                Write-Verbose "Test SFTP path '$sftpPath' exists"

                if (-not (Test-SFTPPath @sessionParams -Path $sftpPath)) {
                    throw "Path '$sftpPath' not found on SFTP server"
                }
                #endregion
            }
            catch {
                [PSCustomObject]@{
                    DateTime    = Get-Date
                    Source      = $path.Source
                    Destination = $path.Destination
                    FileName    = $null
                    FileLength  = $null
                    Action      = $null
                    Error       = $_
                }
                $Error.RemoveAt(0)
            }
        }

        #region Run code serial or parallel
        $foreachParams = if ($MaxConcurrentJobs -eq 1) {
            @{
                Process = $scriptBlock
            }
        }
        else {
            @{
                Parallel      = $scriptBlock
                ThrottleLimit = $MaxConcurrentJobs
            }
        }

        Write-Verbose "Execute $($uploadPaths.Count) SFTP upload jobs"

        $pathsWithFilesToUpload | ForEach-Object @foreachParams

        Write-Verbose 'All upload jobs finished'
        #endregion
    }
}
catch {
    $M = $_
    Write-Warning $M
    $Error.RemoveAt(0)
    throw $M
}
finally {
    #region Close SFTP session
    if ($sessionParams.SessionID) {
        Write-Verbose 'Close SFTP session'

        $params = @{
            SessionId   = $sessionParams.SessionID
            ErrorAction = 'Ignore'
        }
        $null = Remove-SFTPSession @params
    }
    #endregion
}
