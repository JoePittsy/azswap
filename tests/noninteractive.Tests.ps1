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
        Mock az -ModuleName azswap { if ($args -notcontains 'user.name') { 'user@contoso.com  Contoso Prod' } } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' } # user.name query (account check): not signed in
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
        { azswap login -ErrorAction Stop } | Should -Throw '*Run this in your own terminal: azswap contoso; azswap login'
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

    It 'rejects the profile name <_>' -ForEach @('my co', '-x', '--help', '.', '..', 'contoso.', "it's") {
        { azswap new $_ 'tid-1' -ErrorAction Stop } | Should -Throw 'Profile names can only use*'
        @(Get-ChildItem $TestDrive -Force).Count | Should -Be 0
    }

    It 'accepts the profile name <_>' -ForEach @('a', 'contoso-dev', 'fabrikam.hr', 'x_1') {
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        azswap new $_ 'tid-1' -ErrorAction Stop | Out-Null
        Join-Path $TestDrive ".azure-$_\azswap-tenant" | Should -Exist
    }

    It 'makes azswap login itself fail' {
        $env:AZURE_CONFIG_DIR = New-TestProfile contoso 'tid-1'
        azswap login -ErrorAction SilentlyContinue
        $? | Should -BeFalse
    }

    It 'sets LASTEXITCODE to 1 on refusal' {
        # Called directly: through azswap, the failed token check has already set it.
        $dir = New-TestProfile contoso 'tid-1'
        $global:LASTEXITCODE = 0
        & (Get-Module azswap) { param($d) $ErrorActionPreference = 'SilentlyContinue'; Invoke-AzswapLogin -Dir $d -NoLogin } $dir
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'says so when the folder is not an azswap profile, instead of a blank command' {
        $out = & (Get-Module azswap) { param($d) $ErrorActionPreference = 'Continue'; Invoke-AzswapLogin -Dir $d -NoLogin 2>&1 } (Join-Path $TestDrive '.azure')
        "$out" | Should -BeLike "*isn't an azswap profile*"
        "$out" | Should -Not -BeLike '*azswap  *'
    }
}

