@{
    RootModule = 'Capsulenv.psm1'
    ModuleVersion = '0.15.4'
    GUID = 'fd343cc9-98c9-4ddf-bff5-89de07a77ee9'
    Author = 'capsulenv contributors'
    CompanyName = 'Community'
    Copyright = '(c) capsulenv contributors'
    Description = 'A portable Windows Scoop development environment with relocation-aware caches and lifecycle rehydration.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        '__GENERATED_FUNCTIONS__'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @(
        '__GENERATED_ALIASES__'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('portable', 'scoop', 'environment', 'windows')
        }
    }
}
