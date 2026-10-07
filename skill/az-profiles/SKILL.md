---
name: az-profiles
description: Pick the right Azure CLI identity (azswap profile) before running any `az` command for a customer, tenant or repo, including `az devops`, `az boards`, `az repos`, `az pipelines`, `az rest`, `az account`, `az functionapp`, `az webapp`, `az keyvault` and `az deployment`. The user works across several Azure tenants with a separate az config folder for each, so an unprefixed `az` call may run as the wrong account in the wrong tenant. Use this skill whenever a task is about to call `az` or a tool that signs in through the Azure CLI (DefaultAzureCredential, func, VS Code Azure extensions), whenever az reports the wrong account, an expired login or an AADSTS error, or when the user asks to add a customer profile.
---

# Azure CLI profiles

Each customer identity has its own az config folder, `~/.azure-<name>` (or
`$AZSWAP_HOME/.azure-<name>`), managed by [`azswap`](https://github.com/JoePittsy/azswap).
`az` uses whichever folder `AZURE_CONFIG_DIR` points at, and each folder keeps its own
sign-in, token cache, default subscription and `az devops` settings.

**Never run `az` without picking a profile.** An unprefixed call uses `~/.azure`, which
may be signed in to any tenant.

## 1. List the profiles

Before the first `az` call in a task, list the profiles. This reads the profile folders
only: it never calls `az` or signs in.

```powershell
azswap list -AsJson
```
```bash
pwsh -NoProfile -Command 'Import-Module azswap; azswap list -AsJson'
```

It prints a JSON array, one object per profile:

| Field | Meaning |
|---|---|
| `name` | The profile name, used as `azswap run <name>` and `~/.azure-<name>` |
| `active` | `true` if it's the current shell's `AZURE_CONFIG_DIR` |
| `path` | The profile's az config folder |
| `tenant` | The tenant id or domain it signs in to |
| `account` | The account it's signed in as (from its default subscription), or `null` if never signed in |
| `expectedAccount` | The account it must be signed in as, or `null` if not recorded |
| `accountMismatch` | `true` when `account` and `expectedAccount` are both known and differ |
| `subscription`, `subscriptionId` | The default subscription, or `null` |
| `loginMethod` | `interactive`, `devicecode` or `null` (device code) |

`account` comes from the last sign-in and can be stale: it is not proof the token is
still valid. Step 3 checks that.

## 2. Pick the profile yourself

Choose the profile from the conversation without asking. Match what you know against each
profile's `name`, `account`, `expectedAccount`, `tenant` and `subscription`:

- the current directory or repo name (`D:\Source\Contoso\...`, `fabrikam-api`);
- Azure DevOps org URLs (`https://dev.azure.com/contoso`, `contoso.visualstudio.com`);
- customer or company names and their abbreviations, and resource names that embed them;
- account or email domains (`@contoso.com`, `contoso.onmicrosoft.com`);
- tenant ids, subscription names or ids in the task, a URL or an error message.

Then:

- Exactly one profile fits → use it, and say so in one clause the first time
  ("using `contoso`"), so a wrong guess is visible straight away.
- Two or more fit, or none do → ask the user, listing the candidates by name and account.
  Don't fall back to the `active` profile or to `~/.azure`.
- No profile for the customer yet → follow **Adding a customer**.
- Keep that profile for the rest of the task. Switch only when the conversation moves to
  another customer.
- The chosen profile has `accountMismatch: true` → **stop**, see step 3.

## 3. Check the account

Nothing persists between tool calls, so **set the profile on every call**:

```powershell
azswap run <name> -NoLogin -- az group list ...                       # PowerShell with azswap
```
```bash
AZURE_CONFIG_DIR=~/.azure-<name> az group list ...                    # Bash
```
```powershell
$env:AZURE_CONFIG_DIR = "$HOME\.azure-<name>"; az group list ...      # PowerShell without azswap
```

Use the `path` from step 1 for `AZURE_CONFIG_DIR` if profiles live outside the home folder.
`azswap run` points `AZURE_CONFIG_DIR` at the profile for one executable and restores it
afterwards; the output and `$LASTEXITCODE` come through. Always pass `-NoLogin`. It won't
run PowerShell scripts or cmdlets; wrap those as `-- pwsh -NoProfile -File <script> ...`.

Before the first real call, check who you are:

```powershell
azswap run <name> -NoLogin -- az account show --query "{user:user.name,sub:name,tenant:tenantId}" -o tsv
```
```bash
AZURE_CONFIG_DIR=~/.azure-<name> az account show --query "{user:user.name,sub:name,tenant:tenantId}" -o tsv
```

- The account is the profile's `expectedAccount` (or, with none recorded, plausibly the
  right one for the customer) → carry on.
