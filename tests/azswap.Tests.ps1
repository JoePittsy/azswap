#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI. Functions win over az.cmd/az on PATH, so the real CLI is
    # never reached; anything not mocked below fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    function New-TestProfile([string]$Name, [string]$Tenant, [string]$Account, [string]$Subscription) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') $Tenant
        if ($Account) {
            @{ subscriptions = @(@{ isDefault = $true; name = $Subscription; user = @{ name = $Account } }) } |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'azureProfile.json')
        }
        $dir
    }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'azswap' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null

        # Pester itself runs non-interactive (redirected stdin in CI); these tests are about an interactive shell.
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        Mock az -ModuleName azswap { if ($args -notcontains 'user.name') { 'user@contoso.com  Contoso Prod' } } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' } # user.name query (account check): not signed in
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    Context 'help' {
        It 'prints usage for <_>' -ForEach @('help', '--help') {
            azswap $_ | Should -Match '^azswap - per-customer Azure CLI profiles'
        }

        It 'prints usage for -h and -Help' {
            azswap -h | Should -Match 'Usage:'
            azswap -Help | Should -Match 'Usage:'
        }

        It 'has comment-based help with examples' {
            $help = Get-Help azswap
            $help.Synopsis | Should -Match 'Azure CLI profiles'
            @($help.Examples.Example).Count | Should -BeGreaterThan 0
        }
    }

    Context 'status' {
        It 'says no profile is selected when AZURE_CONFIG_DIR is unset' {
            azswap | Should -Be "No profile selected; az is using ~/.azure. Run 'azswap list'."
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
        }

        It 'shows the profile name and account' {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1'
            azswap | Should -Be 'contoso  user@contoso.com  Contoso Prod'
        }
    }

    Context 'switch' {
        It 'sets AZURE_CONFIG_DIR and skips sign-in when the token is valid' {
            $dir = New-TestProfile contoso 'tid-1'
            azswap contoso | Should -Be 'user@contoso.com  Contoso Prod'
            $env:AZURE_CONFIG_DIR | Should -Be $dir
            Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
        }

        It 'signs in to the profile tenant with a device code when the token has expired' {
            New-TestProfile contoso 'tid-1' | Out-Null
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            azswap contoso | Out-Null
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'login' -and ($args -join ' ') -match '--tenant tid-1 ' -and $args -contains '--use-device-code'
            }
        }

        It 'signs in without a device code with -Interactive' {
            New-TestProfile contoso 'tid-1' | Out-Null
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            azswap contoso -Interactive | Out-Null
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'login' -and ($args -join ' ') -match '--tenant tid-1 ' -and $args -notcontains '--use-device-code'
            }
        }

        It 'errors on an unknown profile and leaves AZURE_CONFIG_DIR alone' {
            { azswap nope -ErrorAction Stop } | Should -Throw "Unknown profile 'nope'*"
            $env:AZURE_CONFIG_DIR | Should -BeNullOrEmpty
        }
    }

    Context 'login' {
        It 'errors when no profile is selected' {
            { azswap login -ErrorAction Stop } | Should -Throw 'No profile selected*'
        }

        It 'signs in to the current profile tenant' {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1'
            azswap login | Should -Be 'user@contoso.com  Contoso Prod'
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'login' -and ($args -join ' ') -match '--tenant tid-1 ' -and $args -contains '--use-device-code'
            }
        }
    }

    Context 'new' {
        It 'needs a profile and a tenant' {
            { azswap new -ErrorAction Stop } | Should -Throw 'Usage: azswap new <profile> <tenant>'
            { azswap new contoso -ErrorAction Stop } | Should -Throw 'Usage: azswap new <profile> <tenant>'
        }

        It 'rejects the reserved name <_>' -ForEach @('list', 'new', 'login', 'help') {
            { azswap new $_ 'tid-1' -ErrorAction Stop } | Should -Throw "'$_' is a command name*"
        }

        It 'rejects an existing profile' {
            New-TestProfile contoso 'tid-1' | Out-Null
            { azswap new contoso 'tid-2' -ErrorAction Stop } | Should -Throw "Profile 'contoso' already exists."
            Get-Content (Join-Path $TestDrive '.azure-contoso\azswap-tenant') | Should -Be 'tid-1'
        }

        It 'creates the folder and tenant file, then switches' {
            azswap new fabrikam fabrikam.onmicrosoft.com | Should -Be 'user@contoso.com  Contoso Prod'
            $dir = Join-Path $TestDrive '.azure-fabrikam'
            Get-Content (Join-Path $dir 'azswap-tenant') | Should -Be 'fabrikam.onmicrosoft.com'
            $env:AZURE_CONFIG_DIR | Should -Be $dir
        }
    }

    Context 'list' {
        It 'lists profiles with account, subscription and tenant, marking the current one' {
            New-TestProfile contoso 'tid-1' 'me@contoso.com' 'Contoso Prod' | Out-Null
            $env:AZURE_CONFIG_DIR = New-TestProfile fabrikam 'tid-2' 'me@fabrikam.com' 'Fabrikam Dev'
            New-Item -ItemType Directory (Join-Path $TestDrive '.azure-notaprofile') | Out-Null

            $lines = (azswap list | Out-String -Width 200) -split '\r?\n'
            $lines | Where-Object { $_ -match 'contoso' } | Should -Match '^\s+contoso\s+me@contoso\.com\s+Contoso Prod\s+tid-1'
            $lines | Where-Object { $_ -match 'fabrikam' } | Should -Match '^\*\s+fabrikam\s+me@fabrikam\.com\s+Fabrikam Dev\s+tid-2'
            $lines -match 'notaprofile' | Should -BeNullOrEmpty
        }
    }

    Context 'tab completion' {
        It 'completes commands and profile names' {
            New-TestProfile contoso 'tid-1' | Out-Null
            New-TestProfile lcc 'tid-2' | Out-Null
            $all = (TabExpansion2 -inputScript 'azswap ' -cursorColumn 7).CompletionMatches.CompletionText
            $all | Should -Be @('list', 'new', 'login', 'help', 'import', 'contoso', 'lcc')

            $l = (TabExpansion2 -inputScript 'azswap l' -cursorColumn 8).CompletionMatches.CompletionText
            $l | Should -Be @('list', 'login', 'lcc')
        }
    }
}
