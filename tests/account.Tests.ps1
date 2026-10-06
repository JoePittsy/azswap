#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    function New-TestProfile([string]$Name, [string]$Tenant, [string]$Account, [string]$Expected) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') $Tenant
        if ($Account) {
            @{ subscriptions = @(@{ isDefault = $true; name = 'Sub'; user = @{ name = $Account } }) } |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'azureProfile.json')
        }
        if ($Expected) { Set-Content (Join-Path $dir 'azswap-account') $Expected }
        $dir
    }

    function Get-Expected([string]$Name) {
        $file = Join-Path $TestDrive ".azure-$Name\azswap-account"
        if (Test-Path $file) { (Get-Content $file -Raw).Trim() }
    }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'account check' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null

        # Pester runs non-interactive; these tests are about an interactive shell.
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        $script:signedIn = 'me@contoso.com'
        Mock az -ModuleName azswap { $script:signedIn } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' -and $args -contains 'user.name' }
        Mock az -ModuleName azswap { "$script:signedIn  Contoso Prod" } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' -and $args -notcontains 'user.name' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    Context 'Test-AzswapAccount' {
        It 'passes silently when the account matches, ignoring case' {
            $dir = New-TestProfile contoso 'tid-1' -Expected 'ME@Contoso.com'
            InModuleScope azswap -Parameters @{ dir = $dir } {
                Test-AzswapAccount -Dir $dir -WarningVariable w -WarningAction SilentlyContinue | Should -BeTrue
                $w | Should -BeNullOrEmpty
            }
        }

        It 'warns, naming both accounts and the fixes, on a mismatch' {
            $dir = New-TestProfile contoso 'tid-1' -Expected 'admin@contoso.com'
            InModuleScope azswap -Parameters @{ dir = $dir } {
                Test-AzswapAccount -Dir $dir -WarningVariable w -WarningAction SilentlyContinue | Should -BeFalse
                "$w" | Should -Match "profile 'contoso' is signed in as me@contoso\.com, but expects admin@contoso\.com"
                "$w" | Should -Match 'azswap login'
                "$w" | Should -Match 'azswap contoso -Account me@contoso\.com'
            }
            Get-Expected contoso | Should -Be 'admin@contoso.com'
        }

        It 'records the account after a sign-in when none is expected yet' {
            $dir = New-TestProfile contoso 'tid-1'
            InModuleScope azswap -Parameters @{ dir = $dir } {
                Test-AzswapAccount -Dir $dir -SignedIn -InformationVariable i 6>$null | Should -BeTrue
                "$i" | Should -Match 'Recorded me@contoso\.com'
            }
            Get-Expected contoso | Should -Be 'me@contoso.com'
        }

        It 'treats an azswap-account file holding <_> as not set' -ForEach @('', '   ', "`r`n") {
            $dir = New-TestProfile contoso 'tid-1'
            [IO.File]::WriteAllText((Join-Path $dir 'azswap-account'), $_)
            InModuleScope azswap -Parameters @{ dir = $dir } {
                Test-AzswapAccount -Dir $dir -WarningVariable w -WarningAction SilentlyContinue | Should -BeTrue
                "$w" | Should -Match "No expected account for 'contoso'"
            }
        }

        It 'does nothing when not signed in' {
            $dir = New-TestProfile contoso 'tid-1'
            $script:signedIn = $null
            InModuleScope azswap -Parameters @{ dir = $dir } { Test-AzswapAccount -Dir $dir -SignedIn | Should -BeTrue }
            Get-Expected contoso | Should -BeNullOrEmpty
        }
    }

    Context 'switch and login' {
        It 'warns after switching to a profile signed in as the wrong account' {
            New-TestProfile contoso 'tid-1' -Expected 'admin@contoso.com' | Out-Null
            $out = azswap contoso -WarningVariable w -WarningAction SilentlyContinue
            $out | Should -Be 'me@contoso.com  Contoso Prod'
            "$w" | Should -Match 'WRONG ACCOUNT'
        }

        It 'warns after azswap login as the wrong account' {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1' -Expected 'admin@contoso.com'
            azswap login -WarningVariable w -WarningAction SilentlyContinue | Should -Be 'me@contoso.com  Contoso Prod'
            "$w" | Should -Match 'WRONG ACCOUNT'
        }

        It 'warns, and records nothing, on a plain switch with no expected account' {
            New-TestProfile contoso 'tid-1' | Out-Null
            azswap contoso -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            "$w" | Should -Match "No expected account for 'contoso' \(signed in as me@contoso\.com\)\. If that's right, run: azswap contoso -Account me@contoso\.com"
            Get-Expected contoso | Should -BeNullOrEmpty
        }

        It 'records the account after a sign-in azswap performed' {
            New-TestProfile contoso 'tid-1' | Out-Null
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            azswap contoso 6>$null | Out-Null
            Get-Expected contoso | Should -Be 'me@contoso.com'
        }

        It 'records the account after a successful azswap login' {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1'
            azswap login 6>$null | Out-Null
            Get-Expected contoso | Should -Be 'me@contoso.com'
        }

        It 'records nothing and does not check after a failed sign-in' {
            New-TestProfile contoso 'tid-1' | Out-Null
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
            azswap contoso -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Expected contoso | Should -BeNullOrEmpty
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' }
        }

        It 'records nothing and does not check after a refused sign-in' {
            New-TestProfile contoso 'tid-1' | Out-Null
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            azswap contoso -NoLogin -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Expected contoso | Should -BeNullOrEmpty
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' }
        }

        It 'switching with -Account updates the expected account, then checks against it' {
            New-TestProfile contoso 'tid-1' -Expected 'admin@contoso.com' | Out-Null
            azswap contoso -Account me@contoso.com -WarningVariable w | Out-Null
            Get-Expected contoso | Should -Be 'me@contoso.com'
            $w | Should -BeNullOrEmpty
        }

        It 'login -Account stores the expected account' {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1' -Expected 'admin@contoso.com'
            azswap login -Account me@contoso.com -WarningVariable w | Out-Null
            Get-Expected contoso | Should -Be 'me@contoso.com'
            $w | Should -BeNullOrEmpty
        }

        It 'new -Account stores the expected account before signing in' {
            azswap new fabrikam 'tid-2' -Account admin@fabrikam.com -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            Get-Expected fabrikam | Should -Be 'admin@fabrikam.com'
            "$w" | Should -Match 'expects admin@fabrikam\.com'
        }

        It 'rejects -Account with <_>' -ForEach @('', 'list', 'import', 'help', '--help') {
            { azswap $_ -Account me@contoso.com -ErrorAction Stop } | Should -Throw '-Account works with*'
        }

        It 'rejects -Account with -Help' {
            { azswap contoso -Help -Account me@contoso.com -ErrorAction Stop } | Should -Throw '-Account works with*'
        }

        It 'rejects a blank -Account and keeps the expected account' -ForEach @(
            @{ Run = { azswap contoso -Account '  ' -ErrorAction Stop } }
            @{ Run = { $env:AZURE_CONFIG_DIR = Join-Path $TestDrive '.azure-contoso'; azswap login -Account '' -ErrorAction Stop } }
        ) {
            New-TestProfile contoso 'tid-1' -Expected 'admin@contoso.com' | Out-Null
            $Run | Should -Throw '-Account needs an account*'
            Get-Expected contoso | Should -Be 'admin@contoso.com'
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
        }

        It 'new rejects a blank -Account before creating anything' {
            { azswap new fabrikam 'tid-2' -Account ' ' -ErrorAction Stop } | Should -Throw '-Account needs an account*'
            Join-Path $TestDrive '.azure-fabrikam' | Should -Not -Exist
        }
    }


    Context 'list' {
        It 'flags a mismatch offline, without calling az' {
            New-TestProfile contoso 'tid-1' 'me@contoso.com' 'admin@contoso.com' | Out-Null
            New-TestProfile fabrikam 'tid-2' 'me@fabrikam.com' 'ME@fabrikam.com' | Out-Null
            $lines = (azswap list | Out-String -Width 200) -split '\r?\n'
            $lines | Where-Object { $_ -match 'contoso' } | Should -Match '! me@contoso\.com \(expects admin@contoso\.com\)'
            $lines | Where-Object { $_ -match 'fabrikam' } | Should -Not -Match '!'
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
        }
    }
}
