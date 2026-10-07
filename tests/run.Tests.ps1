#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:psd1 = Join-Path $PSScriptRoot '..\azswap\azswap.psd1'
    Import-Module $psd1 -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    # The exact refusal text, without the Windows-only -NewWindow hint (new-window.Tests.ps1 covers it).
    Mock Test-AzswapWindows -ModuleName azswap { $false }

    # 'run' only runs executables, so the command under test is a child PowerShell process
    # (pwsh or powershell.exe, whichever runs the tests) running echo.ps1, which prints the
    # profile and its arguments and leaves a 'ran' file behind.
    $script:pwsh = (Get-Process -Id $PID).Path
    function global:Invoke-AzswapTestFunction { 'ran' }
    Set-Alias -Name azswap-test-alias -Value Get-ChildItem -Scope Global

    function New-TestProfile([string]$Name, [string]$Expected) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') 'tid-1'
        if ($Expected) { Set-Content (Join-Path $dir 'azswap-account') $Expected }
        $dir
    }

    # Runs a failing azswap call and returns its error record, whatever $ErrorActionPreference is.
    function Get-RunError([scriptblock]$Call) {
        try { & $Call } catch { return $_ }
        throw 'Expected the call to fail.'
    }
}

AfterAll {
    Remove-Item function:global:az, function:global:Invoke-AzswapTestFunction, alias:azswap-test-alias -ErrorAction SilentlyContinue
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
        $echo = Join-Path $TestDrive 'echo.ps1'
        $ran = Join-Path $TestDrive 'ran'
        Set-Content $echo @'
Set-Content (Join-Path $PSScriptRoot 'ran') 'ran'
"dir=$env:AZURE_CONFIG_DIR"
foreach ($a in $args) { "[$a]" }
'@

        # Pester runs non-interactive; sign-in tests are about an interactive shell.
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

    Context 'running' {
        It 'runs the command under the profile, then restores the previous profile' {
            azswap run contoso -- $pwsh -NoProfile -File $echo | Should -Be "dir=$dir"
            $LASTEXITCODE | Should -Be 0
            $env:AZURE_CONFIG_DIR | Should -Be $other
            Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
        }

        It 'leaves AZURE_CONFIG_DIR unset when it was unset' {
            $env:AZURE_CONFIG_DIR = $null
            azswap run contoso -- $pwsh -NoProfile -File $echo | Should -Be "dir=$dir"
            Test-Path env:AZURE_CONFIG_DIR | Should -BeFalse
        }

        It 'passes dash-prefixed arguments through, and drops $null' {
            $out = azswap run contoso -- $pwsh -NoProfile -File $echo account --query user.name -o tsv -Interactive -NoLogin
            $out | Should -Be @("dir=$dir", '[account]', '[--query]', '[user.name]', '[-o]', '[tsv]', '[-Interactive]', '[-NoLogin]')
            azswap run contoso -- $pwsh -NoProfile -File $echo a $null 1 | Should -Be @("dir=$dir", '[a]', '[1]')
        }

        It 'preserves a failing exit code and reports it as an error' {
            $out = azswap run contoso -ErrorAction SilentlyContinue -ErrorVariable err -- $pwsh -NoProfile -Command 'exit 3'
            $out | Should -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 3
            $err.FullyQualifiedErrorId | Should -Contain 'AzswapRunCommandFailed,azswap'
            (Get-RunError { azswap run contoso -ErrorAction Stop -- $pwsh -NoProfile -Command 'exit 3' }).Exception.Message |
                Should -BeLike '*exited with code 3.'
            $LASTEXITCODE | Should -Be 3
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'makes pwsh -Command exit <code> for <name>' -ForEach @(
            @{ name = 'a passing command'; signedIn = 'me@contoso.com'; exit = 0; code = 0 }
            @{ name = 'a failing command'; signedIn = 'me@contoso.com'; exit = 3; code = 1 }
            @{ name = 'a wrong account'; signedIn = 'someone@else.com'; exit = 0; code = 1 }
        ) {
            $setup = Join-Path $TestDrive 'setup.ps1'
            Set-Content $setup @"
Import-Module '$psd1'
`$env:AZSWAP_HOME = '$TestDrive'
function global:az { `$global:LASTEXITCODE = 0; if (`$args -contains 'user.name') { '$signedIn' } }
"@
            $ErrorActionPreference = 'Continue' # Windows PowerShell turns the child's stderr into errors
            & $pwsh -NoProfile -NonInteractive -Command ". '$setup'; azswap run contoso -WarningAction SilentlyContinue -- '$pwsh' -NoProfile -Command 'exit $exit'" 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be $code
        }
    }

    Context 'signing in' {
        BeforeEach {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
        }

        It 'signs in under the profile first when the token has expired' {
            Mock az -ModuleName azswap { $global:loginDir = $env:AZURE_CONFIG_DIR; $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'login' }
            azswap run contoso -Interactive -- $pwsh -NoProfile -File $echo | Should -Be "dir=$dir"
            $global:loginDir | Should -Be $dir
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'login' -and ($args -join ' ') -match '--tenant tid-1 ' -and $args -notcontains '--use-device-code'
            }
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'passes -DeviceCode through to the sign-in' {
            Set-Content (Join-Path $dir 'azswap-login') 'interactive'
            azswap run contoso -DeviceCode -- $pwsh -NoProfile -File $echo | Out-Null
            Should -Invoke az -ModuleName azswap -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'login' -and $args -contains '--use-device-code' }
        }

        It 'fails, without running the command, when sign-in fails' {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
            (Get-RunError { azswap run contoso -ErrorAction Stop -WarningAction SilentlyContinue -- $pwsh -NoProfile -File $echo }).Exception.Message |
                Should -Be "Sign-in failed for 'contoso'."
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Not -Be 0
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'refuses to sign in with -NoLogin and does not run the command' {
            (Get-RunError { azswap run contoso -NoLogin -ErrorAction Stop -- $pwsh -NoProfile -File $echo }).Exception.Message |
                Should -BeLike '*-NoLogin was given*: azswap contoso'
            Test-Path $ran | Should -BeFalse
            Should -Invoke az -ModuleName azswap -ParameterFilter { $args[0] -eq 'login' } -Times 0 -Exactly
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'refuses to sign in in a non-interactive host and does not run the command' {
            Mock Test-AzswapInteractive -ModuleName azswap { $false }
            (Get-RunError { azswap run contoso -ErrorAction Stop -- $pwsh -NoProfile -File $echo }).Exception.Message |
                Should -BeLike '*non-interactive*: azswap contoso'
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }
    }

    Context 'account check' {
        It 'refuses to run the command as the wrong account' {
            $script:signedIn = 'someone@else.com'
            $e = Get-RunError { azswap run contoso -ErrorAction Stop -WarningAction SilentlyContinue -- $pwsh -NoProfile -File $echo }
            $e.Exception.Message | Should -Be "Wrong account for 'contoso', so '$pwsh' was not run."
            $e.FullyQualifiedErrorId | Should -Be 'AzswapWrongAccount,azswap'
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'warns but runs, without recording, when the profile has no expected account' {
            Remove-Item (Join-Path $dir 'azswap-account')
            azswap run contoso -WarningVariable w -WarningAction SilentlyContinue -- $pwsh -NoProfile -File $echo | Should -Be "dir=$dir"
            "$w" | Should -BeLike "No expected account for 'contoso'*"
            Test-Path (Join-Path $dir 'azswap-account') | Should -BeFalse
        }
    }

    # Under the default preference an error doesn't stop azswap, so only its own 'return' keeps
    # the command from running.
    Context 'never runs the command, with errors not stopping' {
        BeforeEach { $ErrorActionPreference = 'Continue' }

        It 'after a failed sign-in' {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'login' }
            azswap run contoso -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -- $pwsh -NoProfile -File $echo | Should -BeNullOrEmpty
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Not -Be 0
        }

        It 'after a refused sign-in' {
            Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' -and $args[1] -eq 'get-access-token' }
            azswap run contoso -NoLogin -ErrorAction SilentlyContinue -- $pwsh -NoProfile -File $echo | Should -BeNullOrEmpty
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
        }

        It 'as the wrong account' {
            $script:signedIn = 'someone@else.com'
            azswap run contoso -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -- $pwsh -NoProfile -File $echo | Should -BeNullOrEmpty
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
        }

        It 'for a PowerShell script' {
            azswap run contoso -ErrorAction SilentlyContinue -- $echo -DryRun | Should -BeNullOrEmpty
            Test-Path $ran | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
        }
    }

    Context 'errors' {
        It 'refuses PowerShell commands (<_>), which would misbind -Switch arguments' -ForEach @('Get-ChildItem', 'azswap-test-alias', 'Invoke-AzswapTestFunction', 'ECHO_SCRIPT') {
            $name = if ($_ -eq 'ECHO_SCRIPT') { $echo } else { $_ }
            $e = Get-RunError { azswap run contoso -ErrorAction Stop -- $name -DryRun }
            $e.FullyQualifiedErrorId | Should -Be 'AzswapRunNotExecutable,azswap'
            $e.Exception.Message | Should -BeLike '*only runs executables*pwsh -NoProfile -File*'
            Test-Path $ran | Should -BeFalse
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
            $LASTEXITCODE | Should -Be 1
        }

        It 'runs the executable when a same-named script shadows it (npm-style shims)' {
            $bin = Join-Path $TestDrive 'bin'
            New-Item -ItemType Directory $bin | Out-Null
            Set-Content (Join-Path $bin 'azswapshim.ps1') "'script'"
            if ($env:OS -eq 'Windows_NT') { Set-Content (Join-Path $bin 'azswapshim.cmd') '@echo executable' }
            else { Set-Content (Join-Path $bin 'azswapshim') "#!/bin/sh`necho executable"; chmod +x (Join-Path $bin 'azswapshim') }
            $savedPath = $env:PATH
            try {
                $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
                azswap run contoso -- azswapshim | Should -Be 'executable'
            } finally { $env:PATH = $savedPath }
        }

        It 'errors on a command that does not exist' {
            $e = Get-RunError { azswap run contoso -ErrorAction Stop -- no-such-command-azswap }
            $e.FullyQualifiedErrorId | Should -Be 'AzswapRunCommandNotFound,azswap'
            $LASTEXITCODE | Should -Be 1
            $env:AZURE_CONFIG_DIR | Should -Be $other
        }

        It 'errors on an unknown profile' {
            $e = Get-RunError { azswap run nope -ErrorAction Stop -- $pwsh -NoProfile -File $echo }
            $e.Exception.Message | Should -BeLike "Unknown profile 'nope'*"
            $e.FullyQualifiedErrorId | Should -Be 'AzswapUnknownProfile,azswap'
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
            $LASTEXITCODE | Should -Be 1
        }

        It 'errors when the profile or command is missing' {
            (Get-RunError { azswap run -ErrorAction Stop }).Exception.Message | Should -BeLike 'Usage: azswap run*'
            (Get-RunError { azswap run contoso -ErrorAction Stop }).Exception.Message | Should -BeLike 'Usage: azswap run*'
            (Get-RunError { azswap run contoso -ErrorAction Stop -- }).Exception.Message | Should -BeLike 'Usage: azswap run*'
            $LASTEXITCODE | Should -Be 1
        }

        It 'rejects -<_> with run' -ForEach @('Apply', 'FromDefault', 'Only') {
            $extra = @{ $_ = $(if ($_ -eq 'Only') { 'x' } else { $true }) }
            (Get-RunError { azswap run contoso @extra -ErrorAction Stop -- $pwsh -NoProfile -File $echo }).Exception.Message |
                Should -BeLike 'Usage: azswap run*'
            Test-Path $ran | Should -BeFalse
        }

        It 'rejects -Account with run' {
            (Get-RunError { azswap run contoso -Account a@b.com -ErrorAction Stop -- $pwsh -NoProfile -File $echo }).Exception.Message |
                Should -BeLike '-Account works with*'
        }
    }

    Context 'extra arguments for other commands' {
        It 'rejects: azswap <_>' -ForEach @('list x', "list ''", 'login x', 'import x', 'help x', 'contoso x', 'contoso x y', 'new a b c', 'x y z w') {
            $words = @($_ -split ' ' | ForEach-Object { if ($_ -eq "''") { '' } else { $_ } })
            (Get-RunError { azswap @words -ErrorAction Stop }).Exception.Message | Should -BeLike 'Too many arguments. Usage: azswap*'
            Test-Path (Join-Path $TestDrive '.azure-a') | Should -BeFalse
            $env:AZURE_CONFIG_DIR | Should -Be $other
            Should -Invoke az -ModuleName azswap -Times 0 -Exactly
        }

        It 'still accepts the right number: azswap <_>' -ForEach @('list', 'contoso', 'help') {
            { azswap $_ -ErrorAction Stop } | Should -Not -Throw
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
