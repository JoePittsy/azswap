#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force

    # Stand-in for the Azure CLI; anything not mocked fails loudly instead of signing in.
    function global:az { throw "Unmocked az call: $args" }

    function New-TestProfile([string]$Name) {
        $dir = Join-Path $TestDrive ".azure-$Name"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content (Join-Path $dir 'azswap-tenant') 'tid-1'
        $dir
    }

    # The script inside a child command line from Get-AzswapSignInCommand.
    function ConvertFrom-ChildArgs([string[]]$ChildArgs) {
        $ChildArgs[0] | Should -Be '-NoProfile'
        $ChildArgs[1] | Should -Be '-EncodedCommand'
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ChildArgs[2]))
    }
}

AfterAll {
    Remove-Item function:global:az -ErrorAction SilentlyContinue
    Remove-Module azswap -ErrorAction SilentlyContinue
}

Describe '-NewWindow' {
    BeforeEach {
        $savedHome = $env:AZSWAP_HOME
        $savedConfig = $env:AZURE_CONFIG_DIR
        Get-ChildItem $TestDrive -Force | Remove-Item -Recurse -Force
        $env:AZSWAP_HOME = $TestDrive
        $env:AZURE_CONFIG_DIR = $null

        # The calling process is an agent: non-interactive. It must never sign in or open a real window.
        Mock Test-AzswapInteractive -ModuleName azswap { $false }
        Mock Test-AzswapWindows -ModuleName azswap { $true }
        Mock Open-AzswapSignInWindow -ModuleName azswap { }
        Mock Start-Process -ModuleName azswap { throw 'Start-Process must not run in tests' }
        Mock az -ModuleName azswap { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'account' }
        Mock az -ModuleName azswap { throw 'az login must not run in the calling process' } -ParameterFilter { $args[0] -eq 'login' }
    }

    AfterEach {
        $env:AZSWAP_HOME = $savedHome
        $env:AZURE_CONFIG_DIR = $savedConfig
    }

    It 'switch: switches this shell, opens the window for the profile and returns at once' {
        $dir = New-TestProfile contoso
        azswap contoso -NewWindow -Interactive -Account 'a@contoso.com' -ErrorAction Stop |
            Should -Be "Opened a sign-in window for 'contoso'. Finish signing in there, then carry on."
        $env:AZURE_CONFIG_DIR | Should -Be $dir
        Should -Invoke Open-AzswapSignInWindow -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
            $Dir -eq $dir -and $Name -eq 'contoso' -and -not $Login -and $Interactive -and -not $DeviceCode -and $Account -eq 'a@contoso.com'
        }
        Should -Invoke az -ModuleName azswap -Times 0 -Exactly
    }

    It 'login: opens a window that runs azswap login on the current profile' {
        $env:AZURE_CONFIG_DIR = New-TestProfile contoso
        azswap login -NewWindow -DeviceCode -ErrorAction Stop | Should -BeLike "Opened a sign-in window for 'contoso'*"
        Should -Invoke Open-AzswapSignInWindow -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
            $Dir -eq $env:AZURE_CONFIG_DIR -and $Login -and $DeviceCode -and -not $Interactive -and -not $Account
        }
        Should -Invoke az -ModuleName azswap -Times 0 -Exactly
    }

    It 'new: creates the profile, switches to it, and leaves recording the method to the window' {
        azswap new fabrikam 'tid-2' -NewWindow -Interactive -Account 'me@fabrikam.com' -ErrorAction Stop |
            Should -BeLike "Opened a sign-in window for 'fabrikam'*"
        $dir = Join-Path $TestDrive '.azure-fabrikam'
        Get-Content (Join-Path $dir 'azswap-tenant') | Should -Be 'tid-2'
        Get-Content (Join-Path $dir 'azswap-account') | Should -Be 'me@fabrikam.com'
        Join-Path $dir 'azswap-login' | Should -Not -Exist
        $env:AZURE_CONFIG_DIR | Should -Be $dir
        Should -Invoke Open-AzswapSignInWindow -ModuleName azswap -Times 1 -Exactly -ParameterFilter {
            $Dir -eq $dir -and $Login -and $Interactive -and $Account -eq 'me@fabrikam.com'
        }
        Should -Invoke az -ModuleName azswap -Times 0 -Exactly
    }

    It 'is a usage error with <_>' -ForEach @(
        'contoso -NoLogin', 'login -NoLogin', 'list', 'import', 'help', '-Help', 'run', 'status'
    ) {
        $env:AZURE_CONFIG_DIR = New-TestProfile contoso
        $splat = switch ($_) {
            'contoso -NoLogin' { @{ Command = 'contoso'; NoLogin = $true } }
            'login -NoLogin' { @{ Command = 'login'; NoLogin = $true } }
            '-Help' { @{ Help = $true } }
            'run' { @{ Command = 'run'; Target = 'contoso'; Tenant = 'az' } }
            'status' { @{} }
            default { @{ Command = $_ } }
        }
        azswap @splat -NewWindow -ErrorAction SilentlyContinue -ErrorVariable err
        $? | Should -BeFalse
        $err.FullyQualifiedErrorId | Should -Match '^AzswapNewWindowUsage'
        Should -Invoke Open-AzswapSignInWindow -ModuleName azswap -Times 0 -Exactly
    }

    It 'fails on macOS and Linux with the command to run instead' {
        Mock Test-AzswapWindows -ModuleName azswap { $false }
        New-TestProfile contoso | Out-Null
        azswap contoso -NewWindow -ErrorAction SilentlyContinue -ErrorVariable err
        $? | Should -BeFalse
        $LASTEXITCODE | Should -Be 1
        "$err" | Should -Be "-NewWindow isn't supported on this platform yet; run 'azswap contoso' in a terminal."
        { azswap new fabrikam 'tid-2' -NewWindow -ErrorAction Stop } | Should -Throw "*run 'azswap new fabrikam tid-2' in a terminal."
        Join-Path $TestDrive '.azure-fabrikam' | Should -Not -Exist
        Should -Invoke Open-AzswapSignInWindow -ModuleName azswap -Times 0 -Exactly
    }

    It 'Test-AzswapWindows matches the real platform' {
        $onWindows = $env:OS -eq 'Windows_NT'
        & (Get-Module azswap) { Test-AzswapWindows } | Should -Be $onWindows
    }

    It 'the refusal suggests -NewWindow on Windows' {
        New-TestProfile contoso | Out-Null
        { azswap contoso -Interactive -ErrorAction Stop } | Should -Throw '*: azswap contoso -Interactive (or: azswap contoso -Interactive -NewWindow)'
        $env:AZURE_CONFIG_DIR = Join-Path $TestDrive '.azure-contoso'
        { azswap login -ErrorAction Stop } | Should -Throw '*: azswap contoso; azswap login (or: azswap login -NewWindow)'
    }

    It 'the refusal does not suggest -NewWindow elsewhere' {
        Mock Test-AzswapWindows -ModuleName azswap { $false }
        New-TestProfile contoso | Out-Null
        azswap contoso -ErrorAction SilentlyContinue -ErrorVariable err
        "$err" | Should -Not -BeLike '*NewWindow*'
    }
}

