# azswap

Per-customer Azure CLI profiles for PowerShell. If you work across several tenants,
`azswap` gives each identity its own az config folder, so switching customer can't leave
you running commands as the wrong account in the wrong tenant.

```text
azswap                            Show the current profile and signed-in account
azswap <profile> [-Interactive]   Switch profile; sign in if the token has expired
azswap list                       List profiles with account, subscription and tenant
azswap new <profile> <tenant>     Create a profile and sign in
azswap login [-Interactive]       Sign in to the current profile again
azswap help                       Show help (also -h, --help)
```

## How it works

The Azure CLI keeps everything (sign-ins, token cache, default subscription, `az devops`
settings) in one config folder, `~/.azure` by default. It uses whatever folder the
`AZURE_CONFIG_DIR` environment variable names instead.

`azswap` gives each profile its own folder, `~/.azure-<profile>`, and records the
profile's tenant in an `azswap-tenant` file inside it. `azswap <profile>` then:

1. Points `AZURE_CONFIG_DIR` at that folder for the current shell.
2. Checks the token, and signs in to the profile's tenant if the token has expired:
   device code by default, or browser sign-in with `-Interactive`.
3. Prints the signed-in account and subscription.

There's no shared state between shells: each window can use a different profile.

## Install

Requires PowerShell 7 and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).

```powershell
git clone https://github.com/JoePittsy/azswap.git
Add-Content $PROFILE ". `"$PWD\azswap\azswap.ps1`""
. $PROFILE
```

Then create a profile for each identity:

```powershell
azswap new contoso 00000000-0000-0000-0000-000000000000
azswap new fabrikam fabrikam.onmicrosoft.com -Interactive
```

The tenant can be a tenant id or a domain. Tab completion covers commands and profile names.

### Already have `~/.azure-<name>` folders?

Write the tenant into each one and `azswap` picks it up:

```powershell
Set-Content "$HOME\.azure-contoso\azswap-tenant" '00000000-0000-0000-0000-000000000000'
```

## Device code or browser sign-in?

Device code is the default because it works in any terminal, including remote and
embedded ones. Tenants with Conditional Access policies that require a compliant or
hybrid-joined device reject device-code sign-in, so use `-Interactive` for those. On
Windows that goes through the Web Account Manager (WAM) broker.

## Things that ignore `azswap`

Only processes that inherit `AZURE_CONFIG_DIR` from your shell use the profile. The
VS Code Azure extensions, and anything that authenticates through `AzureCliCredential`
(including `DefaultAzureCredential`) without that variable set, still read `~/.azure`.
`AZURE_DEVOPS_EXT_PAT`, if it is set, overrides the profile's sign-in for `az devops`
and `az boards`.

## Claude Code skill

[`skill/az-profiles/SKILL.md`](skill/az-profiles/SKILL.md) is a template skill for
[Claude Code](https://claude.com/claude-code). It teaches Claude to work out which
customer you're talking about from the conversation or the current repo, and to run
every `az` command under that profile. Claude checks the account before acting, and
asks you to run `azswap <profile>` when a sign-in has expired.

To use it, copy the folder to `~/.claude/skills/az-profiles/`, then fill in the
profile and cue tables with your own customers. Your filled-in copy contains tenant
ids and account names, so keep it out of public repos.

## Similar tools

- [azcli-profile-mgmt](https://github.com/clarked-msft/azcli-profile-mgmt) uses the
  same `AZURE_CONFIG_DIR`-per-profile approach, for Bash and PowerShell, with copy,
  rename and per-profile shell history. Profiles don't record their tenant, so signing
  in is a manual `az login`, and its Copilot CLI instructions ask you which profile
  to use rather than inferring it.
- [azctx](https://github.com/iul1an/azctx) switches subscriptions inside a disposable
  per-shell copy of `~/.azure`. It runs on Linux and macOS.

What azswap adds is that each profile knows its tenant, so an expired session signs
straight back in to the right place. The Claude Code skill also picks the profile
from context (the repo you're in, the ADO org or the customer you mention) instead of
asking.

## Licence

MIT
