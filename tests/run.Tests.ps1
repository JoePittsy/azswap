#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    # Harmless commands to run under a profile.
    function global:Show-Run { "dir=$env:AZURE_CONFIG_DIR"; $args }
    function global:Invoke-Boom { throw 'boom' }
    $script:pwsh = (Get-Process -Id $PID).Path # pwsh or powershell.exe, whichever runs the tests

    function New-TestProfile([string]$Name, [string]$Expected) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') 'tid-1'
        if ($Expected) { Set-Content (Join-Path $dir 'azswap-account') $Expected }
        $dir
    }

    # Runs a failing azswap call and returns its error message, whatever $ErrorActionPreference is.
    function Get-RunError([scriptblock]$Call) {
        try { & $Call } catch { return $_.Exception.Message }
        throw 'Expected the call to fail.'
    }
}

AfterAll {
    Remove-Item function:global:az, function:global:Show-Run, function:global:Invoke-Boom -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'azswap run' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $other = New-TestProfile fabrikam 'me@fabrikam.com'
        $dir = New-TestProfile contoso 'me@contoso.com'

        # Pester runs non-interactive; sign-in tests are about an interactive shell.
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        $script:signedIn = 'me@contoso.com'
        Mock az -ModuleName azswap { $script:signedIn } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' -and $args -contains 'user.name' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
        Mock Invoke-Boom { 'ran' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    Context 'running' {
        It 'runs the command under the profile, then restores the previous profile' {
            azswap run contoso -- Show-Run | Should -Be "dir=$dir"
            $env:AZURE_CONFIG_DIR | Should -Be $other
            Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
        }

        It 'leaves AZURE_CONFIG_DIR unset when it was unset' {
            $env:AZURE_CONFIG_DIR = $null
            azswap run contoso -- Show-Run | Should -Be "dir=$dir"
            Test-Path env:AZURE_CONFIG_DIR | Should -BeFalse
        }

        It 'restores the previous profile when the command throws' {
            Mock Invoke-Boom { throw 'boom' }
            { azswap run contoso -- Invoke-Boom } | Should -Throw 'boom'
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'passes every token after the command name through verbatim' {
            $out = azswap run contoso -- Show-Run account show --query user.name -o tsv -Interactive -NoLogin
            $out | Should -Be @("dir=$dir", 'account', 'show', '--query', 'user.name', '-o', 'tsv', '-Interactive', '-NoLogin')
        }

        It 'sets AZURE_CONFIG_DIR for a child process and preserves its exit code' {
            azswap run contoso -- $pwsh -NoProfile -Command '$env:AZURE_CONFIG_DIR; exit 3' | Should -Be $dir
            $LASTEXITCODE | Should -Be 3
            azswap run contoso -- $pwsh -NoProfile -Command 'exit 0' | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context 'signing in' {
        BeforeEach {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        }

        It 'signs in under the profile first when the token has expired' {
            Mock az -ModuleName azswap { $global:loginDir = $env:AZURE_CONFIG_DIR; $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
            azswap run contoso -Interactive -- Show-Run | Should -Be "dir=$dir"
            $global:loginDir | Should -Be $dir
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'login' -and ($args -join ' ') -match '--tenant tid-1 ' -and $args -notcontains '--use-device-code'
            }
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'passes -DeviceCode through to the sign-in' {
            Set-Content (Join-Path $dir 'azswap-login') 'interactive'
            azswap run contoso -DeviceCode -- Show-Run | Out-Null
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'login' -and $args -contains '--use-device-code' }
        }

        It 'does not run the command when sign-in fails, and LASTEXITCODE stays non-zero' {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
            azswap run contoso -WarningAction SilentlyContinue -- Invoke-Boom
            Should -Invoke Invoke-Boom -Times 0 -Exactly
            $LASTEXITCODE | Should -Not -Be 0
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'refuses to sign in with -NoLogin and does not run the command' {
            Get-RunError { azswap run contoso -NoLogin -ErrorAction Stop -- Invoke-Boom } | Should -BeLike '*-NoLogin was given*: azswap contoso'
            Should -Invoke Invoke-Boom -Times 0 -Exactly
            Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'refuses to sign in in a non-interactive host and does not run the command' {
            Mock Test-AzswapInteractive -ModuleName azswap { $false }
            Get-RunError { azswap run contoso -ErrorAction Stop -- Invoke-Boom } | Should -BeLike '*non-interactive*: azswap contoso'
            Should -Invoke Invoke-Boom -Times 0 -Exactly
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }
    }

    Context 'account check' {
        It 'refuses to run the command as the wrong account' {
            $script:signedIn = 'someone@else.com'
            Get-RunError { azswap run contoso -ErrorAction Stop -WarningAction SilentlyContinue -- Invoke-Boom } |
                Should -Be "Wrong account for 'contoso', so 'Invoke-Boom' was not run."
            Should -Invoke Invoke-Boom -Times 0 -Exactly
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'warns but runs, without recording, when the profile has no expected account' {
            Remove-Item (Join-Path $dir 'azswap-account')
            azswap run contoso -WarningVariable w -WarningAction SilentlyContinue -- Show-Run | Should -Be "dir=$dir"
            "$w" | Should -BeLike "No expected account for 'contoso'*"
            Test-Path (Join-Path $dir 'azswap-account') | Should -BeFalse
        }
    }

    Context 'errors' {
        It 'errors on an unknown profile' {
            Get-RunError { azswap run nope -ErrorAction Stop -- Show-Run } | Should -BeLike "Unknown profile 'nope'*"
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
        }

        It 'errors when the profile or command is missing' {
            Get-RunError { azswap run -ErrorAction Stop } | Should -BeLike 'Usage: azswap run*'
            Get-RunError { azswap run contoso -ErrorAction Stop } | Should -BeLike 'Usage: azswap run*'
            Get-RunError { azswap run contoso -ErrorAction Stop -- } | Should -BeLike 'Usage: azswap run*'
        }

        It 'rejects -Account' {
            Get-RunError { azswap run contoso -Account a@b.com -ErrorAction Stop -- Show-Run } | Should -BeLike '-Account works with*'
        }

        It 'other commands reject extra arguments: <_>' -ForEach @('new a b c', 'list x y z', 'login x y z', 'import x y z', 'contoso x y z') {
            $words = $_ -split ' '
            Get-RunError { azswap @words -ErrorAction Stop } | Should -BeLike 'Unexpected argument(s):*'
            Test-Path (Join-Path $TestDrive '.azure-a') | Should -BeFalse
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }
    }

    Context 'tab completion' {
        It 'completes profile names after run' {
            (TabExpansion2 -inputScript 'azswap run ' -cursorColumn 11).CompletionMatches.CompletionText |
                Should -Be @('contoso', 'fabrikam')
            (TabExpansion2 -inputScript 'azswap run f' -cursorColumn 12).CompletionMatches.CompletionText |
                Should -Be @('fabrikam')
        }
    }
}
