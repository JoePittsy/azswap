# azswap - per-customer Azure CLI profiles.
# Each profile is <root>/.azure-<name> (an AZURE_CONFIG_DIR); its tenant id is in azswap-tenant inside it.
# <root> is $env:AZSWAP_HOME if set, otherwise $HOME.

$script:Usage = @'
azswap - per-customer Azure CLI profiles

Usage:
  azswap                            Show the current profile and signed-in account
  azswap <profile> [-Interactive|-DeviceCode] [-NoLogin] [-Account <upn>]
                                    Switch profile; sign in if the token has expired
  azswap list                       List profiles with account, subscription and tenant
  azswap new <profile> <tenant> [-Interactive|-DeviceCode] [-Account <upn>]
                                    Create a profile and sign in
  azswap login [-Interactive|-DeviceCode] [-NoLogin] [-Account <upn>]
                                    Sign in to the current profile again
  azswap run <profile> [-Interactive|-DeviceCode] [-NoLogin] -- <command> [args...]
                                    Run one command under a profile
  azswap help                       Show this help (also -h, --help)
  azswap import [-Apply]            Adopt existing ~/.azure-* folders as profiles
  azswap import -FromDefault [-Apply]
                                    Split ~/.azure into a profile per account

Options:
  -Interactive   Browser (WAM) sign-in instead of device code. Needed where
                 Conditional Access blocks device code.
  -DeviceCode    Device code sign-in, overriding a remembered -Interactive.
  -NoLogin       Never sign in. Where a sign-in is needed, fail with the command
                 to run instead. Always on in hosts with no terminal attached
                 (redirected input), in CI (CI, GITHUB_ACTIONS or TF_BUILD set to
                 true) and under -NonInteractive. Agents whose commands run in a
                 terminal (a pty) aren't detected and must pass -NoLogin.
  -Account <upn> With new, login or <profile>: the account this profile must be
                 signed in as (in azswap-account). azswap warns loudly when the
                 signed-in account differs.
  -Apply         For import: write the changes. Without it, import is a dry run.
  -Only <names>  For import: only these profile names.

  On 'new' and 'login', -Interactive / -DeviceCode is remembered for the profile
  (in azswap-login) once that sign-in succeeds, so later sign-ins use it without
  the switch. On a switch it applies to that one sign-in only.

Each profile is ~/.azure-<profile>; its tenant id is in azswap-tenant inside it.
'@

$script:Commands = 'list', 'new', 'login', 'help', 'import', 'run'

function Get-AzswapRoot {
    if ($env:AZSWAP_HOME) { $env:AZSWAP_HOME } else { $HOME }
}

function Get-AzswapProfile {
    # -Force: on Linux/macOS dot-folders are hidden and skipped without it
    Get-ChildItem (Get-AzswapRoot) -Directory -Force -Filter '.azure-*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'azswap-tenant') }
}

