@{
    RootModule           = 'azswap.psm1'
    ModuleVersion        = '0.0.1'
    GUID                 = 'fe50d101-a90f-4f2e-a31e-7b5e9b90e4c2'
    Author               = 'Joe Pitts'
    Copyright            = '(c) Joe Pitts. MIT licence.'
    Description          = 'Per-customer Azure CLI profiles. Gives each tenant identity its own AZURE_CONFIG_DIR folder that remembers its tenant, sign-in method and expected account. Switches the current shell between profiles or runs one command under a profile, signs straight back in to the right tenant when a token expires, warns about the wrong account, and never starts a sign-in from scripts, CI or agents.'
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
