#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly. list -AsJson must never call it.
    function global:az { throw "Unmocked az call: $args" }

    # A profile folder. -AzProfile is azureProfile.json's content: a hashtable, or a raw string.
    function New-TestProfile([string]$Name, [string]$Tenant = 'tid-1', $AzProfile, [string]$Expected, [string]$Login) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') $Tenant
        if ($null -ne $AzProfile) {
            $text = if ($AzProfile -is [string]) { $AzProfile } else { $AzProfile | ConvertTo-Json -Depth 5 }
            Set-Content (Join-Path $dir 'azureProfile.json') $text
        }
        if ($Expected) { Set-Content (Join-Path $dir 'azswap-account') $Expected }
        if ($Login) { Set-Content (Join-Path $dir 'azswap-login') $Login }
        $dir
    }

    function New-AzProfile([string]$Account, [string]$Subscription = 'Sub', [string]$Id = 'sub-id-1') {
        @{ subscriptions = @(
            @{ isDefault = $false; name = 'Other'; id = 'sub-id-0'; user = @{ name = 'other@woodgrove.com' } }
            @{ isDefault = $true; name = $Subscription; id = $Id; user = @{ name = $Account; type = 'user' } }
        ) }
    }

    # Every top-level JSON value as its own item, on 5.1 (one array object) and 7 (enumerated).
    function ConvertFrom-JsonArray([string]$Json) { @(foreach ($r in ($Json | ConvertFrom-Json)) { $r }) }

    function Get-ListJson { $out = @(azswap list -AsJson); $out.Count | Should -Be 1; [string]$out[0] }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'list -AsJson' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        Mock az -ModuleName azswap { throw "az called: $args" }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
        Should -Invoke az -ModuleName azswap -Times 0 -Exactly
    }

    Context 'shape' {
        It 'prints an empty JSON array with no profiles' {
            New-Item -ItemType Directory (Join-Path $TestDrive '.azure-notaprofile') | Out-Null
            $json = Get-ListJson
            $json.Trim() | Should -Match '^\[\s*\]$'
            ConvertFrom-JsonArray $json | Should -HaveCount 0
        }

        It 'prints an array with one profile' {
            New-TestProfile contoso -AzProfile (New-AzProfile 'me@contoso.com') | Out-Null
            $json = Get-ListJson
            $json.Trim() | Should -Match '^\[[\s\S]*\]$'
            $rows = ConvertFrom-JsonArray $json
            $rows | Should -HaveCount 1
            $rows[0].name | Should -Be 'contoso'
        }

        It 'prints an array with several profiles' {
            'contoso', 'fabrikam', 'northwind' | ForEach-Object { New-TestProfile $_ | Out-Null }
            $json = Get-ListJson
            $json.Trim() | Should -Match '^\['
            (ConvertFrom-JsonArray $json).name | Should -Be @('contoso', 'fabrikam', 'northwind')
        }

        It 'uses exactly the documented camelCase keys, in order' {
            New-TestProfile contoso | Out-Null
            $keys = (ConvertFrom-JsonArray (Get-ListJson))[0].PSObject.Properties.Name
            $keys | Should -Be @('name', 'active', 'path', 'tenant', 'account', 'expectedAccount', 'accountMismatch', 'subscription', 'subscriptionId', 'loginMethod')
            Get-ListJson | Should -MatchExactly '"expectedAccount"'
        }
    }

    Context 'fields' {
        It 'fills every field from the profile folder' {
            $dir = New-TestProfile contoso 'tid-contoso' (New-AzProfile 'me@contoso.com' 'Contoso Prod' 'sub-contoso') -Expected 'me@contoso.com' -Login interactive
            $r = (ConvertFrom-JsonArray (Get-ListJson))[0]
            $r.name | Should -Be 'contoso'
            $r.active | Should -BeFalse
            $r.path | Should -Be $dir
            $r.tenant | Should -Be 'tid-contoso'
            $r.account | Should -Be 'me@contoso.com'
            $r.expectedAccount | Should -Be 'me@contoso.com'
            $r.accountMismatch | Should -BeFalse
            $r.subscription | Should -Be 'Contoso Prod'
            $r.subscriptionId | Should -Be 'sub-contoso'
            $r.loginMethod | Should -Be 'interactive'
        }

        It 'gives real JSON booleans and nulls' {
            New-TestProfile contoso | Out-Null
            $json = Get-ListJson
            $json | Should -Match '"active":\s*false'
            $json | Should -Match '"accountMismatch":\s*false'
            $json | Should -Match '"account":\s*null'
            $json | Should -Match '"loginMethod":\s*null'
        }

        It 'reads loginMethod <_>' -ForEach @('interactive', 'devicecode') {
            New-TestProfile contoso -Login $_ | Out-Null
            (ConvertFrom-JsonArray (Get-ListJson))[0].loginMethod | Should -Be $_
        }

        It 'marks only the current AZURE_CONFIG_DIR active' {
            New-TestProfile contoso | Out-Null
            $env:AZURE_CONFIG_DIR = New-TestProfile fabrikam
            $rows = ConvertFrom-JsonArray (Get-ListJson)
            ($rows | Where-Object name -eq 'contoso').active | Should -BeFalse
            ($rows | Where-Object name -eq 'fabrikam').active | Should -BeTrue
        }

        It 'reports a service principal account (a GUID) as it is' {
            $sp = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
            New-TestProfile woodgrove -AzProfile (New-AzProfile $sp) -Expected $sp | Out-Null
            $r = (ConvertFrom-JsonArray (Get-ListJson))[0]
            $r.account | Should -Be $sp
            $r.accountMismatch | Should -BeFalse
        }
    }

    Context 'accountMismatch' {
        It 'is <Mismatch> when signed in as <Account> and expecting <Expected>' -ForEach @(
            @{ Account = 'me@contoso.com'; Expected = 'admin@contoso.com'; Mismatch = $true }
            @{ Account = 'me@contoso.com'; Expected = 'ME@Contoso.com'; Mismatch = $false }
            @{ Account = 'me@contoso.com'; Expected = ''; Mismatch = $false }
            @{ Account = ''; Expected = 'admin@contoso.com'; Mismatch = $false }
            @{ Account = ''; Expected = ''; Mismatch = $false }
        ) {
            $azProfile = if ($Account) { New-AzProfile $Account }
            New-TestProfile contoso -AzProfile $azProfile -Expected $Expected | Out-Null
            $r = (ConvertFrom-JsonArray (Get-ListJson))[0]
            $r.accountMismatch | Should -Be $Mismatch
            $r.account | Should -Be $(if ($Account) { $Account } else { $null })
            $r.expectedAccount | Should -Be $(if ($Expected) { $Expected } else { $null })
        }
    }

    Context 'unreadable azureProfile.json' {
        It 'gives nulls when azureProfile.json is <Case>' -ForEach @(
            @{ Case = 'missing'; Content = $null }
            @{ Case = 'empty'; Content = '' }
            @{ Case = 'invalid'; Content = '{ not json' }
            @{ Case = 'without subscriptions'; Content = '{"installationId": "x"}' }
            @{ Case = 'without a default subscription'; Content = '{"subscriptions": [{"isDefault": false, "name": "S", "id": "i", "user": {"name": "u@fabrikam.com"}}]}' }
        ) {
            New-TestProfile fabrikam 'tid-2' -AzProfile $Content -Expected 'me@fabrikam.com' | Out-Null
            $r = (ConvertFrom-JsonArray (Get-ListJson))[0]
            $r.name | Should -Be 'fabrikam'
            $r.tenant | Should -Be 'tid-2'
            $r.account | Should -BeNullOrEmpty
            $r.subscription | Should -BeNullOrEmpty
            $r.subscriptionId | Should -BeNullOrEmpty
            $r.accountMismatch | Should -BeFalse
        }
    }

    Context 'plain list is unchanged' {
        It 'still prints the table, flagging a mismatch' {
            New-TestProfile contoso 'tid-1' (New-AzProfile 'me@contoso.com' 'Contoso Prod') -Expected 'admin@contoso.com' | Out-Null
            $env:AZURE_CONFIG_DIR = New-TestProfile fabrikam 'tid-2' (New-AzProfile 'me@fabrikam.com' 'Fabrikam Dev')
            $lines = (azswap list | Out-String -Width 200) -split '\r?\n'
            $lines | Where-Object { $_ -match 'contoso' } | Should -Match '^\s+contoso\s+! me@contoso\.com \(expects admin@contoso\.com\)\s+Contoso Prod\s+tid-1'
            $lines | Where-Object { $_ -match 'fabrikam' } | Should -Match '^\*\s+fabrikam\s+me@fabrikam\.com\s+Fabrikam Dev\s+tid-2'
        }
    }

    Context 'usage' {
        It 'rejects -AsJson with <_>' -ForEach @('', 'contoso', 'new', 'login', 'import', 'help', '--help', 'run') {
            New-TestProfile contoso | Out-Null
            $env:AZURE_CONFIG_DIR = $null
            { azswap $_ -AsJson -ErrorAction Stop } | Should -Throw '-AsJson works only with list.'
            $env:AZURE_CONFIG_DIR | Should -BeNullOrEmpty
        }

        It 'rejects -AsJson with -Help' {
            { azswap list -Help -AsJson -ErrorAction Stop } | Should -Throw '-AsJson works only with list.'
        }

        It 'is in the usage text' {
            azswap help | Should -Match 'azswap list \[-AsJson\]'
        }
    }
}