# Per-profile settings are one-line files named azswap-<name> inside the profile folder
# (azswap-tenant, azswap-login, azswap-account). A missing or empty file means "not set".
function Get-AzswapSetting {
    param([string]$Dir, [string]$Name)
    $file = Join-Path $Dir "azswap-$Name"
    if (Test-Path $file) {
        $value = "$(Get-Content $file -Raw)".Trim()
        if ($value) { $value }
    }
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

# Profile names: start with a letter or digit, no trailing '.' (Windows strips it), and nothing
# a shell would need quoting for.
$script:ProfileNamePattern = '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9_-])?$'

# Runs az with its stderr discarded, for checks whose failure azswap handles itself. A local
# 'Continue' stops Windows PowerShell turning that stderr into error records (terminating
# under 'Stop'). Stdout passes through and $LASTEXITCODE is az's.
function Invoke-AzswapNative {
    $ErrorActionPreference = 'Continue'
    az @args 2>$null
}

# The profile name for a config folder, or nothing if it isn't an azswap-style folder.
function Get-AzswapProfileName {
    param([string]$Dir)
    $leaf = Split-Path $Dir -Leaf
    if ($leaf -like '.azure-?*') { $leaf.Substring(7) }
}

# True if the PowerShell host's own arguments (the command line minus the executable)
# include -NonInteractive. Only options before the script or command count: everything
# after -File/-Command/-EncodedCommand/-CommandWithArgs, or after a bare script path,
# belongs to the script.
function Test-AzswapNonInteractiveArg {
    param([string[]]$Arguments)
    $valued = 'executionpolicy', 'ep', 'workingdirectory', 'wd', 'outputformat', 'o', 'of', 'inputformat', 'if',
        'config', 'configurationname', 'configurationfile', 'settingsfile', 'windowstyle', 'w', 'version', 'v', 'psconsolefile', 'custompipename'
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -notmatch '^(--|-|/)([a-z]+)$') { return $false }
        $name = $Matches[2]
        if ($name -like 'noni*') { return $true }
        # pwsh matches host options by prefix: -c/-co/-command, -f/-file, -e/-enc, plus -ec and -cwa
        if ($name -in 'ec', 'cwa' -or @('command', 'file', 'encodedcommand', 'commandwithargs') -like "$name*") { return $false }
        # ponytail: list of value-taking host options; one missing here only means a later -noni goes unseen
        if ($name -in $valued -or ($name.Length -ge 2 -and @($valued -like "$name*").Count -eq 1)) { $i++ }
    }
    $false
}

# Interactive unless: the process isn't user-interactive (services), stdin is redirected (no
# terminal attached: pipes, agent tool calls, most CI), CI/GITHUB_ACTIONS/TF_BUILD is 'true',
# or the host was started with -NonInteractive. A script run from a terminal counts as
# interactive, because a person is there to sign in.
# The parameters exist only so tests can vary one signal at a time.
function Test-AzswapInteractive {
    param(
        [bool]$UserInteractive = [Environment]::UserInteractive,
        [bool]$InputRedirected = [Console]::IsInputRedirected,
        [string[]]$HostArgs = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)
    )
    $UserInteractive -and -not $InputRedirected -and
        -not ('CI', 'GITHUB_ACTIONS', 'TF_BUILD' | Where-Object { [Environment]::GetEnvironmentVariable($_) -eq 'true' }) -and
        -not (Test-AzswapNonInteractiveArg $HostArgs)
}

