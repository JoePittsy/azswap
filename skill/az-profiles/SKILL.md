---
name: az-profiles
description: Automatically pick the right Azure CLI identity for the customer under discussion before any `az` call, including `az devops`, `az boards`, `az rest` and `az functionapp`. The user works across several customer tenants with a separate az config folder (azswap profile) for each. Use this skill whenever a task runs `az` for a customer or repo, whenever az reports the wrong account or an expired login, or when adding a new customer profile.
---

<!--
  TEMPLATE. Fill in the two tables marked FILL IN with your own customers, then copy
  this folder to ~/.claude/skills/az-profiles/. Add the customer names to the
  description above too, so the skill triggers when you mention them.
  Your filled-in copy contains tenant ids and account names: keep it private.
-->

# Azure CLI profiles

Each customer identity has its own az config folder, `~/.azure-<name>`, managed by
[`azswap`](https://github.com/JoePittsy/azswap). `az` uses whichever folder `AZURE_CONFIG_DIR`
points at, and each folder keeps its own sign-in, token cache, default subscription and
`az devops` settings. Nothing persists between tool calls, so **set it on every call**:

```bash
AZURE_CONFIG_DIR=~/.azure-<name> az group list ...                    # Bash
```
```powershell
$env:AZURE_CONFIG_DIR = "$HOME\.azure-<name>"; az group list ...      # PowerShell
```

Where the `azswap` PowerShell module is loaded, `azswap run` does the same for one
command and restores the variable afterwards. It passes the output and exit code through,
and refuses to run as the wrong account. `-NoLogin` makes an expired token fail with the
sign-in line for the user instead of starting a sign-in:

```powershell
azswap run <name> -NoLogin -- az group list ...                       # PowerShell with azswap
```

Use the `AZURE_CONFIG_DIR` form wherever azswap may not be loaded (Bash, or a
`pwsh -NoProfile` call).

**Never run `az` without picking a profile.** An unprefixed call uses `~/.azure`, which
may be signed in to any tenant.

## Choosing the profile: infer it, don't ask

Work out the customer from the conversation and switch without asking. Use the first
cue that matches:

<!-- FILL IN: one row per cue. Repo folders, ADO orgs, resource names and nicknames work well. -->
| Cue | Profile |
|---|---|
| ADO org `https://dev.azure.com/contoso`, or Contoso / CTS mentioned | `contoso` |
| cwd under `D:\Source\Contoso\`, or a resource named `*-cts-*` | `contoso` |
| cwd under `D:\Source\Fabrikam\`, or Fabrikam mentioned | `fabrikam` |

- Say which profile you picked in one short clause the first time ("using `contoso`"),
  so a wrong guess is visible straight away.
- Keep that profile for the rest of the task. Switch only when the conversation
  moves to another customer.
- Ask only when cues point at two customers, or none match. No profile for the
  customer yet → follow **Adding a customer**.

## Profiles

<!-- FILL IN: `azswap list` prints the account and tenant for each profile. -->
| Name | Account | Tenant | Use for |
|---|---|---|---|
| `contoso` | `you@contoso.com` | `00000000-0000-0000-0000-000000000000` | Contoso subscriptions and ADO |
| `fabrikam` | `you.ext@fabrikam.com` | `11111111-1111-1111-1111-111111111111` | Fabrikam production subscription |

When two identities share a tenant, the tenant id alone does not tell you which one is
signed in. Always check the account.

## Before the first call in a task

```bash
AZURE_CONFIG_DIR=~/.azure-<name> az account show --query "{user:user.name,sub:name,tenant:tenantId}" -o tsv
```

- The account matches the table → carry on.
- `Please run 'az login'` or an `AADSTS` error → the session has expired. **Stop**
  and give the user the sign-in line below. Do not continue against another profile.
- The wrong account → stop and say so. Never "make do" with whichever identity works.
- `azswap` itself warns `WRONG ACCOUNT: ...` when a profile is signed in as someone other
  than its expected account, and `azswap list` marks the profile with `!`. Treat either as
  **stop and tell the user**: quote the warning and ask which account is right. Don't
  assume the recorded account is the right one, and never run
  `azswap <name> -Account ...` to silence the warning until the user has confirmed the
  account. `No expected account for '<name>'` means the same: ask the user to confirm it.

## Signing in (the user runs this, never a tool call)

Sign-in is interactive, and from a tool call it either hangs waiting for a device code
or fails because the broker has no window. azswap refuses to sign in from non-interactive
hosts and prints the command for the user to run instead. If your commands run in a
terminal (a pty), azswap can't tell, so pass `-NoLogin`. Give the user one line to run in
their own terminal:

```powershell
azswap <name>
```

`azswap <name>` switches that shell to the profile, tests the token, and if it has expired
signs in to the profile's tenant with the profile's remembered method: device code,
unless an interactive sign-in has succeeded through `azswap new ... -Interactive` or
`azswap login -Interactive`. It then prints the account, so they can confirm it's the
right identity.

- If the sign-in fails with `AADSTS53003`, `AADSTS50097` or another Conditional Access
  error, the tenant blocks device code. Give the user `azswap login -Interactive`
  instead: it signs in through the browser and, once that succeeds, the profile
  remembers it, so plain `azswap <name>` works from then on. A refused or failed
  sign-in records nothing.

- Set the profile's default subscription once with `az account set --subscription "<name>"`,
  so later calls don't need `--subscription`.

## Adding a customer

1. Choose a short name and add a row to both tables above.
2. The user runs `azswap new <name> <tenant> -Account <upn>` (with `-Interactive` if the
   tenant blocks device code; the profile remembers it once that first sign-in succeeds).
   It creates the folder, records the tenant and the expected account, and signs in.
3. Check the account it prints, then set the default subscription.

If the customer is already signed in to an old `~/.azure-<name>` folder or the default
`~/.azure`, `azswap import` (or `azswap import -FromDefault`) shows what it can adopt,
and the user adds `-Apply` to register it. It never signs in or runs `az`; signing in
to any profile it creates is still the user's job (`azswap <name>`).

## Gotchas

- **Other tools still use `~/.azure`.** The VS Code Azure extensions, Azure Functions
  Core Tools and `DefaultAzureCredential` (through `AzureCliCredential`) ignore these
  folders unless `AZURE_CONFIG_DIR` is set in the process that starts them. `azswap run <name> -- func start`
  (or `-- code .`) starts one under a profile.
- **`AZURE_DEVOPS_EXT_PAT` overrides the profile's sign-in** for `az devops` / `az boards`
  if it is set. Unset it when the board answers as the wrong user.
- On Windows, `az` output can pass through cp1252, so non-ASCII characters in
  subscription names print as `�`. Match subscriptions by id, not by name.
