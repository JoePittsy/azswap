#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    function New-TestProfile([string]$Name, [string]$Tenant) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') $Tenant
        $dir
    }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe 'non-interactive hosts' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null

        Mock Test-AzswapInteractive -ModuleName azswap { $false }
        Mock az -ModuleName azswap { 'user@contoso.com  Contoso Prod' } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    It 'switches but refuses to sign in, naming the command to run' {
        $dir = New-TestProfile contoso 'tid-1'
        { azswap contoso -ErrorAction Stop } | Should -Throw '*non-interactive*Run this in your own terminal: azswap contoso'
        $env:AZURE_CONFIG_DIR | Should -Be $dir
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
    }

    It 'includes -Interactive in the command when it was requested' {
        New-TestProfile contoso 'tid-1' | Out-Null
        { azswap contoso -Interactive -ErrorAction Stop } | Should -Throw '*: azswap contoso -Interactive'
    }

    It 'returns a failing result and prints no account' {
        New-TestProfile contoso 'tid-1' | Out-Null
        $out = azswap contoso -ErrorAction SilentlyContinue -ErrorVariable err
        $out | Should -BeNullOrEmpty
        $err.FullyQualifiedErrorId | Should -Match '^AzswapLoginRefused'
    }

    It 'still switches without error when the token is valid' {
        New-TestProfile contoso 'tid-1' | Out-Null
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        azswap contoso -ErrorAction Stop | Should -Be 'user@contoso.com  Contoso Prod'
    }

    It 'refuses azswap login' {
        $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1'
        { azswap login -ErrorAction Stop } | Should -Throw '*Run this in your own terminal: azswap contoso'
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
    }

    It 'creates a profile with new but does not sign in' {
        { azswap new fabrikam 'tid-2' -ErrorAction Stop } | Should -Throw '*: azswap fabrikam'
        Get-Content (Join-Path $TestDrive '.azure-fabrikam\azswap-tenant') | Should -Be 'tid-2'
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
    }

    It '-NoLogin refuses even in an interactive host' {
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        New-TestProfile contoso 'tid-1' | Out-Null
        { azswap contoso -NoLogin -ErrorAction Stop } | Should -Throw '*-NoLogin was given*: azswap contoso'
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
    }

    It 'quotes an unusual profile name in the suggested command' {
        New-TestProfile 'my co' 'tid-1' | Out-Null
        { azswap 'my co' -ErrorAction Stop } | Should -Throw "*: azswap 'my co'"
    }

    It 'makes the azswap call itself fail and sets LASTEXITCODE' {
        New-TestProfile contoso 'tid-1' | Out-Null
        azswap contoso -ErrorAction SilentlyContinue
        $? | Should -BeFalse
        $LASTEXITCODE | Should -Be 1
    }

    It 'makes azswap new itself fail' {
        azswap new fabrikam 'tid-2' -ErrorAction SilentlyContinue
        $? | Should -BeFalse
    }

    It 'new forwards -NoLogin' {
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        { azswap new fabrikam 'tid-2' -NoLogin -ErrorAction Stop } | Should -Throw '*-NoLogin was given*'
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
    }

    It 'login forwards -NoLogin' {
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1'
        { azswap login -NoLogin -ErrorAction Stop } | Should -Throw '*-NoLogin was given*'
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
    }

    It 'login rejects a config folder that is not an azswap profile' {
        $env:AZURE_CONFIG_DIR = Join-Path $TestDrive '.azure'
        New-Item -ItemType Directory $env:AZURE_CONFIG_DIR | Out-Null
        { azswap login -ErrorAction Stop } | Should -Throw "*isn't an azswap profile*"
    }

    It 'status shows the folder when it is not an azswap profile' {
        $env:AZURE_CONFIG_DIR = Join-Path $TestDrive '.azure'
        azswap | Should -Be "$env:AZURE_CONFIG_DIR  user@contoso.com  Contoso Prod"
    }

    It 'rejects profile names a shell would need to quote' {
        { azswap new 'my co' 'tid-1' -ErrorAction Stop } | Should -Throw 'Profile names can only use*'
        Join-Path $TestDrive '.azure-my co' | Should -Not -Exist
    }

    It 'treats a redirected-input host as non-interactive' {
        # Pester's own host: in CI stdin is redirected, so the real helper must say $false there.
        if (-not [Console]::IsInputRedirected) { Set-ItResult -Skipped -Because 'stdin is not redirected in this run' }
        & (Get-Module azswap) { Test-AzswapInteractive } | Should -BeFalse
    }
}