Describe 'Get-AzswapSignInCommand' {
    BeforeEach { $savedHome = $env:AZSWAP_HOME }
    AfterEach { $env:AZSWAP_HOME = $savedHome }

    It 'builds a -NoProfile command that imports this module and runs the switch' {
        $env:AZSWAP_HOME = $null
        $script = ConvertFrom-ChildArgs (& (Get-Module azswap) { Get-AzswapSignInCommand -Dir 'C:\h\.azure-contoso' -Name 'contoso' -Interactive })
        $psd1 = Join-Path (Get-Module azswap).ModuleBase 'azswap.psd1'
        $script | Should -BeLike "*Import-Module '$psd1'*"
        $script | Should -BeLike "*`$env:AZURE_CONFIG_DIR = 'C:\h\.azure-contoso'*"
        $script | Should -Match "(?m)^azswap 'contoso' -Interactive$"
        $script | Should -BeLike '*ReadKey*'
        $script | Should -Not -BeLike '*AZSWAP_HOME =*'
    }

    It 'runs azswap login with -Login, passing -DeviceCode, -Account and AZSWAP_HOME' {
        $env:AZSWAP_HOME = 'D:\profiles'
        $script = ConvertFrom-ChildArgs (& (Get-Module azswap) { Get-AzswapSignInCommand -Dir 'D:\x' -Name 'contoso' -Login -DeviceCode -Account 'me@contoso.com' })
        $script | Should -Match "(?m)^azswap login -DeviceCode -Account 'me@contoso.com'$"
        $script | Should -BeLike "*`$env:AZSWAP_HOME = 'D:\profiles'*"
    }

    It 'quotes paths with spaces and apostrophes so they survive' {
        # Run the generated assignments in a child scope and read the values back.
        # Curly quotes too: PowerShell treats them as single quotes. Written as code points so the
        # file stays ASCII for Windows PowerShell.
        $weird = "C:\Users\Jo O'Brien\My $([char]0x2018)Docs$([char]0x2019)\.azure-contoso"
        $env:AZSWAP_HOME = "C:\Jo O'Brien"
        $script = ConvertFrom-ChildArgs (& (Get-Module azswap) { param($d) Get-AzswapSignInCommand -Dir $d -Name 'contoso' -Account "o'brien@contoso.com" } $weird)
        $lines = $script -split "`n"
        $assign = ($lines | Where-Object { $_ -like '$env:AZ*=*' }) -replace '\$env:', '$v_'
        $values = & ([scriptblock]::Create(($assign -join "`n") + "`n" + '$v_AZSWAP_HOME; $v_AZURE_CONFIG_DIR'))
        $values | Should -Be @("C:\Jo O'Brien", $weird)
        $call = $lines | Where-Object { $_ -like 'azswap *' }
        $tokens = $null
        [Management.Automation.Language.Parser]::ParseInput($call, [ref]$tokens, [ref]$null) | Out-Null
        ($tokens | Where-Object Kind -eq 'StringLiteral').Value | Should -Be @('contoso', "o'brien@contoso.com")
    }

    It 'quotes a module path containing spaces and an apostrophe' {
        # A copy of the module under such a path, so $PSScriptRoot itself has them.
        $dir = Join-Path $TestDrive "Jo O'Brien's modules\azswap"
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item (Join-Path (Get-Module azswap).ModuleBase '*') $dir
        $copy = Import-Module (Join-Path $dir 'azswap.psd1') -PassThru -Force
        try {
            $script = ConvertFrom-ChildArgs (& $copy { Get-AzswapSignInCommand -Dir 'C:\x' -Name 'contoso' })
            $import = ($script -split "`n") | Where-Object { $_ -like 'Import-Module *' }
            $tokens = $null
            [Management.Automation.Language.Parser]::ParseInput($import, [ref]$tokens, [ref]$null) | Out-Null
            ($tokens | Where-Object Kind -eq 'StringLiteral').Value | Should -Be (Join-Path $dir 'azswap.psd1')
        } finally {
            Remove-Module $copy
            Import-Module (Join-Path $PSScriptRoot '..\azswap\azswap.psd1') -Force
        }
    }
}
