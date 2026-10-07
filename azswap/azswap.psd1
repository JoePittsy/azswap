@{
    RootModule           = 'azswap.psm1'
    ModuleVersion        = '0.0.3'
    GUID                 = 'fe50d101-a90f-4f2e-a31e-7b5e9b90e4c2'
    Author               = 'Joe Pitts'
    Copyright            = '(c) Joe Pitts. MIT licence.'
    Description          = 'Isolated Azure CLI profiles: one identity per shell. The Azure CLI keeps a single current subscription for your whole user account, so az account set in one terminal silently retargets every other terminal, script and agent. azswap gives each tenant identity its own AZURE_CONFIG_DIR folder and points only the current shell (or one command, with azswap run) at it. Profiles remember their tenant, sign-in method and expected account, sign straight back in when a token expires, warn about the wrong account, and never start a sign-in from scripts, CI or agents.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('azswap')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Azure', 'AzureCLI', 'az', 'AZURE_CONFIG_DIR', 'tenant', 'profile', 'multi-tenant', 'login', 'Windows', 'Linux', 'MacOS', 'PSEdition_Core', 'PSEdition_Desktop')
            LicenseUri = 'https://github.com/JoePittsy/azswap/blob/main/LICENSE'
            ProjectUri = 'https://github.com/JoePittsy/azswap'
            ReleaseNotes = @'
0.0.3
- -NewWindow (Windows) on a profile switch, login and new opens a new terminal window that does the sign-in there, so you can sign in when an agent or script needs it without leaving the session. Allowed from non-interactive hosts, because the calling process never signs in itself.
- The refusal message from non-interactive hosts suggests -NewWindow.
- The agent skill may offer to open a sign-in window (and only does so after you say yes), and warns that Claude Code's ! runs bash, where the module isn't available.
- A Claude Code plugin: /plugin marketplace add JoePittsy/azswap, then /plugin install azswap@azswap.

0.0.2
- azswap list -AsJson prints every profile as JSON (name, active, path, tenant, signed-in and expected account, mismatch flag, default subscription, sign-in method). Offline: it never calls az.
- The agent skill in skill/az-profiles is now generic: it reads azswap list -AsJson and works without editing.

0.0.1 - first public release.
- azswap <profile> switches the shell's AZURE_CONFIG_DIR and signs in to the profile's tenant when the token has expired.
- azswap new, login, list and help; tab completion for commands and profile names.
- Each profile remembers its sign-in method (device code or -Interactive browser/WAM sign-in).
- -Account records the account a profile must use; azswap warns on a mismatch and list marks it with '!'.
- azswap run <profile> -- <command> runs one executable under a profile and refuses to run as the wrong account.
- azswap import adopts existing ~/.azure-* folders, or splits ~/.azure into a profile per account (-FromDefault).
- Never signs in from non-interactive hosts (redirected input, CI, -NonInteractive) or with -NoLogin; fails with the command to run instead.
- Windows PowerShell 5.1 and PowerShell 7 on Windows, Linux and macOS.
'@
        }
    }
}
