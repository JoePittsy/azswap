# azswap - per-customer Azure CLI profiles. Dot-source from your pwsh profile.
# Each profile is ~/.azure-<name> (an AZURE_CONFIG_DIR); its tenant id is in azswap-tenant inside it.

$AzswapHelp = @'
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

function Get-AzswapProfiles {
    Get-ChildItem $HOME -Directory -Filter '.azure-*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'azswap-tenant') }
}

<#
.SYNOPSIS
    Per-customer Azure CLI profiles. Run 'azswap help' for usage.
#>
function azswap {
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

    if ($Help -or $Command -in 'help', '--help') { return $AzswapHelp }

    switch ($Command) {
        '' {
            if (-not $env:AZURE_CONFIG_DIR) { return "No profile selected; az is using ~/.azure. Run 'azswap list'." }
            return "$((Split-Path $env:AZURE_CONFIG_DIR -Leaf).Substring(7))  $(& $show)"
        }
        'list' {
            return Get-AzswapProfiles | ForEach-Object {
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
            if ($Target -in 'list', 'new', 'login', 'help') { return Write-Error "'$Target' is a command name; pick another profile name." }
            $dir = Join-Path $HOME ".azure-$Target"
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
            $dir = Join-Path $HOME ".azure-$Command"
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
    @('list', 'new', 'login', 'help') + @(Get-AzswapProfiles | ForEach-Object { $_.Name.Substring(7) }) |
        Where-Object { $_ -like "$word*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
}
