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
  azswap import [-Apply]            Adopt existing ~/.azure-* folders as profiles
  azswap import -FromDefault [-Apply]
                                    Split ~/.azure into a profile per account

Options:
  -Interactive   Browser (WAM) sign-in instead of device code. Needed where
                 Conditional Access blocks device code.
  -Apply         For import: write the changes. Without it, import is a dry run.
  -Only <names>  For import: only these profile names.

Each profile is ~/.azure-<profile>; its tenant id is in azswap-tenant inside it.
'@

$script:Commands = 'list', 'new', 'login', 'help', 'import'

function Get-AzswapRoot {
    if ($env:AZSWAP_HOME) { $env:AZSWAP_HOME } else { $HOME }
}

function Get-AzswapProfile {
    # -Force: on Linux/macOS dot-folders are hidden and skipped without it
    Get-ChildItem (Get-AzswapRoot) -Directory -Force -Filter '.azure-*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'azswap-tenant') }
}

# Per-profile settings are one-line files named azswap-<name> inside the profile folder
# (azswap-tenant today). A missing file means "not set".
function Get-AzswapSetting {
    param([string]$Dir, [string]$Name)
    $file = Join-Path $Dir "azswap-$Name"
    if (Test-Path $file) { (Get-Content $file -Raw).Trim() }
}

function Write-AzswapSetting {
    param([string]$Dir, [string]$Name, [string]$Value)
    Set-Content (Join-Path $Dir "azswap-$Name") $Value
}

# Subscriptions in an az config folder's azureProfile.json. Nothing if it is missing,
# empty or unreadable (a folder that has never been signed in).
function Get-AzswapSubscription {
    param([string]$Dir)
    $file = Join-Path $Dir 'azureProfile.json'
    if (-not (Test-Path $file)) { return }
    try { (Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).subscriptions }
    catch { Write-Verbose "Can't read ${file}: $_" }
}

