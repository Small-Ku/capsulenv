@{
    RootModule = 'Capsulenv.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'fd343cc9-98c9-4ddf-bff5-89de07a77ee9'
    Author = 'capsulenv contributors'
    CompanyName = 'Community'
    Copyright = '(c) capsulenv contributors'
    Description = 'A reversible, portable Windows development environment built around Scoop.'
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
