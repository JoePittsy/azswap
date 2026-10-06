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
azswap import [-Apply]            Adopt existing ~/.azure-* folders as profiles
azswap import -FromDefault [-Apply]
                                  Split ~/.azure into a profile per account
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

Profile folders live in your home folder. Set the `AZSWAP_HOME` environment variable to
keep them somewhere else; `azswap` then looks for `$env:AZSWAP_HOME/.azure-<profile>`.
The tests use it to work in a scratch folder.

`Get-Help azswap -Full` has the full reference and examples.

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

### From source

```powershell
git clone https://github.com/JoePittsy/azswap.git
Add-Content $PROFILE "Import-Module `"$PWD\azswap\azswap\azswap.psd1`""
. $PROFILE
```

Then create a profile for each identity:

```powershell
azswap new contoso 00000000-0000-0000-0000-000000000000
azswap new fabrikam fabrikam.onmicrosoft.com -Interactive
```

The tenant can be a tenant id or a domain. Tab completion covers commands and profile names.

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

## Development

```powershell
Invoke-Pester ./tests                                          # Pester 5
Invoke-ScriptAnalyzer ./azswap -Recurse -Settings PSGallery
```

The tests mock `az` and point `AZSWAP_HOME` at a scratch folder, so they never touch
your real profiles or sign in. CI runs both on Windows and Ubuntu.

### Releasing

1. Bump `ModuleVersion` in [`azswap/azswap.psd1`](azswap/azswap.psd1) and commit.
2. Tag the commit `vX.Y.Z` to match, and push the tag: `git push origin vX.Y.Z`.
3. The Publish workflow runs the tests, checks the tag matches the manifest, and
   publishes to the PowerShell Gallery. It needs a Gallery API key in the
   `PSGALLERY_API_KEY` repository secret.

## Licence

MIT