Describe 'Test-AzswapInteractive' {
    # Each signal on its own must make the host non-interactive; the baseline proves the others are off.
    BeforeAll {
        $ciVars = 'CI', 'GITHUB_ACTIONS', 'TF_BUILD'
        $savedCi = @{}
        foreach ($v in $ciVars) { $savedCi[$v] = [Environment]::GetEnvironmentVariable($v); [Environment]::SetEnvironmentVariable($v, $null) }
        $interactive = @{ UserInteractive = $true; InputRedirected = $false; HostArgs = @('-NoProfile') }
        function Test-It([hashtable]$Overrides) {
            $p = $interactive.Clone(); foreach ($k in $Overrides.Keys) { $p[$k] = $Overrides[$k] }
            & (Get-Module azswap) { param($p) Test-AzswapInteractive @p } $p
        }
    }

    AfterAll {
        foreach ($v in $ciVars) { [Environment]::SetEnvironmentVariable($v, $savedCi[$v]) }
    }

    It 'is interactive with no signal' { Test-It @{} | Should -BeTrue }
    It 'is not interactive when the process is not user-interactive' { Test-It @{ UserInteractive = $false } | Should -BeFalse }
    It 'is not interactive when stdin is redirected' { Test-It @{ InputRedirected = $true } | Should -BeFalse }
    It 'is not interactive under -NonInteractive' { Test-It @{ HostArgs = @('-NonInteractive') } | Should -BeFalse }

    It 'is not interactive when <_> is true' -ForEach @('CI', 'GITHUB_ACTIONS', 'TF_BUILD') {
        [Environment]::SetEnvironmentVariable($_, 'true')
        try { Test-It @{} | Should -BeFalse } finally { [Environment]::SetEnvironmentVariable($_, $null) }
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
        Mock az -ModuleName azswap { if ($args -notcontains 'user.name') { 'user@contoso.com  Contoso Prod' } } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' }
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
        azswap contoso -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $env:AZURE_CONFIG_DIR = $dir
        azswap login -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'show' } -Times 0 -Exactly
    }

    It 'fails the call when az login fails, like a refusal' {
        New-TestProfile contoso 'tid-1' | Out-Null
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 3 } -ParameterFilter { $args[0] -eq 'login' }
        azswap contoso -ErrorAction SilentlyContinue -ErrorVariable err
        $? | Should -BeFalse
        $LASTEXITCODE | Should -Be 3
        "$err" | Should -Be "Sign-in failed for 'contoso'."
    }

    It 'Invoke-AzswapLogin emits nothing when it refuses' {
        $dir = New-TestProfile contoso 'tid-1'
        # CI runs with $ErrorActionPreference = 'Stop'; this test is only about pipeline output.
        & (Get-Module azswap) { param($d) $ErrorActionPreference = 'SilentlyContinue'; Invoke-AzswapLogin -Dir $d -NoLogin } $dir |
            Should -BeNullOrEmpty
    }

    It 'Invoke-AzswapLogin falls back to Write-Error without -Cmdlet' {
        $dir = New-TestProfile contoso 'tid-1'
        $out = & (Get-Module azswap) { param($d) $ErrorActionPreference = 'Continue'; Invoke-AzswapLogin -Dir $d -NoLogin 2>&1 } $dir
        $out.FullyQualifiedErrorId | Should -Match '^AzswapLoginRefused'
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
        @{ Arguments = @('-CommandWithArgs', 'x', '-noni'); Expected = $false }
        @{ Arguments = @('-config', 'x', '-noni'); Expected = $true }
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
        # Windows PowerShell turns the child's stderr into errors, which 'Stop' (as in CI) would throw.
        $ErrorActionPreference = 'Continue'
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

Describe 'native az' {
    # A real az script on PATH that writes to stderr, so Windows PowerShell's native-stderr handling
    # (errors recorded despite 2>$null, terminating under 'Stop') is actually exercised. The
    # preference is set globally, as in CI or a user's profile: module functions don't see a
    # caller's local preference.
    BeforeAll {
        $stubDir = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Force $stubDir | Out-Null
        if ($IsLinux -or $IsMacOS) {
            $stub = Join-Path $stubDir 'az'
            $lines = @(
                '#!/bin/sh'
                'case "$1 $2" in'
                '  "account get-access-token") echo "Please run ''az login'' to setup account." >&2; exit "${AZSTUB_TOKEN_EXIT:-1}";;'
                '  "account show") echo "user@contoso.com  Contoso Prod"; exit 0;;'
                'esac'
                'if [ "$1" = login ]; then echo "login on stderr" >&2; exit "${AZSTUB_LOGIN_EXIT:-0}"; fi'
                'exit 9'
            )
            [IO.File]::WriteAllText($stub, ($lines -join "`n") + "`n")
            chmod +x $stub
        } else {
            $lines = @(
                '@echo off'
                'if "%1 %2"=="account get-access-token" ( echo Please run ''az login'' to setup account. 1>&2 & exit /b %AZSTUB_TOKEN_EXIT% )'
                'if "%1 %2"=="account show" ( echo user@contoso.com  Contoso Prod& exit /b 0 )'
                'if "%1"=="login" ( echo login on stderr 1>&2 & exit /b %AZSTUB_LOGIN_EXIT% )'
                'exit /b 9'
            )
            Set-Content (Join-Path $stubDir 'az.cmd') $lines -Encoding Ascii
        }
        $savedPath = $env:PATH
        $env:PATH = $stubDir + [IO.Path]::PathSeparator + $env:PATH
        # Let 'az' resolve to the script, not the suite's function stand-in.
        while (Test-Path function:az) { Remove-Item function:az }
    }

    AfterAll {
        $env:PATH = $savedPath
        function global:az { throw "Unmocked az call: $args" }
    }

    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        $savedPref = $global:ErrorActionPreference
        Get-ChildItem $TestDrive -Exclude 'bin' -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null
        $env:AZSTUB_TOKEN_EXIT = '1'
        $env:AZSTUB_LOGIN_EXIT = '0'
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
        $global:ErrorActionPreference = $savedPref
        Remove-Item env:AZSTUB_TOKEN_EXIT, env:AZSTUB_LOGIN_EXIT -ErrorAction SilentlyContinue
    }

    It 'resolves az to the stub' {
        (Get-Command az).Source | Should -BeLike "$stubDir*"
    }

    It 'a successful azswap new succeeds despite the expired-token stderr' {
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        $global:ErrorActionPreference = 'Continue'
        $out = azswap new fabrikam 'tid-2'
        $? | Should -BeTrue
        $out | Should -Be 'user@contoso.com  Contoso Prod'
    }

    It "a successful azswap new succeeds under 'Stop'" {
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        $global:ErrorActionPreference = 'Stop'
        azswap new fabrikam 'tid-2' | Should -Be 'user@contoso.com  Contoso Prod'
    }

    It "refuses with the command to run under 'Stop', not the token check's stderr" {
        Mock Test-AzswapInteractive -ModuleName azswap { $false }
        New-TestProfile contoso 'tid-1' | Out-Null
        $global:ErrorActionPreference = 'Stop'
        { azswap contoso } | Should -Throw '*Run this in your own terminal: azswap contoso'
    }

    It 'fails the call when the real az login exits non-zero' {
        Mock Test-AzswapInteractive -ModuleName azswap { $true }
        New-TestProfile contoso 'tid-1' | Out-Null
        $env:AZSTUB_LOGIN_EXIT = '1'
        $global:ErrorActionPreference = 'Continue'
        azswap contoso -ErrorVariable err 2>$null
        $? | Should -BeFalse
        $LASTEXITCODE | Should -Be 1
        $err.FullyQualifiedErrorId | Should -Contain 'AzswapLoginFailed,azswap'
    }
}
