#Requires -Modules Pester
#Requires -Modules Toolbox.EventLog, Toolbox.HTML
#Requires -Version 5.1

BeforeAll {
    $testData = @(
        [PSCustomObject]@{
            Name     = 'file b.pdf'
            FullName = '/folder/file b.pdf'
        }
    )

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        Path             = (New-Item 'TestDrive:/a.txt' -ItemType 'Directory').FullName
        SftpComputerName = 'PC1'
        SftpPath         = '/out'
        SftpUserName     = 'bob'
        SftpPassword     = 'pass' | ConvertTo-SecureString -AsPlainText -Force
    }

    Mock New-SFTPSession {
        [PSCustomObject]@{
            SessionID = 1
        }
    }
    Mock Test-SFTPPath {
        $true
    }
    Mock Remove-SFTPSession
    Mock Remove-SFTPItem
    Mock Get-SFTPChildItem
    Mock Get-SFTPItem
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach @(
        'Path',
        'SftpComputerName', 
        'SftpUserName', 
        'SftpPassword', 
        'SftpPath'
    ) {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory | 
        Should -BeTrue
    }
}
Describe 'generate an error when' {
    It 'authentication to the SFTP server fails' {
        Mock New-SFTPSession {
            throw 'Failed authenticating'
        }

        $testResult = .$testScript @testParams

        $testResult.Error | Should -Be "Failed creating an SFTP session to '$($testParams.SftpComputerName)': Failed authenticating"
    }
    It 'the path on the SFTP server does not exist' {
        Mock Test-SFTPPath {
            $false
        }

        $testResult = .$testScript @testParams

        $testResult.Error | Should -Be "Path '$($testParams.SftpPath)' not found on SFTP server"
    }
    It 'Path does not exist and ErrorWhenPathIsNotFound is true' {      
        $testNewParams = $testParams.Clone()
        $testNewParams.Path = 'c:\doesNotExist'
        $testNewParams.ErrorWhenPathIsNotFound = $true

        $testResult = .$testScript @testNewParams

        $testResult.Error | 
        Should -Be "Download folder '$($testNewParams.Path)' not found"
    }
    It 'the SFTP file list could bot be retrieved' {
        Mock Get-SFTPChildItem {
            throw 'Failed getting list'
        }

        $testResult = .$testScript @testParams

        $testResult.Error | 
        Should -BeLike "Failed retrieving the SFTP file list*"
    }
    It 'the SFTP file cannot be downloaded' {
        Mock Get-SFTPChildItem {
            $testData
        }
        Mock Get-SFTPItem {
            throw 'oops'
        }

        $testResult = .$testScript @testParams

        $testResult.Error | 
        Should -Be "Failed downloading file: oops"
    }
}
Describe 'OverwriteFile' {
    BeforeAll {
        Mock Get-SFTPChildItem {
            $testData
        }
    }
    It 'when true the file is overwritten' {
        $testNewParams = $testParams.Clone()
        $testNewParams.OverwriteFile = $true
    
        .$testScript @testNewParams

        Should -Invoke Get-SFTPItem -Times 1 -Exactly -ParameterFilter {
            $Force -eq $true
        }
    }
    It 'when false the file is not overwritten' {
        $testNewParams = $testParams.Clone()
        $testNewParams.OverwriteFile = $false
    
        .$testScript @testNewParams

        Should -Invoke Get-SFTPItem -Times 1 -Exactly -ParameterFilter {
            (-not $Force)
        }
    }
}
Describe 'RemoveFileAfterDownload' {
    BeforeAll {
        Mock Get-SFTPChildItem {
            $testData
        }
    }
    Context 'when false' {
        BeforeAll {
            $testNewParams = $testParams.Clone()
            $testNewParams.RemoveFileAfterDownload = $false
    
            $testResults = .$testScript @testNewParams
        }
        It 'the file on the SFTP server is not removed' {
            Should -Not -Invoke Remove-SFTPItem -Scope 'Context'
        }
    }
    Context 'when true' {
        BeforeAll {
            $testNewParams = $testParams.Clone()
            $testNewParams.RemoveFileAfterDownload = $true
    
            $testResults = .$testScript @testNewParams
        }
        It 'the file on the SFTP server is removed' {
            Should -Invoke Remove-SFTPItem -Times 1 -Exactly -Scope 'Context' -ParameterFilter {
                $path -eq $testData[0].FullName
            }
        }
        It 'return an object with results' {
            $testResults | ForEach-Object {
                $_.DateTime | Should -Not -BeNullOrEmpty
                $_.LocalPath | Should -Not -BeNullOrEmpty
                $_.SftpPath | Should -Not -BeNullOrEmpty
                $_.FileName | Should -Be $testData[0].Name
                $_.Downloaded | Should -BeTrue
                $_.Action[0] | Should -Be 'file downloaded'
                $_.Action[1] | Should -Be 'file removed'
                $_.Error | Should -BeNullOrEmpty
            }
        }
    }
}
