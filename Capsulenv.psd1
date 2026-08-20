@{
    RootModule = 'Capsulenv.psm1'
    ModuleVersion = '0.17.2'
    GUID = 'fd343cc9-98c9-4ddf-bff5-89de07a77ee9'
    Author = 'capsulenv contributors'
    CompanyName = 'Community'
    Copyright = '(c) capsulenv contributors'
    Description = 'A portable Windows development environment with capability-planned packages, relocation-aware runtime projections, and optional Scoop integration.'
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