# The only place azswap signs in. Call it as a plain statement, never inside an expression:
# az's stdout must stay the terminal, or az drops its subscription picker. Success is
# $LASTEXITCODE -eq 0 afterwards. In a non-interactive host, or with -NoLogin, it never runs
# az login: it sets $LASTEXITCODE to 1 and writes an AzswapLoginRefused error naming the command
# for a human to run. A failed az login writes AzswapLoginFailed. Pass the calling azswap's
# $PSCmdlet as -Cmdlet: errors then go through it, so the azswap call itself fails ($? is false,
# pwsh -Command exits 1). -Again means the user asked to sign in again (azswap login), so the
# suggested command does too.
# Method: -Interactive / -DeviceCode, else the profile's azswap-login setting
# ('interactive' or 'devicecode'), else device code.
function Invoke-AzswapLogin {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'LASTEXITCODE is how callers and scripts read the result')]
    param([string]$Dir, [switch]$Interactive, [switch]$DeviceCode, [switch]$NoLogin, [switch]$Again, [Management.Automation.PSCmdlet]$Cmdlet)
    $name = Get-AzswapProfileName $Dir
    if ($name -and $name -notmatch $script:ProfileNamePattern) { $name = "'$($name -replace "'", "''")'" }
    $fail = {
        param($Message, $Id)
        $rec = [Management.Automation.ErrorRecord]::new([Exception]::new($Message), $Id, 'AuthenticationError', $Dir)
        if ($Cmdlet) { $Cmdlet.WriteError($rec) } else { Write-Error -ErrorRecord $rec }
    }
    if ($NoLogin -or -not (Test-AzswapInteractive)) {
        $global:LASTEXITCODE = 1
        $why = if ($NoLogin) { '-NoLogin was given' } else { 'this host is non-interactive' }
        $switches = $(if ($Interactive) { ' -Interactive' } elseif ($DeviceCode) { ' -DeviceCode' })
        $msg = if (-not $name) { "Sign-in needed, but $why, and '$Dir' isn't an azswap profile." }
               elseif ($Again) { "Sign-in needed, but $why. Run this in your own terminal: azswap $name; azswap login$switches" }
               else { "Sign-in needed, but $why. Run this in your own terminal: azswap $name$switches" }
        & $fail $msg 'AzswapLoginRefused'
        return
    }
    # azswap rejects -Interactive with -DeviceCode before it gets here.
    if (-not $Interactive -and -not $DeviceCode) { $Interactive = (Get-AzswapSetting -Dir $Dir -Name 'login') -eq 'interactive' }
    $loginArgs = @('login', '--tenant', (Get-AzswapSetting -Dir $Dir -Name 'tenant'), '-o', 'none')
    if (-not $Interactive) { $loginArgs += '--use-device-code' }
    az @loginArgs
    if ($LASTEXITCODE -ne 0) {
        $code = $LASTEXITCODE
        # Before the error, so -ErrorAction Stop doesn't swallow it. az prints the AADSTS error
        # itself; device-code output is on stderr, so it isn't captured to inspect.
        if (-not $Interactive) {
            Write-Warning "If Conditional Access blocked device code (AADSTS53003, AADSTS50097), sign in with 'azswap login -Interactive'; the profile then remembers it."
        }
        & $fail "Sign-in failed for '$(if ($name) { $name } else { $Dir })'." 'AzswapLoginFailed'
        $global:LASTEXITCODE = $code
    }
}