- `Sign-in needed, but ...`, `Please run 'az login'` or an `AADSTS` error → the session
  has expired. **Stop** and give the user the sign-in line below. Do not continue against
  another profile.
- The wrong account → stop and say so. Never "make do" with whichever identity works.
- `accountMismatch: true` in the list, `WRONG ACCOUNT: ...` from azswap, or
  `Wrong account for '<name>'` from `azswap run` (which then did not run the command) →
  **stop and tell the user**: quote it and ask which account is right. Don't assume the
  recorded account is the right one, and never run `azswap <name> -Account ...` to
  silence it until the user has confirmed the account. `No expected account for '<name>'`
  means the same: ask the user to confirm it.

When two identities share a tenant, the tenant id alone does not tell you which one is
signed in. Always check the account.

## Signing in (the user runs this, never a tool call)

Sign-in is interactive, and from a tool call it either hangs waiting for a device code
or fails because the broker has no window. azswap refuses to sign in from non-interactive
hosts (no terminal attached, CI, `-NonInteractive`) and fails with an error naming the
command for the user to run instead. If your commands run in a terminal (a pty), azswap
can't tell, so pass `-NoLogin` to every `azswap <name>` or `azswap run` call. Never
run `azswap new` or `azswap login` yourself to fix a sign-in. Give the user one line to
run in their own terminal, the one from the error if there is one:

```powershell
azswap <name>
```

`azswap <name>` switches that shell to the profile, tests the token, and if it has expired
signs in to the profile's tenant with the profile's `loginMethod`. It then prints the
account, so they can confirm it's the right identity.

- If the sign-in fails with `AADSTS53003`, `AADSTS50097` or another Conditional Access
  error, the tenant blocks device code. Give the user `azswap login -Interactive`
  instead: it signs in through the browser and, once that succeeds, the profile
  remembers it, so plain `azswap <name>` works from then on.
- Set the profile's default subscription once with `az account set --subscription "<id>"`,
  so later calls don't need `--subscription`.

## Adding a customer

1. Suggest a short name (the customer's name, lower case).
2. The user runs `azswap new <name> <tenant> -Account <upn>` (with `-Interactive` if the
   tenant blocks device code). It creates the folder, records the tenant and the expected
   account, and signs in.
3. Run `azswap list -AsJson` again, check the account, then set the default subscription.

If the customer is already signed in to an old `~/.azure-<name>` folder or the default
`~/.azure`, `azswap import` (or `azswap import -FromDefault`) shows what it can adopt,
and the user adds `-Apply` to register it. It never signs in or runs `az`; signing in
to any profile it creates is still the user's job (`azswap <name>`).

## Gotchas

- **Other tools still use `~/.azure`.** The VS Code Azure extensions, Azure Functions
  Core Tools and `DefaultAzureCredential` (through `AzureCliCredential`) ignore these
  folders unless `AZURE_CONFIG_DIR` is set in the process that starts them.
  `azswap run <name> -NoLogin -- func start` (or `-- code .`) starts one under a profile.
- **`AZURE_DEVOPS_EXT_PAT` overrides the profile's sign-in** for `az devops` / `az boards`
  if it is set. Unset it when the board answers as the wrong user.
- On Windows, `az` output can pass through cp1252, so non-ASCII characters in
  subscription names print as `�`. Match subscriptions by id, not by name.
