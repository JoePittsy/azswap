@{
    RootModule           = 'azswap.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'fe50d101-a90f-4f2e-a31e-7b5e9b90e4c2'
    Author               = 'Joe Pitts'
    Copyright            = '(c) Joe Pitts. MIT licence.'
    Description          = 'Per-customer Azure CLI profiles. Gives each tenant identity its own AZURE_CONFIG_DIR folder that remembers its tenant, switches the current shell between them, and signs straight back in to the right tenant when a token expires.'
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
        }
    }
}