# Compares the signed-in account (of the active AZURE_CONFIG_DIR, which callers have set to
# $Dir) with azswap-account. Warns and returns $false on a mismatch; otherwise $true.
# With no expected account: -SignedIn (azswap has just signed in successfully) records the
# account; otherwise it only warns, because an old sign-in may already be the wrong one.
function Test-AzswapAccount {
    [CmdletBinding()]
    param([string]$Dir, [switch]$SignedIn)
    $query = 'account', 'show', '--query', 'user.name', '-o', 'tsv'
    $actual = Invoke-AzswapNative @query
    if (-not $actual) { return $true } # not signed in: nothing to compare
    $name = Get-AzswapProfileName $Dir
    $expected = Get-AzswapSetting -Dir $Dir -Name 'account'
    if (-not $expected) {
        if ($SignedIn) {
            Write-AzswapSetting -Dir $Dir -Name 'account' -Value $actual
            Write-Information "Recorded $actual as the expected account for '$name'." -InformationAction Continue
        } else {
            Write-Warning "No expected account for '$name' (signed in as $actual). If that's right, run: azswap $name -Account $actual"
        }
        return $true
    }
    if ($actual -eq $expected) { return $true } # -eq is case-insensitive
    Write-Warning ("WRONG ACCOUNT: profile '$name' is signed in as $actual, but expects $expected. " +
        "If $expected is right, sign in again and pick it: 'azswap login' (or 'azswap login -Interactive'). " +
        "If $actual is right, update the expected account: 'azswap $name -Account $actual'.")
    $false
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

        Each profile also records the account it must be signed in as (azswap-account).
        After switching or signing in, azswap warns loudly when the signed-in account is
        different, and 'azswap list' marks the mismatch with '!'.

        Commands: (none) shows the current profile; <profile> switches; list, new, login,
        import, run and help. Run 'azswap help' for a one-screen summary.

        'azswap run <profile> -- <command>' runs one command under a profile without
        changing the current shell's profile, then restores AZURE_CONFIG_DIR. It passes the
        command's output and $LASTEXITCODE through. It refuses to run the command if the
        profile is signed in as the wrong account.

        Profile folders live in $HOME, or in $env:AZSWAP_HOME if that is set.

    .PARAMETER Command
        A profile name to switch to, or one of: list, new, login, import, run, help. Omit it
        to show the current profile and account.

    .PARAMETER Target
        For 'new': the name of the profile to create. For 'run': the profile to run under.

    .PARAMETER Tenant
        For 'new': the tenant id or domain the profile signs in to. For 'run' it receives
        the command's name, which follows '--'.

    .PARAMETER Arguments
        For 'run': the command's arguments, everything after its name, passed verbatim.
        Other commands reject extra arguments.

    .PARAMETER Account
        For 'new', 'login' or <profile>: the account (user.name) the profile must be signed
        in as, stored in azswap-account. Without it, the account of the profile's next
        successful azswap sign-in is recorded. A profile with no expected account warns on
        every switch until you set one.

    .PARAMETER Interactive
        Browser (WAM) sign-in instead of device code. Needed where Conditional Access
        blocks device code. With 'new' or 'login', once the sign-in succeeds the profile
        remembers it (in an azswap-login file), so later sign-ins are interactive without
        the switch. When switching, it applies to that one sign-in only.

    .PARAMETER DeviceCode
        Device code sign-in, overriding a remembered -Interactive. Remembered the same
        way as -Interactive.

    .PARAMETER NoLogin
        Never sign in. Where a sign-in would start, write an error naming the command for
        a human to run (azswap <profile>, plus -Interactive or -DeviceCode if given) and
        return without printing the account. The call fails ($? is false, $LASTEXITCODE
        is 1, and pwsh -Command exits 1). A refused sign-in remembers no method.

        This is automatic in a non-interactive host: one with no terminal attached
        (redirected input), CI (CI, GITHUB_ACTIONS or TF_BUILD set to true), or started
        with -NonInteractive. A script run from a terminal counts as interactive, since a
        person is there to sign in. Agents whose commands run in a terminal (a pty) are
        not detected, so they must pass -NoLogin.

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
        azswap contoso -NoLogin

        Switches to the contoso profile but never signs in; if the token has expired it
        fails with the command to run in an interactive terminal.

    .EXAMPLE
        azswap new fabrikam fabrikam.onmicrosoft.com -Interactive

        Creates the fabrikam profile for that tenant and signs in through the browser.
        Later sign-ins to fabrikam use the browser too.

    .EXAMPLE
        azswap login -DeviceCode

        Signs in to the current profile with a device code, and makes device code its
        sign-in method from now on.

    .EXAMPLE
        azswap contoso -Account admin@contoso.com

        Sets the account the contoso profile should be signed in as, then switches to it.

    .EXAMPLE
        azswap list

        Lists every profile with its account, default subscription and tenant. The
        current profile is marked with *.

    .EXAMPLE
        azswap run contoso -- az group list -o table

        Lists contoso's resource groups, signing in first if the token has expired. This
        shell's profile is unchanged afterwards.

    .EXAMPLE
        azswap run fabrikam -- code .

        Starts VS Code under the fabrikam profile, so its Azure extensions use it.

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'LASTEXITCODE is how callers and scripts read the result')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string]$Command,
        [Parameter(Position = 1)] [string]$Target,
        [Parameter(Position = 2)] [string]$Tenant,
        [string]$Account,
        [switch]$Interactive,
        [switch]$NoLogin,
        [switch]$DeviceCode,
        [Alias('h')] [switch]$Help,
        [switch]$Apply,
        [switch]$FromDefault,
        [string[]]$Only,
        [Parameter(ValueFromRemainingArguments)] [string[]]$Arguments = @()
    )

    if ($PSBoundParameters.ContainsKey('Account')) {
        $Account = $Account.Trim()
        if (-not $Account) { return Write-Error '-Account needs an account, such as user@contoso.com.' }
        if ($Help -or $Command -in '', 'list', 'import', 'help', '--help', 'run') { return Write-Error '-Account works with new, login or a profile name.' }
    }
    if ($Help -or $Command -in 'help', '--help') { return $script:Usage }
    if ($Interactive -and $DeviceCode) { return Write-Error 'Use -Interactive or -DeviceCode, not both.' }
    # 'new' and 'login' remember an explicit method once a sign-in with it succeeds.
    $method = if ($Interactive) { 'interactive' } elseif ($DeviceCode) { 'devicecode' }
    if ($Arguments -and $Command -ne 'run') { return Write-Error "Unexpected argument(s): $($Arguments -join ' '). Run 'azswap help'." }
    $accountArg = if ($Account) { @{ Account = $Account } } else { @{} }

    switch ($Command) {
        '' {
            if (-not $env:AZURE_CONFIG_DIR) { return "No profile selected; az is using ~/.azure. Run 'azswap list'." }
            $name = Get-AzswapProfileName $env:AZURE_CONFIG_DIR
            return "$(if ($name) { $name } else { $env:AZURE_CONFIG_DIR })  $(Show-AzswapAccount)"
        }
        'list' {
            return Get-AzswapProfile | ForEach-Object {
                $p = Get-Content (Join-Path $_.FullName 'azureProfile.json') -Raw -ErrorAction SilentlyContinue |
                    ConvertFrom-Json -ErrorAction SilentlyContinue
                $sub = $p.subscriptions | Where-Object isDefault | Select-Object -First 1
                $expected = Get-AzswapSetting -Dir $_.FullName -Name 'account'
                [pscustomobject]@{
                    ' '          = if ($_.FullName -eq $env:AZURE_CONFIG_DIR) { '*' } else { '' }
                    Profile      = $_.Name.Substring(7)
                    Account      = if ($sub.user.name -and $expected -and $sub.user.name -ne $expected) {
                        "! $($sub.user.name) (expects $expected)"
                    } else { $sub.user.name }
                    Subscription = $sub.name
                    Tenant       = Get-AzswapSetting -Dir $_.FullName -Name 'tenant'
                }
            } | Format-Table -AutoSize
        }
        'new' {
            if (-not $Target -or -not $Tenant) { return Write-Error 'Usage: azswap new <profile> <tenant>' }
            if ($Target -notmatch $script:ProfileNamePattern) {
                return Write-Error "Profile names can only use letters, digits, '.', '_' and '-', must start with a letter or digit, and can't end with '.'."
            }
            if ($Target -in $script:Commands) { return Write-Error "'$Target' is a command name; pick another profile name." }
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Target"
            if (Test-Path (Join-Path $dir 'azswap-tenant')) { return Write-Error "Profile '$Target' already exists." }
            New-Item -ItemType Directory -Force $dir | Out-Null
            Write-AzswapSetting -Dir $dir -Name 'tenant' -Value $Tenant
            # Re-emit the inner call's sign-in errors through this call, so 'azswap new' itself fails
            # too. Only those: Windows PowerShell also records az's discarded stderr as errors.
            # Not captured: az login must keep the terminal. A new folder has no token, so this signs in.
            azswap $Target -Interactive:$Interactive -DeviceCode:$DeviceCode -NoLogin:$NoLogin @accountArg -ErrorAction SilentlyContinue -ErrorVariable err
            if ($method -and $LASTEXITCODE -eq 0) { Write-AzswapSetting -Dir $dir -Name 'login' -Value $method }
            foreach ($e in $err) { if ($e.FullyQualifiedErrorId -like 'AzswapLogin*') { $PSCmdlet.WriteError($e) } }
            return
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
            if (-not (Test-Path (Join-Path $env:AZURE_CONFIG_DIR 'azswap-tenant'))) {
                return Write-Error "'$env:AZURE_CONFIG_DIR' isn't an azswap profile. Run 'azswap <profile>'."
            }
            if ($Account) { Write-AzswapSetting -Dir $env:AZURE_CONFIG_DIR -Name 'account' -Value $Account }
            Invoke-AzswapLogin -Dir $env:AZURE_CONFIG_DIR -Interactive:$Interactive -DeviceCode:$DeviceCode -NoLogin:$NoLogin -Again -Cmdlet $PSCmdlet
            if ($LASTEXITCODE -ne 0) { return }
            if ($method) { Write-AzswapSetting -Dir $env:AZURE_CONFIG_DIR -Name 'login' -Value $method }
            Show-AzswapAccount
            $null = Test-AzswapAccount -Dir $env:AZURE_CONFIG_DIR -SignedIn
            return
        }
        'run' {
            # After '--' everything binds positionally, so the command's first word lands in
            # $Tenant and the rest in $Arguments, verbatim.
            if (-not $Target -or -not $Tenant) { return Write-Error 'Usage: azswap run <profile> -- <command> [args...]' }
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Target"
            if (-not (Test-Path (Join-Path $dir 'azswap-tenant'))) {
                return Write-Error "Unknown profile '$Target'. Run 'azswap list', or 'azswap new $Target <tenant>'."
            }
            $previous = $env:AZURE_CONFIG_DIR
            try {
                $env:AZURE_CONFIG_DIR = $dir
                Invoke-AzswapNative account get-access-token -o none
                $signedIn = $false
                if ($LASTEXITCODE -ne 0) {
                    Invoke-AzswapLogin -Dir $dir -Interactive:$Interactive -DeviceCode:$DeviceCode -NoLogin:$NoLogin -Cmdlet $PSCmdlet
                    if ($LASTEXITCODE -ne 0) { return }
                    $signedIn = $true
                }
                if (-not (Test-AzswapAccount -Dir $dir -SignedIn:$signedIn)) {
                    $global:LASTEXITCODE = 1
                    return Write-Error "Wrong account for '$Target', so '$Tenant' was not run."
                }
                & $Tenant @Arguments
            } finally {
                $env:AZURE_CONFIG_DIR = $previous
            }
        }
        default {
            $dir = Join-Path (Get-AzswapRoot) ".azure-$Command"
            if (-not (Test-Path (Join-Path $dir 'azswap-tenant'))) {
                return Write-Error "Unknown profile '$Command'. Run 'azswap list', or 'azswap new $Command <tenant>'."
            }
            if ($Account) { Write-AzswapSetting -Dir $dir -Name 'account' -Value $Account }
            $env:AZURE_CONFIG_DIR = $dir
            Invoke-AzswapNative account get-access-token -o none
            $signedIn = $false
            if ($LASTEXITCODE -ne 0) {
                Invoke-AzswapLogin -Dir $dir -Interactive:$Interactive -DeviceCode:$DeviceCode -NoLogin:$NoLogin -Cmdlet $PSCmdlet
                if ($LASTEXITCODE -ne 0) { return }
                $signedIn = $true # only now may Test-AzswapAccount record the account
            }
            Show-AzswapAccount
            $null = Test-AzswapAccount -Dir $dir -SignedIn:$signedIn
            return
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

Register-ArgumentCompleter -CommandName azswap -ParameterName Target -ScriptBlock {
    param($commandName, $parameterName, $word, $commandAst, $fakeBoundParameters)
    $null = $commandName, $parameterName, $commandAst # unused, but fixed by the completer signature
    if ($fakeBoundParameters.Command -ne 'run') { return }
    Get-AzswapProfile | ForEach-Object { $_.Name.Substring(7) } |
        Where-Object { $_ -like "$word*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }
}
