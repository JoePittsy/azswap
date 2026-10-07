#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    # The exact refusal text, without the Windows-only -NewWindow hint (new-window.Tests.ps1 covers it).
    Mock Test-AzswapWindows -ModuleName azswap { $false }

    # $Login is written byte for byte ('' makes a zero-byte file); $null writes no file.
    function New-TestProfile([string]$Name, $Login) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') 'tid-1'
        if ($null -ne $Login) { [IO.File]::WriteAllText((Join-Path $dir 'azswap-login'), $Login) }
        $dir
    }

    # Exact file content, or $null when there is no file.
    function Get-LoginRaw([string]$Name) {
        $file = Join-Path $TestDrive ".azure-$Name/azswap-login"
        if (Test-Path $file) { [IO.File]::ReadAllText($file) }
    }

    function Get-LoginSetting([string]$Name) {
        $raw = Get-LoginRaw $Name
        if ($null -ne $raw) { $raw.Trim() }
    }

    function Assert-LoginCall([bool]$DeviceCode) {
        Should -Invoke az -ModuleName azswap -Times 1 -Exactly -Scope It -ParameterFilter {
            $args[0] -eq 'login' -and ($args -contains '--use-device-code') -eq $DeviceCode
        }
    }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'sign-in method' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null

        # Pester's host is non-interactive, which would refuse every sign-in.
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        Mock az -ModuleName azswap { if ($args -notcontains 'user.name') { 'user@contoso.com  Contoso Prod' } } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' } # user.name query (account check): not signed in
        # Token always expired, so every switch signs in.
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    Context 'resolution' {
        It 'signs in with <expected> when stored=<stored> and switch=<switch>' -ForEach @(
            @{ stored = $null; switch = $null; expected = 'devicecode' }
            @{ stored = 'interactive'; switch = $null; expected = 'interactive' }
            @{ stored = 'devicecode'; switch = $null; expected = 'devicecode' }
            @{ stored = 'interactive'; switch = 'DeviceCode'; expected = 'devicecode' }
            @{ stored = 'devicecode'; switch = 'Interactive'; expected = 'interactive' }
            @{ stored = $null; switch = 'Interactive'; expected = 'interactive' }
            @{ stored = 'Interactive'; switch = $null; expected = 'interactive' }
            @{ stored = "  interactive `r`n"; switch = $null; expected = 'interactive' }
            @{ stored = 'browser'; switch = $null; expected = 'devicecode' }
            @{ stored = '   '; switch = $null; expected = 'devicecode' }
            @{ stored = ''; switch = $null; expected = 'devicecode' }
        ) {
            New-TestProfile contoso $stored | Out-Null
            $splat = @{}
            if ($switch) { $splat[$switch] = $true }
            azswap contoso @splat | Should -Be 'user@contoso.com  Contoso Prod'
            Assert-LoginCall ($expected -eq 'devicecode')
            # Switching never changes what is stored.
            Get-LoginRaw contoso | Should -Be $stored
        }

        It 'rejects -Interactive with -DeviceCode' {
            New-TestProfile contoso | Out-Null
            { azswap contoso -Interactive -DeviceCode -ErrorAction Stop } | Should -Throw '*not both*'
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
            $env:AZURE_CONFIG_DIR | Should -BeNullOrEmpty
        }
    }

    Context 'new' {
        It 'stores <stored> with -<switch> and signs in that way' -ForEach @(
            @{ switch = 'Interactive'; stored = 'interactive' }
            @{ switch = 'DeviceCode'; stored = 'devicecode' }
        ) {
            $splat = @{ $switch = $true }
            azswap new fabrikam fabrikam.onmicrosoft.com @splat | Should -Be 'user@contoso.com  Contoso Prod'
            Get-LoginSetting fabrikam | Should -Be $stored
            Assert-LoginCall ($stored -eq 'devicecode')
        }

        It 'stores nothing without a switch' {
            azswap new fabrikam fabrikam.onmicrosoft.com | Out-Null
            Get-LoginRaw fabrikam | Should -BeNullOrEmpty
            Assert-LoginCall $true
        }

        It 'stores nothing when the sign-in fails' {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
            azswap new fabrikam fabrikam.onmicrosoft.com -Interactive -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-LoginRaw fabrikam | Should -BeNullOrEmpty
            Assert-LoginCall $false
        }

        It 'stores nothing when the sign-in is refused, and the refusal keeps -Interactive' {
            Mock Test-AzswapInteractive -ModuleName azswap { $false }
            { azswap new fabrikam fabrikam.onmicrosoft.com -Interactive -ErrorAction Stop } |
                Should -Throw '*azswap fabrikam -Interactive'
            Get-LoginRaw fabrikam | Should -BeNullOrEmpty
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'login' }
        }
    }

    Context 'login' {
        It 'uses the stored method and leaves it alone' {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'interactive'
            azswap login | Should -Be 'user@contoso.com  Contoso Prod'
            Assert-LoginCall $false
            Get-LoginRaw contoso | Should -Be 'interactive'
        }

        It 'remembers -<switch> as <stored> after signing in that way' -ForEach @(
            @{ switch = 'Interactive'; stored = 'interactive'; before = $null }
            @{ switch = 'DeviceCode'; stored = 'devicecode'; before = 'interactive' }
        ) {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso $before
            $splat = @{ $switch = $true }
            azswap login @splat | Should -Be 'user@contoso.com  Contoso Prod'
            Get-LoginSetting contoso | Should -Be $stored
            Assert-LoginCall ($stored -eq 'devicecode')
        }

        It 'leaves the stored method alone when the sign-in is <case>' -ForEach @(
            @{ case = 'refused by the guard'; noLogin = $false; refused = $true }
            @{ case = 'refused by -NoLogin'; noLogin = $true; refused = $true }
            @{ case = 'failed'; noLogin = $false; refused = $false }
        ) {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'interactive'
            if ($refused -and -not $noLogin) { Mock Test-AzswapInteractive -ModuleName azswap { $false } }
            if (-not $refused) { Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' } }
            azswap login -DeviceCode -NoLogin:$noLogin -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                Should -BeNullOrEmpty
            Get-LoginRaw contoso | Should -Be 'interactive'
        }
    }

    Context 'refusal message' {
        It 'keeps a one-off -DeviceCode' {
            New-TestProfile contoso 'interactive' | Out-Null
            { azswap contoso -DeviceCode -NoLogin -ErrorAction Stop } |
                Should -Throw '*Run this in your own terminal: azswap contoso -DeviceCode'
        }

        It "keeps -DeviceCode in the 'azswap login' suggestion" {
            $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'interactive'
            { azswap login -DeviceCode -NoLogin -ErrorAction Stop } |
                Should -Throw '*Run this in your own terminal: azswap contoso; azswap login -DeviceCode'
        }

        It 'quotes a profile name that is not a plain token' {
            New-TestProfile "o'brien co" | Out-Null
            { azswap "o'brien co" -NoLogin -ErrorAction Stop } |
                Should -Throw "*Run this in your own terminal: azswap 'o''brien co'"
        }
    }

    Context 'Conditional Access hint' {
        It 'suggests -Interactive when device code sign-in fails, before the failure error' {
            New-TestProfile contoso | Out-Null
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
            $thrown = $null
            try { azswap contoso -ErrorAction Stop -WarningVariable warn -WarningAction SilentlyContinue | Out-Null }
            catch { $thrown = $_ }
            $thrown.FullyQualifiedErrorId | Should -BeLike 'AzswapLoginFailed*'
            $warn | Should -Match 'azswap login -Interactive'
        }

        It 'does not warn when <case>' -ForEach @(
            @{ case = 'interactive sign-in fails'; stored = 'interactive'; fail = $true; noLogin = $false }
            @{ case = 'device code sign-in succeeds'; stored = $null; fail = $false; noLogin = $false }
            @{ case = 'the sign-in is refused'; stored = $null; fail = $false; noLogin = $true }
        ) {
            New-TestProfile contoso $stored | Out-Null
            if ($fail) { Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' } }
            azswap contoso -NoLogin:$noLogin -ErrorAction SilentlyContinue -WarningVariable warn -WarningAction SilentlyContinue | Out-Null
            $warn | Should -BeNullOrEmpty
        }
    }
}
