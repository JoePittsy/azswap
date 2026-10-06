# azswap - per-customer Azure CLI profiles.
# Each profile is <root>/.azure-<name> (an AZURE_CONFIG_DIR); its tenant id is in azswap-tenant inside it.
# <root> is $env:AZSWAP_HOME if set, otherwise $HOME.

$script:Usage = @'
azswap - per-customer Azure CLI profiles

Usage:
  azswap                            Show the current profile and signed-in account
  azswap <profile> [-Interactive]   Switch profile; sign in if the token has expired
  azswap list                       List profiles with account, subscription and tenant
  azswap new <profile> <tenant>     Create a profile and sign in
  azswap login [-Interactive]       Sign in to the current profile again
  azswap help                       Show this help (also -h, --help)

Options:
  -Interactive   Browser (WAM) sign-in instead of device code. Needed where
                 Conditional Access blocks device code.

Each profile is ~/.azure-<profile>; its tenant id is in azswap-tenant inside it.
'@

$script:Commands = 'list', 'new', 'login', 'help'

function Get-AzswapRoot {
    if ($env:AZSWAP_HOME) { $env:AZSWAP_HOME } else { $HOME }
}

function Get-AzswapProfile {
    Get-ChildItem (Get-AzswapRoot) -Directory -Filter '.azure-*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'azswap-tenant') }
}

function azswap {
    <#
    .SYNOPSIS
        Switch between per-customer Azure CLI profiles in the current shell.

    .DESCRIPTION
        Each profile is a folder, ~/.azure-<profile>, used as AZURE_CONFIG_DIR, with the
        profile's tenant id stored in an azswap-tenant file inside it. Switching sets
        $env:AZURE_CONFIG_DIR for the current session, checks the token, signs in to the
        profile's tenant if it has expired, and prints the signed-in account.

        Commands: (none) shows the current profile; <profile> switches; list, new, login
        and help. Run 'azswap help' for a one-screen summary.

        Profile folders live in $HOME, or in $env:AZSWAP_HOME if that is set.

    .PARAMETER Command
        A profile name to switch to, or one of: list, new, login, help. Omit it to show
        the current profile and account.

    .PARAMETER Target
        For 'new': the name of the profile to create.

    .PARAMETER Tenant
        For 'new': the tenant id or domain the profile signs in to.

    .PARAMETER Interactive
        Browser (WAM) sign-in instead of device code. Needed where Conditional Access
        blocks device code.

    .PARAMETER Help
        Show the usage summary (same as 'azswap help', -h or --help).

    .EXAMPLE
        azswap contoso

        Switches this shell to the contoso profile, signing in with a device code if the
        token has expired.

    .EXAMPLE
        azswap new fabrikam fabrikam.onmicrosoft.com -Interactive

        Creates the fabrikam profile for that tenant and signs in through the browser.

    .EXAMPLE
        azswap list

        Lists every profile with its account, default subscription and tenant. The
        current profile is marked with *.

    .EXAMPLE
        azswap

        Shows the current profile and signed-in account.

    .LINK
        https://github.com/JoePittsy/azswap
    #>
    # Deliberately not Verb-Noun: it is a CLI typed constantly. ScriptAnalyzer only checks
    # dashed names, so this needs no suppression.
    param(
        [Parameter(Position = 0)] [string]$Command,
        [Parameter(Position = 1)] [string]$Target,
        [Parameter(Position = 2)] [string]$Tenant,
        [switch]$Interactive,
        [Alias('h')] [switch]$Help
    )

    $show = { az account show --query "join('  ', [user.name, name])" -o tsv }
    $login = {
        param($dir)
        $loginArgs = @('login', '--tenant', (Get-Content (Join-Path $dir 'azswap-tenant')).Trim(), '-o', 'none')
        if (-not $Interactive) { $loginArgs += '--use-device-code' }
        az @loginArgs
    }

    if ($Help -or $Command -in 'help', '--help') { return $script:Usage }

    switch ($Command) {
        '' {
            if (-not $env:AZURE_CONFIG_DIR) { return "No profile selected; az is using ~/.azure. Run 'azswap list'." }
            return "$((Split-Path $env:AZURE_CONFIG_DIR -Leaf).Substring(7))  $(& $show)"
        }
        'list' {
            return Get-AzswapProfile | ForEach-Object {
                $p = Get-Content (Join-Path $_.FullName 'azureProfile.json') -Raw -ErrorAction SilentlyContinue |
                    ConvertFrom-Json -ErrorAction SilentlyContinue
                $sub = $p.subscriptions | Where-Object isDefault | Select-Object -First 1
                [pscustomobject]@{
                    ' '          = if ($_.FullName -eq $env:AZURE_CONFIG_DIR) { '*' } else { '' }
                    Profile      = $_.Name.Substring(7)
                    Account      = $sub.user.name
                    Subscription = $sub.name
                    Tenant       = (Get-Content (Join-Path $_.FullName 'azswap-tenant')).Trim()
                }
            } | Format-Table -AutoSize
        }
        'new' {
            if (-not $Target -or -not $Tenant) { return Write-Error 'Usage: azswap new <profile> <tenant>' }
            if ($Target -in $script:Commands) { return Write-Error "'$Target' is a command name; pick another profile name." }
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Target"
            if (Test-Path (Join-Path $dir 'azswap-tenant')) { return Write-Error "Profile '$Target' already exists." }
            New-Item -ItemType Directory -Force $dir | Out-Null
            Set-Content (Join-Path $dir 'azswap-tenant') $Tenant
            return azswap $Target -Interactive:$Interactive
        }
        'login' {
            if (-not $env:AZURE_CONFIG_DIR) { return Write-Error "No profile selected. Run 'azswap <profile>'." }
            & $login $env:AZURE_CONFIG_DIR
            return & $show
        }
        default {
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Command"
            if (-not (Test-Path (Join-Path $dir 'azswap-tenant'))) {
                return Write-Error "Unknown profile '$Command'. Run 'azswap list', or 'azswap new $Command <tenant>'."
            }
            $env:AZURE_CONFIG_DIR = $dir
            az account get-access-token -o none 2>$null
            if ($LASTEXITCODE -ne 0) { & $login $dir }
            return & $show
        }
    }
}

Register-ArgumentCompleter -CommandName azswap -ParameterName Command -ScriptBlock {
    param($commandName, $parameterName, $word)
    $null = $commandName, $parameterName # unused, but fixed by the completer signature
    @($script:Commands) + @(Get-AzswapProfile | ForEach-Object { $_.Name.Substring(7) }) |
        Where-Object { $_ -like "$word*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
}
