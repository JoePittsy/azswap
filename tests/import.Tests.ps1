#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI: import must never call it, so nothing is mocked.
    function global:az { throw "Unmocked az call: $args" }

    # An az config folder under $TestDrive. Each subscription is @(account, tenant, isDefault[, tenantDomain]).
    # azureProfile.json is written as UTF-8 with a BOM, as az writes it.
    function New-AzFolder([string]$Name, [object[]]$Subscriptions, [switch]$ConfigOnly) {
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'config') '[core]'
        if ($ConfigOnly) { return $dir }
        $subs = @(foreach ($s in $Subscriptions) {
            $sub = @{ id = [guid]::NewGuid(); name = "Sub $($s[0])"; tenantId = $s[1]; isDefault = [bool]$s[2]
                      user = @{ name = $s[0]; type = if ($s[0] -match '@') { 'user' } else { 'servicePrincipal' } } }
            if ($s.Count -gt 3) { $sub.tenantDefaultDomain = $s[3] }
            $sub
        })
        $json = ConvertTo-Json @{ subscriptions = $subs } -Depth 5
        [IO.File]::WriteAllText((Join-Path $dir 'azureProfile.json'), $json, [Text.UTF8Encoding]::new($true))
        $dir
    }

    function Get-Row($Rows, $ProfileName) { $Rows | Where-Object Profile -eq $ProfileName }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'azswap import' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        Mock az -ModuleName azswap { throw "import must not call az: $args" }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        Should -Invoke az -ModuleName azswap -Times 0 -Exactly
    }

    Context 'existing ~/.azure-* folders' {
        BeforeEach {
            New-AzFolder '.azure-contoso' @(, @('me@contoso.com', 'tid-c', $true)) | Out-Null
            New-AzFolder '.azure-multi' @(@('a@x.com', 'tid-x', $false), @('b@y.com', 'tid-y', $false)) | Out-Null
            New-AzFolder '.azure-onetenant' @(@('me@one.com', 'tid-1', $false), @('me@one.com', 'tid-1', $false)) | Out-Null
            New-AzFolder '.azure-fresh' -ConfigOnly | Out-Null
            New-Item -ItemType Directory (Join-Path $TestDrive '.azure-devops') | Out-Null
            New-AzFolder '.azure-list' @(, @('me@l.com', 'tid-l', $true)) | Out-Null
            $script:existing = New-AzFolder '.azure-done' @(, @('me@done.com', 'tid-d', $true))
            Set-Content (Join-Path $existing 'azswap-tenant') 'tid-d'
        }

        It 'is a dry run by default and explains what it cannot resolve' {
            $rows = azswap import
            (Get-Row $rows contoso).Status | Should -Be 'would register'
            (Get-Row $rows contoso).Tenant | Should -Be 'tid-c'
            (Get-Row $rows contoso).Account | Should -Be 'me@contoso.com'
            (Get-Row $rows onetenant).Tenant | Should -Be 'tid-1'
            (Get-Row $rows multi).Status | Should -Be 'skipped: several tenants and no default subscription'
            (Get-Row $rows fresh).Status | Should -Match '^skipped: no profile data'
            (Get-Row $rows devops).Status | Should -Be 'skipped: not an az config folder'
            (Get-Row $rows list).Status | Should -Match "is a command name"
            Get-Row $rows done | Should -BeNullOrEmpty
            Get-ChildItem $TestDrive -Recurse -Force -Filter 'azswap-*' | Should -HaveCount 1
        }

        It 'writes tenant and account with -Apply, and leaves other files alone' {
            $before = Get-Content (Join-Path $TestDrive '.azure-contoso\azureProfile.json') -Raw
            $rows = azswap import -Apply
            (Get-Row $rows contoso).Status | Should -Be 'registered'
            Get-Content (Join-Path $TestDrive '.azure-contoso\azswap-tenant') | Should -Be 'tid-c'
            Get-Content (Join-Path $TestDrive '.azure-contoso\azswap-account') | Should -Be 'me@contoso.com'
            Get-Content (Join-Path $TestDrive '.azure-contoso\azureProfile.json') -Raw | Should -Be $before
            Test-Path (Join-Path $TestDrive '.azure-multi\azswap-tenant') | Should -BeFalse
            Test-Path (Join-Path $TestDrive '.azure-devops\azswap-tenant') | Should -BeFalse
            Test-Path (Join-Path $TestDrive '.azure-list\azswap-tenant') | Should -BeFalse
            azswap list | Out-String | Should -Match 'contoso'
        }

        It 'does not overwrite an existing azswap-account holding <Label>' -ForEach @(
            @{ Label = 'an account'; Content = 'other@contoso.com' }
            @{ Label = 'whitespace'; Content = "  `r`n" }
            @{ Label = 'nothing'; Content = '' }
        ) {
            $file = Join-Path $TestDrive '.azure-contoso\azswap-account'
            [IO.File]::WriteAllText($file, $Content)
            (Get-Row (azswap import -Apply) contoso).Status | Should -Be 'registered'
            [IO.File]::ReadAllText($file) | Should -BeExactly $Content
        }

        It 'keeps the tenant but not an account when one tenant has two accounts and no default' {
            New-AzFolder '.azure-shared' @(@('a@s.com', 'tid-s', $false), @('b@s.com', 'tid-s', $false)) | Out-Null
            $row = Get-Row (azswap import -Only shared -Apply) shared
            $row.Tenant | Should -Be 'tid-s'
            $row.Account | Should -BeNullOrEmpty
            Get-Content (Join-Path $TestDrive '.azure-shared\azswap-tenant') | Should -Be 'tid-s'
            Test-Path (Join-Path $TestDrive '.azure-shared\azswap-account') | Should -BeFalse
        }

        It 'reports a failed write and carries on with the other folders' {
            Mock Write-AzswapSetting -ModuleName azswap {
                if ($Dir -like '*.azure-contoso') { throw 'Access denied' }
                Set-Content (Join-Path $Dir "azswap-$Name") $Value
            }
            $rows = azswap import -Apply
            (Get-Row $rows contoso).Status | Should -Be 'failed: Access denied'
            (Get-Row $rows onetenant).Status | Should -Be 'registered'
        }

        It 'treats a real non-terminating write error as a failure' {
            # Set-Content under a path that is a file fails without throwing on its own.
            $notADir = Join-Path $TestDrive 'plain-file'
            Set-Content $notADir 'x'
            InModuleScope azswap -Parameters @{ Dir = $notADir } {
                Write-AzswapImport -Dir $Dir -Tenant 'tid' -Account 'me@x.com' 2>$null
            } | Should -Match '^failed: '
            Test-Path $notADir -PathType Leaf | Should -BeTrue
        }

        It 'limits itself to -Only' {
            $rows = azswap import -Only onetenant -Apply
            @($rows).Count | Should -Be 1
            Test-Path (Join-Path $TestDrive '.azure-onetenant\azswap-tenant') | Should -BeTrue
            Test-Path (Join-Path $TestDrive '.azure-contoso\azswap-tenant') | Should -BeFalse
        }

        It 'says when there is nothing to import' {
            Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
            azswap import | Should -Be 'No ~/.azure-* folders to import.'
        }
    }

    Context '-FromDefault' {
        BeforeEach {
            $sp = '0a1b2c3d-1111-2222-3333-444455556666'
            New-AzFolder '.azure' @(
                @('me@contoso.com', 'tid-c', $true, 'contosoltd.onmicrosoft.com'),
                @('me@contoso.com', 'tid-c', $false, 'contosoltd.onmicrosoft.com'),
                @('me@fabrikam.co.uk', 'tid-f', $false),
                @('admin@fabrikam.co.uk', 'tid-f', $false),
                @($sp, 'tid-s', $false),
                @('me@List.com', 'tid-l', $false)
            ) | Out-Null
        }

        It 'suggests one profile per account and tenant without writing anything' {
            $rows = azswap import -FromDefault
            @($rows).Count | Should -Be 5
            (Get-Row $rows contosoltd).Account | Should -Be 'me@contoso.com'
            (Get-Row $rows contosoltd).Status | Should -Be 'would create'
            (Get-Row $rows fabrikam-me).Tenant | Should -Be 'tid-f'
            (Get-Row $rows fabrikam-admin).Account | Should -Be 'admin@fabrikam.co.uk'
            (Get-Row $rows 'tid').Account | Should -Be $sp
            (Get-Row $rows list).Status | Should -Match 'is a command name'
            Get-ChildItem $TestDrive -Force -Filter '.azure-*' | Should -BeNullOrEmpty
        }

        It 'creates empty profiles with tenant and account, and no tokens, with -Apply' {
            $rows = azswap import -FromDefault -Apply
            (Get-Row $rows contosoltd).Status | Should -Be 'created; sign in with: azswap contosoltd'
            $dir = Join-Path $TestDrive '.azure-contosoltd'
            (Get-ChildItem $dir -Force).Name | Sort-Object | Should -Be @('azswap-account', 'azswap-tenant')
            Get-Content (Join-Path $dir 'azswap-tenant') | Should -Be 'tid-c'
            Get-Content (Join-Path $dir 'azswap-account') | Should -Be 'me@contoso.com'
            Test-Path (Join-Path $TestDrive '.azure-list') | Should -BeFalse
            (Get-ChildItem (Join-Path $TestDrive '.azure') -Force).Name | Sort-Object | Should -Be @('azureProfile.json', 'config')
        }

        It 'skips names that already exist' {
            New-Item -ItemType Directory (Join-Path $TestDrive '.azure-contosoltd') | Out-Null
            $rows = azswap import -FromDefault -Apply
            (Get-Row $rows contosoltd).Status | Should -Be 'skipped: .azure-contosoltd already exists'
            Get-ChildItem (Join-Path $TestDrive '.azure-contosoltd') -Force | Should -BeNullOrEmpty
            (Get-Row $rows fabrikam-me).Status | Should -Match '^created'
        }

        It 'removes a folder it created when the tenant write fails, and carries on' {
            Mock Write-AzswapSetting -ModuleName azswap {
                if ($Dir -like '*.azure-contosoltd') { throw 'Access denied' }
                Set-Content (Join-Path $Dir "azswap-$Name") $Value
            }
            $rows = azswap import -FromDefault -Apply
            (Get-Row $rows contosoltd).Status | Should -Be 'failed: Access denied'
            Test-Path (Join-Path $TestDrive '.azure-contosoltd') | Should -BeFalse
            (Get-Row $rows fabrikam-me).Status | Should -Match '^created'
        }

        It 'creates only the profiles named in -Only' {
            azswap import -FromDefault -Only fabrikam-me, contosoltd -Apply | Should -HaveCount 2
            (Get-ChildItem $TestDrive -Force -Filter '.azure-*').Name | Sort-Object |
                Should -Be @('.azure-contosoltd', '.azure-fabrikam-me')
        }

        Context 'identities that already have profiles' {
            BeforeEach {
                Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
                New-AzFolder '.azure' @(
                    @('azx.me@leeds.gov.uk', 'T1', $true),
                    @('JPitts@trueNorthIT.co.uk', 'T1', $false),
                    @('adm@truenorthit.co.uk', 'T3', $false),
                    @('me@nhs.net', 'T2', $false)
                ) | Out-Null
                function New-Profile($Name, $Tenant) {
                    $dir = Join-Path $TestDrive ".azure-$Name"
                    New-Item -ItemType Directory -Force $dir | Out-Null
                    Set-Content (Join-Path $dir 'azswap-tenant') $Tenant
                    $dir
                }
                # Covered through its azureProfile.json, which has no azswap-account.
                $lcc = New-AzFolder '.azure-lcc' @(, @('AZX.me@leeds.gov.uk', 'T1', $true))
                Set-Content (Join-Path $lcc 'azswap-tenant') 'T1'
                # Never signed in: same tenant, account unknown.
                New-Profile lcc-tnit T1 | Out-Null
                New-Profile nhs T2 | Out-Null
                New-Profile nhs2 T2 | Out-Null
                # Covered through azswap-account (case-insensitive), never signed in.
                Set-Content (Join-Path (New-Profile tnit T3) 'azswap-account') 'ADM@TrueNorthIT.co.uk'
            }

            It 'shows covered identities as existing and skips unconfirmed ones' {
                $rows = azswap import -FromDefault -Apply
                (Get-Row $rows leeds).Status | Should -Be 'exists: lcc'
                (Get-Row $rows truenorthit-adm).Status | Should -Be 'exists: tnit'
                (Get-Row $rows truenorthit-jpitts).Status |
                    Should -Be "skipped: tenant already has profile 'lcc-tnit' (account unknown; sign in to it, or use -Only to create anyway)"
                (Get-Row $rows nhs).Status | Should -Match "^skipped: tenant already has profile 'nhs', 'nhs2' \(account unknown"
                (Get-ChildItem $TestDrive -Force -Filter '.azure-*').Name | Sort-Object |
                    Should -Be @('.azure-lcc', '.azure-lcc-tnit', '.azure-nhs', '.azure-nhs2', '.azure-tnit')
            }

            It 'creates an unconfirmed identity named in -Only, but never a covered one' {
                $rows = azswap import -FromDefault -Only truenorthit-jpitts, leeds -Apply
                (Get-Row $rows truenorthit-jpitts).Status | Should -Match '^created'
                Get-Content (Join-Path $TestDrive '.azure-truenorthit-jpitts\azswap-account') | Should -Be 'JPitts@trueNorthIT.co.uk'
                (Get-Row $rows leeds).Status | Should -Be 'exists: lcc'
                Test-Path (Join-Path $TestDrive '.azure-leeds') | Should -BeFalse
            }
        }

        It 'errors when ~/.azure has no accounts' {
            Remove-Item (Join-Path $TestDrive '.azure\azureProfile.json')
            { azswap import -FromDefault -ErrorAction Stop } | Should -Throw 'No accounts found*'
        }
    }
}