Describe 'interactive sign-in' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        Mock az -ModuleName azswap { 'user@contoso.com  Contoso Prod' } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    It 'passes az login output straight through, so az keeps the terminal' {
        # A caller that wraps Invoke-AzswapLogin in an expression captures az's stdout, which then stops being a TTY.
        New-TestProfile contoso 'tid-1' | Out-Null
        Mock az -ModuleName azswap { 'az-login-output'; $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
        azswap contoso | Should -Be @('az-login-output', 'user@contoso.com  Contoso Prod')
    }

    It 'stops without the account when az login fails' {
        $dir = New-TestProfile contoso 'tid-1'
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
        azswap contoso | Should -BeNullOrEmpty
        $env:AZURE_CONFIG_DIR = $dir
        azswap login | Should -BeNullOrEmpty
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' } -Times 0 -Exactly
    }

    It 'Invoke-AzswapLogin emits nothing when it refuses' {
        $dir = New-TestProfile contoso 'tid-1'
        & (Get-Module azswap) { param($d) Invoke-AzswapLogin -Dir $d -NoLogin 2>$null } $dir | Should -BeNullOrEmpty
    }
}

Describe 'Test-AzswapNonInteractiveArg' {
    It 'returns <Expected> for <Arguments>' -ForEach @(
        @{ Arguments = @('-NonInteractive'); Expected = $true }
        @{ Arguments = @('-noni', '-NoProfile'); Expected = $true }
        @{ Arguments = @('--noninteractive'); Expected = $true }
        @{ Arguments = @('/NonInteractive'); Expected = $true }
        @{ Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File', 'x.ps1'); Expected = $true }
        @{ Arguments = @('-ex', 'Bypass', '-noni'); Expected = $true }
        @{ Arguments = @(); Expected = $false }
        @{ Arguments = @('-NoProfile', '-NoLogo'); Expected = $false }
        @{ Arguments = @('-File', 'x.ps1', '-nonincremental'); Expected = $false }
        @{ Arguments = @('-f', 'x.ps1', '-NonInteractive'); Expected = $false }
        @{ Arguments = @('x.ps1', '-noninteractive'); Expected = $false }
        @{ Arguments = @('-Command', 'azswap', '-NonInteractive'); Expected = $false }
        @{ Arguments = @('-c', 'azswap -noni'); Expected = $false }
        @{ Arguments = @('-EncodedCommand', 'abc', '-noni'); Expected = $false }
        @{ Arguments = @('-ec', 'abc', '-noni'); Expected = $false }
    ) {
        & (Get-Module azswap) { param($a) Test-AzswapNonInteractiveArg $a } $Arguments | Should -Be $Expected
    }
}

Describe 'process exit code' {
    BeforeAll {
        # A real child PowerShell of the same edition, started with -NonInteractive, with az stubbed
        # inside it: the refusal must make the process exit non-zero.
        $exe = (Get-Process -Id $PID).Path
        $psd1 = (Resolve-Path (Join-Path $PSScriptRoot '..\azswap\azswap.psd1')).Path
        $profileHome = Join-Path $TestDrive 'exitcode'
        New-Item -ItemType Directory -Force (Join-Path $profileHome '.azure-contoso') | Out-Null
        Set-Content (Join-Path $profileHome '.azure-contoso\azswap-tenant') 'tid-1'
        $setup = @(
            "`$env:AZSWAP_HOME = '$profileHome'"
            "Import-Module '$psd1'"
            "function global:az { if (`$args[0] -eq 'login') { throw 'az login was called' }; `$global:LASTEXITCODE = 1 }"
        ) -join "`n"
    }

    It 'exits non-zero from pwsh -Command' {
        $out = & $exe -NoProfile -NonInteractive -Command "$setup`nazswap contoso" 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out | Out-String) | Should -Match 'AzswapLoginRefused|Run this in your own terminal'
    }

    It 'exits non-zero from pwsh -File when the script stops on errors' {
        $file = Join-Path $TestDrive 'refuse.ps1'
        Set-Content $file "`$ErrorActionPreference = 'Stop'`n$setup`nazswap contoso`n'not reached'"
        $out = & $exe -NoProfile -NonInteractive -File $file 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Not -Contain 'not reached'
    }
}