# A profile name from a domain or account: lower case, letters, digits and dashes only.
function ConvertTo-AzswapName {
    param([string]$Text)
    ($Text.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
}

# One candidate profile per identity in ~/.azure (-FromDefault).
function Get-AzswapDefaultIdentity {
    param([string]$Root)
    $ids = Get-AzswapSubscription (Join-Path $Root '.azure') |
        Group-Object { "$($_.user.name)|$($_.tenantId)" } |
        ForEach-Object {
            $s = $_.Group[0]
            # The tenant's own domain when az recorded it, else the account's domain, else
            # the start of the tenant id (a service principal's name is a GUID).
            $domain = if ($s.tenantDefaultDomain) { $s.tenantDefaultDomain } elseif ($s.user.name -match '@(.+)$') { $Matches[1] }
            $name = if ($domain) { $domain.Split('.')[0] } else { "$($s.tenantId)".Split('-')[0] }
            [pscustomobject]@{ Profile = ConvertTo-AzswapName $name; Account = $s.user.name; Tenant = $s.tenantId; Reason = $null; Exists = $null }
        }
    # Two identities with the same name (two accounts in one tenant): add each account's
    # local part, or the start of a service principal's app id.
    $ids | Group-Object Profile | Where-Object Count -gt 1 | ForEach-Object Group | ForEach-Object {
        $local = ($_.Account -replace '@.*') -replace '^([0-9a-f]{8})-[0-9a-f-]{27}$', '$1'
        $_.Profile = ConvertTo-AzswapName "$($_.Profile)-$local"
    }
    $ids
}

# Marks -FromDefault identities that existing profiles already cover. Covered: a profile
# with the same tenant and account (its azswap-account, else its default subscription's
# user). A profile in the same tenant with no known account (never signed in) might be the
# same identity, so that one is skipped unless -Only names it.
function Resolve-AzswapCoverage {
    param([object[]]$Identity, [string[]]$Only)
    $known = @(Get-AzswapProfile | ForEach-Object {
        $account = Get-AzswapSetting -Dir $_.FullName -Name 'account'
        if (-not $account) { $account = (Get-AzswapSubscription $_.FullName | Where-Object isDefault | Select-Object -First 1).user.name }
        [pscustomobject]@{ Name = $_.Name.Substring(7); Tenant = Get-AzswapSetting -Dir $_.FullName -Name 'tenant'; Account = $account }
    })
    foreach ($id in $Identity) {
        $same = @($known | Where-Object Tenant -eq $id.Tenant)
        $match = $same | Where-Object { $_.Account -and $_.Account -eq $id.Account } | Select-Object -First 1
        $unknown = @($same | Where-Object { -not $_.Account } | ForEach-Object { "'$($_.Name)'" })
        if ($match) { $id.Exists = $match.Name }
        elseif ($unknown -and $id.Profile -notin $Only) {
            $id.Reason = "tenant already has profile $($unknown -join ', ') (account unknown; sign in to it, or use -Only to create anyway)"
        }
    }
}

# One candidate per <root>/.azure-* folder that is not a profile yet (plain import).
function Get-AzswapImportFolder {
    param([string]$Root)
    Get-ChildItem $Root -Directory -Force -Filter '.azure-*' |
        Where-Object { -not (Test-Path (Join-Path $_.FullName 'azswap-tenant')) } |
        ForEach-Object {
            $subs = @(Get-AzswapSubscription $_.FullName)
            $sub = $subs | Where-Object isDefault | Select-Object -First 1
            $tenant, $account = $sub.tenantId, $sub.user.name
            if (-not $sub -and @($subs.tenantId | Sort-Object -Unique).Count -eq 1) {
                # No default but only one tenant: the account only if every subscription agrees.
                $tenant = $subs[0].tenantId
                $account = if (@($subs.user.name | Sort-Object -Unique).Count -eq 1) { $subs[0].user.name }
            }
            $isAz = (Test-Path (Join-Path $_.FullName 'config')) -or (Test-Path (Join-Path $_.FullName 'azureProfile.json'))
            [pscustomobject]@{
                Profile = $_.Name.Substring(7)
                Account = $account
                Tenant  = $tenant
                Reason  = if (-not $isAz) { 'not an az config folder' }
                          elseif (-not $subs) { 'no profile data; sign in to it first' }
                          elseif (-not $tenant) { 'several tenants and no default subscription' }
            }
        }
}

# Writes one import row's files. Returns nothing on success, or "failed: <reason>".
# An existing azswap-account is never overwritten, whatever it holds.
function Write-AzswapImport {
    param([string]$Dir, [string]$Tenant, [string]$Account, [switch]$Create)
    $ErrorActionPreference = 'Stop'
    $created = $false
    try {
        if ($Create) { New-Item -ItemType Directory $Dir | Out-Null; $created = $true }
        Write-AzswapSetting -Dir $Dir -Name 'tenant' -Value $Tenant
        if ($Account -and -not (Test-Path (Join-Path $Dir 'azswap-account'))) {
            Write-AzswapSetting -Dir $Dir -Name 'account' -Value $Account
        }
    }
    catch {
        # Only a folder created by this call, which holds nothing but azswap-* files.
        if ($created) { Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue }
        "failed: $($_.Exception.Message)"
    }
}

function Show-AzswapAccount {
    az account show --query "join('  ', [user.name, name])" -o tsv
}

# The only place azswap signs in.
function Invoke-AzswapLogin {
    param([string]$Dir, [switch]$Interactive)
    $loginArgs = @('login', '--tenant', (Get-AzswapSetting -Dir $Dir -Name 'tenant'), '-o', 'none')
    if (-not $Interactive) { $loginArgs += '--use-device-code' }
    az @loginArgs
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

        Commands: (none) shows the current profile; <profile> switches; list, new, login,
        import and help. Run 'azswap help' for a one-screen summary.

        Profile folders live in $HOME, or in $env:AZSWAP_HOME if that is set.

    .PARAMETER Command
        A profile name to switch to, or one of: list, new, login, import, help. Omit it to show
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

    .PARAMETER Apply
        For 'import': write azswap-tenant (and azswap-account) files, creating profile
        folders for -FromDefault. Without it, import only shows what it would do.

    .PARAMETER FromDefault
        For 'import': instead of adopting ~/.azure-* folders, plan an empty profile for
        each distinct account and tenant in ~/.azure. Tokens are never copied; you sign
        in to each new profile with 'azswap <profile>'.

    .PARAMETER Only
        For 'import': limit it to these profile names (as shown by the dry run).

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

    .EXAMPLE
        azswap import -Apply

        Registers each ~/.azure-* folder that az has signed in to as a profile, reading
        the tenant and account from its default subscription. Leave out -Apply for a
        dry run.

    .EXAMPLE
        azswap import -FromDefault -Only contoso, fabrikam -Apply

        Creates empty contoso and fabrikam profiles for accounts found in ~/.azure.
        Sign in to each with 'azswap contoso' and 'azswap fabrikam'.

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
        [Alias('h')] [switch]$Help,
        [switch]$Apply,
        [switch]$FromDefault,
        [string[]]$Only
    )

    if ($Help -or $Command -in 'help', '--help') { return $script:Usage }

    switch ($Command) {
        '' {
            if (-not $env:AZURE_CONFIG_DIR) { return "No profile selected; az is using ~/.azure. Run 'azswap list'." }
            return "$((Split-Path $env:AZURE_CONFIG_DIR -Leaf).Substring(7))  $(Show-AzswapAccount)"
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
                    Tenant       = Get-AzswapSetting -Dir $_.FullName -Name 'tenant'
                }
            } | Format-Table -AutoSize
        }
        'new' {
            if (-not $Target -or -not $Tenant) { return Write-Error 'Usage: azswap new <profile> <tenant>' }
            if ($Target -in $script:Commands) { return Write-Error "'$Target' is a command name; pick another profile name." }
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Target"
            if (Test-Path (Join-Path $dir 'azswap-tenant')) { return Write-Error "Profile '$Target' already exists." }
            New-Item -ItemType Directory -Force $dir | Out-Null
            Write-AzswapSetting -Dir $dir -Name 'tenant' -Value $Tenant
            return azswap $Target -Interactive:$Interactive
        }
        'import' {
            # Never signs in or touches tokens: it only writes azswap-* files.
            $root = Get-AzswapRoot
            $candidates = @(if ($FromDefault) { Get-AzswapDefaultIdentity $root } else { Get-AzswapImportFolder $root })
            if (-not $candidates) {
                if ($FromDefault) { return Write-Error "No accounts found in $(Join-Path $root '.azure')." }
                return 'No ~/.azure-* folders to import.'
            }
            if ($FromDefault) { Resolve-AzswapCoverage $candidates -Only $Only }
            $seen = @{}
            return $candidates | Where-Object { -not $Only -or $_.Profile -in $Only } | ForEach-Object {
                $dir = Join-Path $root ".azure-$($_.Profile)"
                if (-not $_.Reason) {
                    $_.Reason = if ($_.Profile -in $script:Commands) { "'$($_.Profile)' is a command name" }
                                elseif ($FromDefault -and ((Test-Path $dir) -or $seen[$_.Profile])) { ".azure-$($_.Profile) already exists" }
                }
                $seen[$_.Profile] = $true
                $status = if ($_.Exists) { "exists: $($_.Exists)" }
                          elseif ($_.Reason) { "skipped: $($_.Reason)" }
                          elseif (-not $Apply) { if ($FromDefault) { 'would create' } else { 'would register' } }
                          elseif ($failed = Write-AzswapImport -Dir $dir -Tenant $_.Tenant -Account $_.Account -Create:$FromDefault) { $failed }
                          elseif ($FromDefault) { "created; sign in with: azswap $($_.Profile)" }
                          else { 'registered' }
                [pscustomobject]@{ Profile = $_.Profile; Account = $_.Account; Tenant = $_.Tenant; Status = $status }
            }
        }
        'login' {
            if (-not $env:AZURE_CONFIG_DIR) { return Write-Error "No profile selected. Run 'azswap <profile>'." }
            Invoke-AzswapLogin -Dir $env:AZURE_CONFIG_DIR -Interactive:$Interactive
            return Show-AzswapAccount
        }
        default {
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Command"
            if (-not (Test-Path (Join-Path $dir 'azswap-tenant'))) {
                return Write-Error "Unknown profile '$Command'. Run 'azswap list', or 'azswap new $Command <tenant>'."
            }
            $env:AZURE_CONFIG_DIR = $dir
            az account get-access-token -o none 2>$null
            if ($LASTEXITCODE -ne 0) { Invoke-AzswapLogin -Dir $dir -Interactive:$Interactive }
            return Show-AzswapAccount
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
