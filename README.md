# azswap

Isolated Azure CLI profiles for PowerShell: one identity per shell, so a terminal, a
script or an AI agent working on one customer can't touch another.

[![CI](https://github.com/JoePittsy/azswap/actions/workflows/ci.yml/badge.svg)](https://github.com/JoePittsy/azswap/actions/workflows/ci.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/azswap)](https://www.powershellgallery.com/packages/azswap)
[![Claude Code plugin](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FJoePittsy%2Fazswap%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=Claude%20Code%20plugin&color=D97757)](#claude-code-skill)

## Why azswap?

The Azure CLI can already hold several accounts: `az login` once per tenant, then
`az account set` to switch. The catch is that **there is one "current" subscription for
your whole user account**, stored in `~/.azure`. Every terminal, script, scheduled job and
AI agent shares it.

```text
Terminal 1 (Contoso)                    Terminal 2 (Fabrikam)
--------------------                    ---------------------
az account set -s contoso-prod
                                        az account set -s fabrikam-dev
az group delete -n rg-old --yes
  → runs against fabrikam-dev
```

Nothing warns you. Switching in one window silently retargets every other window, and
anything else running as you.

azswap gives each profile its own Azure CLI config folder (`AZURE_CONFIG_DIR`) and points
**only the current shell** at it:

```text
Terminal 1                              Terminal 2
----------                              ----------
azswap contoso                          azswap fabrikam
az group delete -n rg-old --yes
  → runs against contoso, always
```

Each profile has its own sign-in, token cache, default subscription and `az devops`
settings. Nothing you do in one can change another.

That isolation is what the rest is built on:

- **Two identities, one tenant.** An admin account and an everyday account in the same
  tenant can see the same subscriptions, and `az account set` picks by subscription, not
  by account. As separate profiles they can't be confused.
- **The right sign-in when a token expires.** Each profile remembers its tenant, its
  sign-in method (device code, or browser where Conditional Access demands it) and the
  account it should be. `azswap contoso` signs straight back in to the right place.
- **A wrong-account check.** If the sign-in window hands you the wrong account (Windows
  likes to offer the one you're signed in to the PC with), azswap warns, and `azswap run`
  refuses to run the command.
- **One command, one profile.** `azswap run fabrikam -- az group list` runs a single
  command under a profile and leaves your shell alone. That's handy for scripts, and for
  starting VS Code or Functions Core Tools under the right identity.
- **Safe for scripts, CI and AI agents.** azswap never starts an interactive sign-in from
  a host with nobody at the keyboard; it fails with the exact command for a person to run.
  The [Claude Code plugin](#claude-code-skill) lets an agent pick the right profile for the
  repo you're in.
- **A smaller blast radius.** A logout, `az account clear` or a corrupt token cache
  affects one profile, not every customer.

**When you don't need it:** if you have one identity, and you work on one customer at a
time in one terminal, plain `az login` and `az account set` are fine.

## Install

Requires PowerShell 7 or Windows PowerShell 5.1, and the
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).

```powershell
Install-Module azswap -Scope CurrentUser
Add-Content $PROFILE 'Import-Module azswap'
. $PROFILE
```

PowerShell would autoload the module the first time you run `azswap`, but tab completion
is registered when the module is imported, so it only appears after that first run.
The `Import-Module` line in `$PROFILE` gives you completion from the start.

To run it from a clone instead:

```powershell
git clone https://github.com/JoePittsy/azswap.git
Add-Content $PROFILE "Import-Module `"$PWD\azswap\azswap\azswap.psd1`""
. $PROFILE
```

### Claude Code plugin

If you use [Claude Code](https://claude.com/claude-code), add the plugin too, so Claude picks
the right profile before it runs any `az` command. Run these inside Claude Code:

```text
/plugin marketplace add JoePittsy/azswap
/plugin install azswap@azswap
```

The plugin carries only the agent skill, so install the module above as well. See
[Claude Code skill](#claude-code-skill) for what it does and how to update it.

## Quick start

```powershell
Install-Module azswap -Scope CurrentUser
Add-Content $PROFILE 'Import-Module azswap'    # then open a new shell
azswap new contoso 00000000-0000-0000-0000-000000000000 -Account you@contoso.com
azswap contoso                                 # switch this shell to contoso
azswap list                                    # every profile, its account and tenant
```

Using Claude Code? Add the plugin, and Claude will pick the right profile for the repo
you're in:

```text
/plugin marketplace add JoePittsy/azswap
/plugin install azswap@azswap
```

The tenant can be a tenant id or a domain. Tab completion covers commands and profile
names. `Get-Help azswap -Full` has the full reference and examples.

```text
azswap - per-customer Azure CLI profiles

Usage:
  azswap                            Show the current profile and signed-in account
  azswap <profile> [-Interactive|-DeviceCode] [-NoLogin|-NewWindow] [-Account <upn>]
                                    Switch profile; sign in if the token has expired
  azswap list [-AsJson]             List profiles with account, subscription and tenant
  azswap new <profile> <tenant> [-Interactive|-DeviceCode] [-Account <upn>] [-NewWindow]
                                    Create a profile and sign in
  azswap login [-Interactive|-DeviceCode] [-NoLogin|-NewWindow] [-Account <upn>]
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
  -NewWindow     With new, login or <profile>, on Windows: sign in in a new
                 terminal window and return straight away. Works from agents and
                 non-interactive hosts, because this shell never signs in. A
                 switch still switches this shell. Not with -NoLogin.
  -Apply         For import: write the changes. Without it, import is a dry run.
  -Only <names>  For import: only these profile names.
  -AsJson        For list: print the profiles as a JSON array, for scripts and
                 agents. Like list, it never calls az.

  On 'new' and 'login', -Interactive / -DeviceCode is remembered for the profile
  (in azswap-login) once that sign-in succeeds, so later sign-ins use it without
  the switch. On a switch it applies to that one sign-in only.

Each profile is ~/.azure-<profile>; its tenant id is in azswap-tenant inside it.
```

## How it works

The Azure CLI keeps everything (sign-ins, token cache, default subscription, `az devops`
settings) in one config folder, `~/.azure` by default. It uses whatever folder the
`AZURE_CONFIG_DIR` environment variable names instead.

`azswap` gives each profile its own folder, `~/.azure-<profile>`, and records the
profile's tenant in an `azswap-tenant` file inside it. `azswap <profile>` then:

1. Points `AZURE_CONFIG_DIR` at that folder for the current shell.
2. Checks the token, and signs in to the profile's tenant if the token has expired,
   with the profile's sign-in method (see below).
3. Prints the signed-in account and subscription, and warns if it isn't the account
   the profile expects.

There's no shared state between shells: each window can use a different profile.

Profile folders live in your home folder. Set the `AZSWAP_HOME` environment variable to
keep them somewhere else; `azswap` then looks for `$env:AZSWAP_HOME/.azure-<profile>`.
The tests use it to work in a scratch folder.

## Moving to azswap

Already have identities set up? `azswap import` turns them into profiles. It is a dry
run until you add `-Apply`, it never signs in, and it never touches tokens.

### Existing `~/.azure-<name>` folders

```powershell
azswap import          # show what it would register
azswap import -Apply   # write it
```

Each `~/.azure-*` folder without an `azswap-tenant` file becomes the profile `<name>`,
with the tenant and account of its default subscription. Folders it can't work out are
listed with the reason: never signed in, several tenants and no default subscription, or
not an az config folder at all (such as `~/.azure-devops`). Sign in to a never-used folder
with `az login` first, or create it again with `azswap new`.

### Everything in `~/.azure`

If every customer lives in the default `~/.azure`, split it up:

```powershell
azswap import -FromDefault                                  # suggested profiles
azswap import -FromDefault -Only contoso, fabrikam -Apply   # create the ones you want
azswap contoso                                              # then sign in to each
```

There is one suggestion per account and tenant. The name comes from the tenant's domain
if az recorded it, otherwise from the account's domain; two accounts in one tenant get
the account name added (`fabrikam-me`, `fabrikam-admin`). `-Apply` creates an empty
profile folder with the tenant and account recorded, and prints the `azswap <profile>`
command to sign in with. Tokens are deliberately not copied, so `~/.azure` is left as it
is. Names that clash with an existing folder or a command are skipped.

Part-way through moving? Identities you already have a profile for (same tenant and
account) show as `exists: <profile>` and are never created again. If a profile for the
same tenant has never been signed in, `azswap` can't tell whether it's the same account,
so it skips that identity and says why; sign in to the profile, or name the identity in
`-Only` to create it anyway.

Don't like a name? Rename the folder before you sign in
(`Rename-Item ~/.azure-contosoltd .azure-contoso`), or use `azswap new` instead.

Both modes return objects, so `-Only` takes the names from the dry run, and you can
filter or export the results like any other PowerShell output.

## Device code or browser sign-in?

Device code is the default because it works in any terminal, including remote and
embedded ones. Tenants with Conditional Access policies that require a compliant or
hybrid-joined device reject device-code sign-in, so use `-Interactive` for those. On
Windows that goes through the Web Account Manager (WAM) broker.

Each profile remembers its method, so you only say it once. A method you name on `new`
or `login` is recorded in an `azswap-login` file in the profile folder once a sign-in
with it succeeds:

```powershell
azswap new fabrikam fabrikam.onmicrosoft.com -Interactive -Account you.ext@fabrikam.com
azswap login -DeviceCode    # sign in to the current profile again, and switch it to device code
azswap fabrikam -DeviceCode # this one sign-in only; what's recorded doesn't change
```

A refused or failed sign-in records nothing, and a profile with no `azswap-login` file
uses device code. If a device-code sign-in fails, `azswap` suggests
`azswap login -Interactive`.

## Scripts, CI and agents

`azswap` never starts a sign-in from a non-interactive host, where it would hang on a
device code or fail for want of a browser window. A host counts as non-interactive when
it has no terminal attached (redirected input: pipelines, scheduled jobs, most agent tool
calls), when `CI`, `GITHUB_ACTIONS` or `TF_BUILD` is set to `true`, when it was started
with `-NonInteractive`, or when the process isn't user-interactive at all. A script you
run from your own terminal still counts as interactive, because you're there to sign in.

Agents that run commands in a real terminal (a pty) look interactive, so they aren't
detected. They must pass `-NoLogin`, which gives the same behaviour anywhere.

In that mode `azswap <profile>` still switches. If the token has expired, it fails with
an error naming the command to run in your own terminal, such as `azswap contoso`, and
doesn't print the account. `azswap login` fails the same way, suggesting
`azswap contoso; azswap login`, and `azswap new` creates the profile without signing in.

The failure is a normal PowerShell error: `$?` is false, `$LASTEXITCODE` is 1, and
`pwsh -Command` exits with 1. A sign-in that `az login` itself rejects fails the same
way. A `pwsh -File` script exits non-zero only if it stops on errors
(`$ErrorActionPreference = 'Stop'`, or `-ErrorAction Stop` on the call), as with any
other PowerShell error.

A refused sign-in records no method. If `azswap new ... -Interactive` was refused, run
`azswap login -Interactive` in your own terminal to sign in and record it.

### Signing in from an agent

On Windows, `-NewWindow` saves leaving the agent to find a terminal. `azswap contoso
-NewWindow` (also `azswap login -NewWindow` and `azswap new ... -NewWindow`) opens a new
terminal window that does the sign-in there, and returns straight away with
`Opened a sign-in window for 'contoso'. Finish signing in there, then carry on.` The
token lands in the profile folder, which every process shares. The calling shell never
signs in, so this works from non-interactive hosts; a switch still points the calling
shell at the profile, and `new` still creates the profile first. `-Interactive`,
`-DeviceCode` and `-Account` are passed on, and the window's sign-in records the method
and account, as a sign-in in your own terminal would.

The window runs this same azswap module (by path) in Windows Terminal if `wt.exe` is on
`PATH`, otherwise in a new console for the same PowerShell edition, without your
`$PROFILE`. It stays open showing the result and account until you press a key. On
Windows, a refused sign-in suggests it: `... azswap contoso (or: azswap contoso
-NewWindow)`. `-NewWindow` doesn't combine with `-NoLogin`, and on macOS and Linux it
fails with the command to run in a terminal instead.

In Claude Code, `!` may run commands in bash, where the azswap PowerShell module doesn't
exist, and `pwsh -Command "... azswap contoso"` is refused as non-interactive, so neither
signs in. Ask the agent to run `azswap contoso -NewWindow` instead.

## Running one command under a profile

`azswap run` runs a single command under a profile without switching the current shell:

```powershell
azswap run contoso -- az group list -o table
azswap run contoso -NoLogin -- az account show   # from a script or agent
```

It points `AZURE_CONFIG_DIR` at the profile, signs in first if the token has expired,
runs the command, then puts `AZURE_CONFIG_DIR` back as it was (or unsets it), even if
the command fails. The command's output comes straight through and `$LASTEXITCODE` is
its exit code. A non-zero exit is also reported as an error, so `$?` is false and
`pwsh -Command` exits non-zero. Everything after `--` goes to the command, including
arguments that start with `-`; PowerShell still expands variables and quotes first, as
it does for any command.

It won't run the command as the wrong account: if the profile is signed in as someone
other than its expected account, `run` warns, sets `$LASTEXITCODE` to 1 and stops. A
sign-in it can't do (with `-NoLogin`, or in a non-interactive host) fails the same way,
with the `azswap <profile>` command to run in your own terminal.

`run` is for executables. It refuses PowerShell scripts, functions and cmdlets, because
their `-Switch` arguments would arrive as plain strings and be silently ignored. Run a
script in its own PowerShell process instead:

```powershell
azswap run contoso -- pwsh -NoProfile -File ./deploy.ps1 -DryRun
```

## Wrong-account warnings

On Windows the sign-in broker offers whichever account Windows is signed in with, so
it's easy to click through and end up with your everyday account in a profile meant
for an admin or guest identity. Two identities can share a tenant, so the tenant alone
can't catch it.

So give each profile the account it must be signed in as, with `-Account`. It's stored in
an `azswap-account` file. After switching or signing in, `azswap` compares it with the
signed-in account and warns loudly (`WRONG ACCOUNT: ...`) if they differ; `run` refuses
to run the command. `azswap list` marks a mismatch with `!`, without calling `az`.

```powershell
azswap new contoso 00000000-0000-0000-0000-000000000000 -Account admin@contoso.com
azswap contoso -Account admin@contoso.com    # set or change it for an existing profile
azswap login -Account admin@contoso.com      # or set it while signing in again
```

Without `-Account`, the account of the profile's first successful `azswap` sign-in is
recorded. A profile that has no expected account and is already signed in (an imported
folder, or one from before this feature) warns on every switch until you confirm the
account with `-Account`. `azswap` doesn't record it for you, because an existing sign-in
may already be the wrong one.

## Things that ignore azswap

Only processes that inherit `AZURE_CONFIG_DIR` from your shell use the profile. The
VS Code Azure extensions, Azure Functions Core Tools, and anything that authenticates
through `AzureCliCredential` (including `DefaultAzureCredential`) still read `~/.azure`
when started without it. Start them under a profile with `azswap run`:

```powershell
azswap run fabrikam -- code .
azswap run contoso -- func start
```

`AZURE_DEVOPS_EXT_PAT`, if it is set, overrides the profile's sign-in for `az devops`
and `az boards`.

## Claude Code skill

[`skill/az-profiles/SKILL.md`](skill/az-profiles/SKILL.md) is a skill for
[Claude Code](https://claude.com/claude-code). Before its first `az` call, Claude runs
`azswap list -AsJson` and picks the profile itself, matching what it knows from the
conversation (the current repo, an ADO org URL, a customer name, an account domain, a
tenant or subscription) against your profile names, accounts and subscriptions. It asks
only when two profiles fit or none do. Claude then runs every `az` command under that
profile, checks the account before acting, stops and asks on a wrong-account warning,
never signs in itself, and asks you to run `azswap <profile>` when a sign-in has expired.
On Windows it may offer to open a sign-in window for you with `azswap <profile> -NewWindow`,
and does so only if you say yes.

The skill reads your profiles at run time, so it needs no editing. Install it as a
Claude Code plugin from this repo's marketplace, inside Claude Code:

```text
/plugin marketplace add JoePittsy/azswap
/plugin install azswap@azswap
```

or from a shell, with `claude plugin marketplace add JoePittsy/azswap` and
`claude plugin install azswap@azswap`. The skill then appears as `azswap:az-profiles`.
The plugin carries only the skill: install the module itself with `Install-Module azswap`
as above. Custom marketplaces don't update automatically, so to pick up a new release run
`claude plugin update azswap@azswap` and start a new session (or turn on auto-update for
the marketplace in `/plugin`).

Alternatively, copy the `skill/az-profiles` folder into `~/.claude/skills/`, where it
appears as `az-profiles`.

`azswap list -AsJson` works for any script too: it prints one object per profile with
`name`, `active`, `path`, `tenant`, `account` (signed in), `expectedAccount`,
`accountMismatch`, `subscription`, `subscriptionId` and `loginMethod`, and never calls `az`.

## Similar tools

- [azcli-profile-mgmt](https://github.com/clarked-msft/azcli-profile-mgmt) uses the
  same `AZURE_CONFIG_DIR`-per-profile approach, for Bash and PowerShell, with copy,
  rename and per-profile shell history. Profiles don't record their tenant, so signing
  in is a manual `az login`, and its Copilot CLI instructions ask you which profile
  to use rather than inferring it.
- [azctx](https://github.com/iul1an/azctx) switches subscriptions inside a disposable
  per-shell copy of `~/.azure`. It runs on Linux and macOS.

What azswap adds:

- **Remembered tenant and sign-in method.** An expired session signs straight back in
  to the right tenant, by device code or browser as the profile needs.
- **A wrong-account check.** Each profile knows the account it should be signed in as,
  and azswap warns (and `run` refuses) when it isn't.
- **`run`** for one command, or a tool such as VS Code, under a profile without
  switching the shell.
- **`import`** to adopt existing `~/.azure-*` folders or split up `~/.azure`.
- **Safe in non-interactive hosts.** Scripts, CI and agents get an error naming the
  command to run, never a hung sign-in.
- **An agent skill** that picks the profile from context (the repo you're in, the ADO
  org or the customer you mention) instead of asking.

## Development

```powershell
Invoke-Pester ./tests                                          # Pester 5
Invoke-ScriptAnalyzer ./azswap -Recurse -Settings PSGallery
```

The tests mock `az` and point `AZSWAP_HOME` at a scratch folder, so they never touch
your real profiles or sign in. CI runs them on Ubuntu and on Windows, under both
PowerShell 7 and Windows PowerShell 5.1. CI also runs `claude plugin validate --strict`
on the Claude Code plugin manifests in [`.claude-plugin/`](.claude-plugin).

The repo root is the plugin root, and Claude Code loads certain top-level folders from
it: `skills/`, `commands/`, `agents/`, `hooks/`, plus `.mcp.json`. Don't create any of
them unless you mean Claude to load it. In particular, files for other agent tools go
under `integrations/<tool>/`, never a top-level `agents/` folder, which Claude Code would
load as subagents.

## Releasing

1. Bump `ModuleVersion` in [`azswap/azswap.psd1`](azswap/azswap.psd1) and `version` in
   [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) to the same version,
   update `ReleaseNotes`, and commit. A test fails if the two differ.
2. Tag the commit `vX.Y.Z` to match, and push the tag: `git push origin vX.Y.Z`.
3. The Publish workflow runs the tests, checks the tag matches both versions, and
   publishes to the PowerShell Gallery. It needs a Gallery API key in the
   `PSGALLERY_API_KEY` repository secret. Plugin users get the new version from the
   repo when they next update the plugin.

## Licence

MIT
