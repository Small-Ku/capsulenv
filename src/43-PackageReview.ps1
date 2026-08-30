function ConvertTo-CapsulenvReviewLines {
    [CmdletBinding()]
    param($Value)

    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Value) { return @() }

    $items = if ($Value -is [string]) { @([string]$Value) } else { @($Value) }
    foreach ($item in $items) {
        $text = if ($item -is [string]) {
            [string]$item
        } else {
            $item | ConvertTo-Json -Depth 12
        }
        foreach ($line in @($text -split "`r?`n")) {
            $lines.Add([string]$line)
        }
    }
    return $lines.ToArray()
}

function ConvertTo-CapsulenvReviewDisplayText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Text.ToCharArray()) {
        $code = [int][char]$character
        if ($code -eq 9) {
            [void]$builder.Append('    ')
        } elseif ($code -lt 32 -or ($code -ge 127 -and $code -le 159)) {
            [void]$builder.Append(('<0x{0:X2}>' -f $code))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-CapsulenvPackageEffectiveManifestPropertySource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Architecture
    )

    $architectureRecord = Get-CapsulenvJsonPropertyRecord -Object $Manifest -Name 'architecture'
    if ($null -ne $architectureRecord -and $null -ne $architectureRecord.Value) {
        $selectedArchitecture = Get-CapsulenvJsonPropertyRecord -Object $architectureRecord.Value -Name $Architecture
        if ($null -ne $selectedArchitecture -and $null -ne $selectedArchitecture.Value) {
            $architectureProperty = Get-CapsulenvJsonPropertyRecord -Object $selectedArchitecture.Value -Name $Name
            if ($null -ne $architectureProperty) {
                return [pscustomobject]@{
                    Exists = $true
                    Path = "architecture.$Architecture.$Name"
                    Value = $architectureProperty.Value
                }
            }
        }
    }

    $rootProperty = Get-CapsulenvJsonPropertyRecord -Object $Manifest -Name $Name
    if ($null -ne $rootProperty) {
        return [pscustomobject]@{ Exists = $true; Path = $Name; Value = $rootProperty.Value }
    }
    return [pscustomobject]@{ Exists = $false; Path = $Name; Value = $null }
}

function Get-CapsulenvPackageReviewItems {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Package)

    $manifest = $Package.SourceManifest
    $architecture = [string]$Package.Architecture
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($hookName in @('pre_install', 'post_install', 'pre_uninstall', 'post_uninstall')) {
        $property = Get-CapsulenvPackageEffectiveManifestPropertySource -Manifest $manifest -Name $hookName -Architecture $architecture
        if (-not $property.Exists -or $null -eq $property.Value -or @($property.Value).Count -eq 0) { continue }
        $items.Add([pscustomobject][ordered]@{
            Field = [string]$property.Path
            Kind = 'LifecycleScript'
            Summary = 'Arbitrary PowerShell lifecycle code executed by upstream Scoop.'
            Lines = @(ConvertTo-CapsulenvReviewLines -Value $property.Value)
        })
    }

    foreach ($installerName in @('installer', 'uninstaller')) {
        $property = Get-CapsulenvPackageEffectiveManifestPropertySource -Manifest $manifest -Name $installerName -Architecture $architecture
        if (-not $property.Exists -or $null -eq $property.Value) { continue }
        $scriptProperty = Get-CapsulenvJsonPropertyRecord -Object $property.Value -Name 'script'
        if ($null -ne $scriptProperty -and $null -ne $scriptProperty.Value -and @($scriptProperty.Value).Count -gt 0) {
            $items.Add([pscustomobject][ordered]@{
                Field = ([string]$property.Path + '.script')
                Kind = 'LifecycleScript'
                Summary = "Arbitrary PowerShell code inside Scoop $installerName semantics."
                Lines = @(ConvertTo-CapsulenvReviewLines -Value $scriptProperty.Value)
            })
        } else {
            $items.Add([pscustomobject][ordered]@{
                Field = [string]$property.Path
                Kind = 'ExternalInstaller'
                Summary = "External $installerName lifecycle delegated to upstream Scoop/the package installer."
                Lines = @(ConvertTo-CapsulenvReviewLines -Value $property.Value)
            })
        }
    }

    $inno = Get-CapsulenvPackageEffectiveManifestPropertySource -Manifest $manifest -Name 'innosetup' -Architecture $architecture
    if ($inno.Exists -and [bool]$inno.Value) {
        $items.Add([pscustomobject][ordered]@{
            Field = [string]$inno.Path
            Kind = 'ExternalInstaller'
            Summary = 'Inno Setup extraction/execution semantics are delegated to upstream Scoop.'
            Lines = @([string]$inno.Value)
        })
    }

    return $items.ToArray()
}

function Get-CapsulenvPackageReviewChecklist {
    [CmdletBinding()]
    param()

    return @(
        'Trace every command and executable launch; confirm arguments, quoting, elevation and child processes are expected. Remember that upstream Scoop lifecycle scripts run with Scoop variables such as $dir and $persist_dir, not Capsulenv PortableSafe isolation.',
        'Check every network endpoint and any secondary download. Scoop hash verification only covers artifacts declared by the manifest.',
        'Trace writes outside the package/persist directories, especially user profile, AppData, ProgramData, Windows and other drives.',
        'Inspect registry, environment, PATH, shortcuts, services, scheduled tasks, file associations and other host-wide integration.',
        'Check secrets/credentials, telemetry and commands that read or upload host data.',
        'Review uninstall/update symmetry: identify what upstream lifecycle code may leave behind or overwrite on later versions.',
        'Treat this checklist as guidance, not a proof of safety. TrustedExecution remains outside Capsulenv PortableSafe guarantees.'
    )
}

function Resolve-CapsulenvPackageReviewRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    if ($Reference -match '^(?i:(scoop(?::(?:user|global))?|user|global))/') {
        $installed = Get-CapsulenvInstalledApp -Selector $Reference
        $bucketProperty = Get-CapsulenvJsonPropertyRecord -Object $installed.Install -Name 'bucket'
        $bucket = if ($null -ne $bucketProperty) { [string]$bucketProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($bucket)) {
            throw (New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.Package.ReviewSourceUnknown' `
                -Message "Installed app '$($installed.Selector)' does not record a source bucket, so Capsulenv cannot identify the manifest that a future Scoop update would execute." `
                -Category ([System.Management.Automation.ErrorCategory]::InvalidData) `
                -TargetObject ([string]$installed.Selector) `
                -Remediation @(
                    "Inspect the installed manifest directly at '$($installed.ManifestPath)'.",
                    'Restore/add the source bucket before approving an upstream Scoop update.'
                ))
        }
        return [pscustomobject][ordered]@{
            RequestReference = [string]$installed.Selector
            PlanReference = "$bucket/$($installed.Name)"
            Operation = 'Update'
            InstalledSelector = [string]$installed.Selector
            InstalledManifestPath = [string]$installed.ManifestPath
        }
    }

    return [pscustomobject][ordered]@{
        RequestReference = $Reference
        PlanReference = $Reference
        Operation = 'Install'
        InstalledSelector = ''
        InstalledManifestPath = ''
    }
}


function ConvertTo-CapsulenvPackageReviewCanonicalValue {
    [CmdletBinding()]
    param($Value)

    return ([pscustomobject][ordered]@{ Value = $Value } | ConvertTo-Json -Depth 64 -Compress)
}

function Get-CapsulenvPackageManifestReviewEffects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [AllowEmptyString()][string]$Reference = ''
    )

    $effects = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($Reference)) {
        $effects.Add([pscustomobject][ordered]@{
            Name = 'source'
            Category = 'Package'
            Path = 'source'
            Value = $Reference
        })
    }

    $definitions = @(
        [pscustomobject]@{ Name='version'; Category='Package'; RootOnly=$true },
        [pscustomobject]@{ Name='url'; Category='Artifact'; RootOnly=$false },
        [pscustomobject]@{ Name='hash'; Category='Artifact'; RootOnly=$false },
        [pscustomobject]@{ Name='depends'; Category='Dependency'; RootOnly=$false },
        [pscustomobject]@{ Name='extract_dir'; Category='Extraction'; RootOnly=$false },
        [pscustomobject]@{ Name='extract_to'; Category='Extraction'; RootOnly=$false },
        [pscustomobject]@{ Name='bin'; Category='CommandSurface'; RootOnly=$false },
        [pscustomobject]@{ Name='persist'; Category='Persistence'; RootOnly=$false },
        [pscustomobject]@{ Name='env_add_path'; Category='Environment'; RootOnly=$false },
        [pscustomobject]@{ Name='env_set'; Category='Environment'; RootOnly=$false },
        [pscustomobject]@{ Name='shortcuts'; Category='HostIntegration'; RootOnly=$false },
        [pscustomobject]@{ Name='pre_install'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='post_install'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='pre_uninstall'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='post_uninstall'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='installer'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='uninstaller'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='innosetup'; Category='Lifecycle'; RootOnly=$false },
        [pscustomobject]@{ Name='cookie'; Category='NetworkAuth'; RootOnly=$false },
        [pscustomobject]@{ Name='psmodule'; Category='Lifecycle'; RootOnly=$false }
    )

    $capturedNames = @($definitions | ForEach-Object { [string]$_.Name })
    foreach ($definition in $definitions) {
        $property = if ([bool]$definition.RootOnly) {
            $record = Get-CapsulenvJsonPropertyRecord -Object $Manifest -Name ([string]$definition.Name)
            if ($null -eq $record) {
                [pscustomobject]@{ Exists=$false; Path=[string]$definition.Name; Value=$null }
            } else {
                [pscustomobject]@{ Exists=$true; Path=[string]$definition.Name; Value=$record.Value }
            }
        } else {
            Get-CapsulenvPackageEffectiveManifestPropertySource -Manifest $Manifest -Name ([string]$definition.Name) -Architecture $Architecture
        }
        if (-not [bool]$property.Exists -or $null -eq $property.Value) { continue }
        $effects.Add([pscustomobject][ordered]@{
            Name = [string]$definition.Name
            Category = [string]$definition.Category
            Path = [string]$property.Path
            Value = $property.Value
        })
    }

    $metadataOnlyRootNames = @('$schema', '_comment', '##', 'architecture', 'autoupdate', 'checkver', 'description', 'homepage', 'license', 'notes', 'suggest')
    foreach ($property in @($Manifest.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($capturedNames -contains $name -or $metadataOnlyRootNames -contains $name) { continue }
        $effects.Add([pscustomobject][ordered]@{
            Name = "unknown:$name"
            Category = 'Unsupported'
            Path = $name
            Value = $property.Value
        })
    }

    $architectureRecord = Get-CapsulenvJsonPropertyRecord -Object $Manifest -Name 'architecture'
    if ($null -ne $architectureRecord -and $null -ne $architectureRecord.Value) {
        $selectedArchitecture = Get-CapsulenvJsonPropertyRecord -Object $architectureRecord.Value -Name $Architecture
        if ($null -ne $selectedArchitecture -and $null -ne $selectedArchitecture.Value) {
            foreach ($property in @($selectedArchitecture.Value.PSObject.Properties)) {
                $name = [string]$property.Name
                if ($capturedNames -contains $name -or $name -eq 'checkver') { continue }
                $effects.Add([pscustomobject][ordered]@{
                    Name = "unknown:architecture.$Architecture.$name"
                    Category = 'Unsupported'
                    Path = "architecture.$Architecture.$name"
                    Value = $property.Value
                })
            }
        }
    }

    return $effects.ToArray()
}

function Resolve-CapsulenvPackageReviewPlanDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Dependency,
        [Parameter(Mandatory = $true)]$ParentPackage,
        [Parameter(Mandatory = $true)][object[]]$Packages
    )

    $resolvedReference = Resolve-CapsulenvPackageDependencyReference -Dependency $Dependency -ParentPlan $ParentPackage
    $parsed = Split-CapsulenvPackageReference -Reference $resolvedReference
    $matches = @($Packages | Where-Object {
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, [string]$parsed.Name) -and
        ([string]::IsNullOrWhiteSpace([string]$parsed.Bucket) -or [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Bucket, [string]$parsed.Bucket))
    })
    if ($matches.Count -eq 1) { return [string]$matches[0].Reference }
    if ($matches.Count -gt 1) {
        throw "Resolved dependency '$Dependency' is ambiguous inside the package plan for '$($ParentPackage.Reference)'."
    }
    throw "Resolved dependency '$Dependency' is missing from the package plan for '$($ParentPackage.Reference)'."
}

function Get-CapsulenvPackageReviewGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $packages = @($Plan.Packages)
    $rootPackage = @($packages | Where-Object {
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Reference, [string]$Plan.Reference)
    })
    if ($rootPackage.Count -ne 1) {
        $rootPackage = @($packages | Select-Object -Last 1)
    }
    if ($rootPackage.Count -ne 1) { throw "Package review graph has no root for '$($Plan.Reference)'." }
    $rootReference = [string]$rootPackage[0].Reference

    $dependenciesByReference = @{}
    $directByReference = @{}
    foreach ($package in $packages) {
        $reference = [string]$package.Reference
        $dependencies = New-Object System.Collections.Generic.List[string]
        foreach ($dependency in @($package.Dependencies)) {
            $dependencies.Add((Resolve-CapsulenvPackageReviewPlanDependency -Dependency ([string]$dependency) -ParentPackage $package -Packages $packages))
        }
        $dependenciesByReference[$reference.ToLowerInvariant()] = $dependencies.ToArray()
        $directByReference[$reference.ToLowerInvariant()] = (
            [string]$package.Classification -ne 'PortableSafe' -or
            ($Operation -eq 'Update' -and [System.StringComparer]::OrdinalIgnoreCase.Equals($reference, $rootReference))
        )
    }

    $blockersByReference = @{}
    function Get-NodeBlockers {
        param([string]$Reference)
        $key = $Reference.ToLowerInvariant()
        if ($blockersByReference.ContainsKey($key)) { return @($blockersByReference[$key]) }
        $items = New-Object System.Collections.Generic.List[string]
        if ([bool]$directByReference[$key]) { $items.Add($Reference) }
        foreach ($dependency in @($dependenciesByReference[$key])) {
            foreach ($blocker in @(Get-NodeBlockers -Reference ([string]$dependency))) {
                if (-not $items.Contains([string]$blocker)) { $items.Add([string]$blocker) }
            }
        }
        $blockersByReference[$key] = $items.ToArray()
        return $items.ToArray()
    }
    [void](Get-NodeBlockers -Reference $rootReference)

    $nodes = @(
        foreach ($package in $packages) {
            $reference = [string]$package.Reference
            $key = $reference.ToLowerInvariant()
            $direct = [bool]$directByReference[$key]
            $blockers = @(Get-NodeBlockers -Reference $reference)
            [pscustomobject][ordered]@{
                Name = [string]$package.Name
                Reference = $reference
                Version = [string]$package.Version
                Architecture = [string]$package.Architecture
                Classification = [string]$package.Classification
                DirectReviewRequired = $direct
                EffectiveReviewRequired = ($blockers.Count -gt 0)
                ExecutionBoundary = if ($blockers.Count -gt 0) { 'TrustedExecution' } else { 'PortableSafe' }
                Dependencies = @($dependenciesByReference[$key])
                BlockingDescendants = @($blockers | Where-Object { -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_, $reference) })
                ManifestPath = [string]$package.ManifestPath
                ManifestSha256 = Get-CapsulenvFileSha256 -Path ([string]$package.ManifestPath)
                Effects = @(Get-CapsulenvPackageManifestReviewEffects -Manifest $package.SourceManifest -Architecture ([string]$package.Architecture) -Reference $reference)
            }
        }
    )

    $nodeByReference = @{}
    foreach ($node in $nodes) { $nodeByReference[([string]$node.Reference).ToLowerInvariant()] = $node }
    $reviewOrder = New-Object System.Collections.Generic.List[string]
    $reviewVisited = @{}
    function Add-ReviewNodeOrder {
        param([string]$Reference)
        $key = $Reference.ToLowerInvariant()
        if ($reviewVisited.ContainsKey($key)) { return }
        $reviewVisited[$key] = $true
        $reviewOrder.Add($Reference)
        foreach ($dependency in @($dependenciesByReference[$key])) {
            Add-ReviewNodeOrder -Reference ([string]$dependency)
        }
    }
    Add-ReviewNodeOrder -Reference $rootReference
    $nodes = @($reviewOrder.ToArray() | ForEach-Object { $nodeByReference[$_.ToLowerInvariant()] })

    $directBlockers = @($nodes | Where-Object DirectReviewRequired | ForEach-Object { [string]$_.Reference })
    $paths = New-Object System.Collections.Generic.List[object]
    function Add-BlockerPaths {
        param([string]$Current, [string[]]$Path)
        $newPath = @($Path + $Current)
        if ($directBlockers -contains $Current) {
            $paths.Add([pscustomobject][ordered]@{ Blocker=$Current; Path=$newPath })
        }
        foreach ($dependency in @($dependenciesByReference[$Current.ToLowerInvariant()])) {
            Add-BlockerPaths -Current ([string]$dependency) -Path $newPath
        }
    }
    Add-BlockerPaths -Current $rootReference -Path @()

    $edges = @(
        foreach ($node in $nodes) {
            foreach ($dependency in @($node.Dependencies)) {
                [pscustomobject][ordered]@{ From=[string]$node.Reference; To=[string]$dependency }
            }
        }
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Root = $rootReference
        Nodes = $nodes
        Edges = $edges
        ReviewPaths = $paths.ToArray()
        DirectBlockers = $directBlockers
        ReviewRequired = ($paths.Count -gt 0)
    }
}

function Get-CapsulenvInstalledScoopReviewGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Selector)

    $root = Get-CapsulenvInstalledApp -Selector $Selector
    if ([string]$root.Provider -ne 'Scoop' -or [string]$root.ProviderScope -notin @('User', 'Global')) {
        throw "Installed Scoop review graph requires an upstream Scoop selector: $Selector"
    }
    $scopePrefix = 'scoop:{0}' -f ([string]$root.ProviderScope).ToLowerInvariant()
    $nodesByName = @{}
    $warnings = New-Object System.Collections.Generic.List[string]

    function Add-InstalledNode {
        param($App)
        $key = ([string]$App.Name).ToLowerInvariant()
        if ($nodesByName.ContainsKey($key)) { return }

        $architecture = Get-CapsulenvInstalledScoopArchitecture -App $App
        $bucketProperty = Get-CapsulenvJsonPropertyRecord -Object $App.Install -Name 'bucket'
        $bucket = if ($null -ne $bucketProperty) { [string]$bucketProperty.Value } else { '' }
        $reference = if ([string]::IsNullOrWhiteSpace($bucket)) { [string]$App.Name } else { "$bucket/$($App.Name)" }
        $versionProperty = Get-CapsulenvJsonPropertyRecord -Object $App.Manifest -Name 'version'
        $version = if ($null -ne $versionProperty) { [string]$versionProperty.Value } else { '' }
        $dependsProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $App -Name 'depends'
        $dependencyNames = New-Object System.Collections.Generic.List[string]
        if ($null -ne $dependsProperty.Value) {
            foreach ($dependency in @((ConvertTo-CapsulenvPackageValueArray -Value $dependsProperty.Value).Items)) {
                try {
                    $parsed = Split-CapsulenvPackageReference -Reference ([string]$dependency)
                    if (-not $dependencyNames.Contains([string]$parsed.Name)) { $dependencyNames.Add([string]$parsed.Name) }
                } catch {
                    $warnings.Add("Installed manifest '$($App.ManifestPath)' contains an invalid dependency '$dependency'.")
                }
            }
        }
        $node = [pscustomobject][ordered]@{
            Name = [string]$App.Name
            Reference = $reference
            Selector = [string]$App.Selector
            Version = $version
            Architecture = $architecture
            ManifestPath = [string]$App.ManifestPath
            ManifestSha256 = Get-CapsulenvFileSha256 -Path ([string]$App.ManifestPath)
            DependencyNames = $dependencyNames.ToArray()
            Dependencies = @()
            Effects = @(Get-CapsulenvPackageManifestReviewEffects -Manifest $App.Manifest -Architecture $architecture -Reference $reference)
        }
        $nodesByName[$key] = $node

        $resolvedDependencies = New-Object System.Collections.Generic.List[string]
        foreach ($dependencyName in @($node.DependencyNames)) {
            $dependencySelector = "$scopePrefix/$dependencyName"
            $dependencyApp = Get-CapsulenvInstalledApp -Selector $dependencySelector -AllowMissing
            if ($null -eq $dependencyApp) {
                $warnings.Add("Installed dependency '$dependencySelector' is missing, so the old update closure is incomplete.")
                continue
            }
            Add-InstalledNode -App $dependencyApp
            $resolvedDependencies.Add([string]$dependencyApp.Name)
        }
        $node.Dependencies = $resolvedDependencies.ToArray()
    }

    Add-InstalledNode -App $root
    $nodes = @($nodesByName.Values | Sort-Object Name)
    $edges = @(
        foreach ($node in $nodes) {
            foreach ($dependencyName in @($node.Dependencies)) {
                [pscustomobject][ordered]@{ From=[string]$node.Name; To=[string]$dependencyName }
            }
        }
    )
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        RootName = [string]$root.Name
        Scope = [string]$root.Scope
        Nodes = $nodes
        Edges = $edges
        Complete = ($warnings.Count -eq 0)
        Warnings = $warnings.ToArray()
    }
}

function Compare-CapsulenvPackageReviewEffects {
    [CmdletBinding()]
    param(
        [object[]]$OldEffects = @(),
        [object[]]$NewEffects = @()
    )

    $oldByName = @{}
    foreach ($effect in @($OldEffects)) { if ($null -ne $effect) { $oldByName[[string]$effect.Name] = $effect } }
    $newByName = @{}
    foreach ($effect in @($NewEffects)) { if ($null -ne $effect) { $newByName[[string]$effect.Name] = $effect } }
    $names = @($oldByName.Keys + $newByName.Keys | Sort-Object -Unique)
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        $old = if ($oldByName.ContainsKey($name)) { $oldByName[$name] } else { $null }
        $new = if ($newByName.ContainsKey($name)) { $newByName[$name] } else { $null }
        $oldCanonical = if ($null -eq $old) { $null } else { ConvertTo-CapsulenvPackageReviewCanonicalValue -Value $old.Value }
        $newCanonical = if ($null -eq $new) { $null } else { ConvertTo-CapsulenvPackageReviewCanonicalValue -Value $new.Value }
        if ([System.StringComparer]::Ordinal.Equals($oldCanonical, $newCanonical)) { continue }
        $changes.Add([pscustomobject][ordered]@{
            Name = [string]$name
            Category = if ($null -ne $new) { [string]$new.Category } else { [string]$old.Category }
            Change = if ($null -eq $old) { 'Added' } elseif ($null -eq $new) { 'Removed' } else { 'Changed' }
            OldPath = if ($null -eq $old) { '' } else { [string]$old.Path }
            NewPath = if ($null -eq $new) { '' } else { [string]$new.Path }
            OldValue = if ($null -eq $old) { $null } else { $old.Value }
            NewValue = if ($null -eq $new) { $null } else { $new.Value }
        })
    }
    return $changes.ToArray()
}

function Compare-CapsulenvPackageReviewGraphs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$OldGraph,
        [Parameter(Mandatory = $true)]$NewGraph
    )

    $oldByName = @{}
    foreach ($node in @($OldGraph.Nodes)) { $oldByName[[string]$node.Name] = $node }
    $newByName = @{}
    foreach ($node in @($NewGraph.Nodes)) { $newByName[[string]$node.Name] = $node }
    $names = @($oldByName.Keys + $newByName.Keys | Sort-Object -Unique)
    $nodes = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        $old = if ($oldByName.ContainsKey($name)) { $oldByName[$name] } else { $null }
        $new = if ($newByName.ContainsKey($name)) { $newByName[$name] } else { $null }
        $oldEffects = if ($null -eq $old) { @() } else { @($old.Effects) }
        $newEffects = if ($null -eq $new) { @() } else { @($new.Effects) }
        $changes = @(Compare-CapsulenvPackageReviewEffects -OldEffects $oldEffects -NewEffects $newEffects)
        $status = if ($null -eq $old) { 'Added' } elseif ($null -eq $new) { 'Removed' } elseif ($changes.Count -gt 0) { 'Changed' } else { 'Unchanged' }
        $nodes.Add([pscustomobject][ordered]@{
            Name = [string]$name
            Status = $status
            OldReference = if ($null -eq $old) { '' } else { [string]$old.Reference }
            NewReference = if ($null -eq $new) { '' } else { [string]$new.Reference }
            OldVersion = if ($null -eq $old) { '' } else { [string]$old.Version }
            NewVersion = if ($null -eq $new) { '' } else { [string]$new.Version }
            Changes = $changes
        })
    }

    $oldEdges = @{}
    foreach ($edge in @($OldGraph.Edges)) { $oldEdges[("{0}->{1}" -f [string]$edge.From, [string]$edge.To).ToLowerInvariant()] = $edge }
    $newEdges = @{}
    foreach ($edge in @($NewGraph.Edges)) {
        $fromNode = @($NewGraph.Nodes | Where-Object Reference -eq ([string]$edge.From))[0]
        $toNode = @($NewGraph.Nodes | Where-Object Reference -eq ([string]$edge.To))[0]
        if ($null -eq $fromNode -or $null -eq $toNode) { continue }
        $newEdges[("{0}->{1}" -f [string]$fromNode.Name, [string]$toNode.Name).ToLowerInvariant()] = [pscustomobject]@{ From=[string]$fromNode.Name; To=[string]$toNode.Name }
    }
    $addedEdges = @($newEdges.Keys | Where-Object { -not $oldEdges.ContainsKey($_) } | Sort-Object | ForEach-Object { $newEdges[$_] })
    $removedEdges = @($oldEdges.Keys | Where-Object { -not $newEdges.ContainsKey($_) } | Sort-Object | ForEach-Object { $oldEdges[$_] })

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        CompleteOldClosure = [bool]$OldGraph.Complete
        Warnings = @($OldGraph.Warnings)
        Nodes = $nodes.ToArray()
        AddedNodes = @($nodes | Where-Object Status -eq 'Added' | ForEach-Object { [string]$_.Name })
        RemovedNodes = @($nodes | Where-Object Status -eq 'Removed' | ForEach-Object { [string]$_.Name })
        ChangedNodes = @($nodes | Where-Object Status -eq 'Changed' | ForEach-Object { [string]$_.Name })
        AddedEdges = $addedEdges
        RemovedEdges = $removedEdges
        HasChanges = (@($nodes | Where-Object Status -ne 'Unchanged').Count -gt 0 -or $addedEdges.Count -gt 0 -or $removedEdges.Count -gt 0)
    }
}

function Get-CapsulenvPackageReviewPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $request = Resolve-CapsulenvPackageReviewRequest -Reference $Reference
    $plan = Get-CapsulenvPackageInstallPlan -Reference ([string]$request.PlanReference)
    $normalizedReference = [string]$plan.Reference
    $operation = [string]$request.Operation
    $graph = Get-CapsulenvPackageReviewGraph -Plan $plan -Operation $operation
    $rootReference = [string]$graph.Root
    $packages = @(
        foreach ($package in @($plan.Packages)) {
            $graphNode = @($graph.Nodes | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Reference, [string]$package.Reference) })[0]
            if ($null -eq $graphNode -or -not [bool]$graphNode.DirectReviewRequired) { continue }
            $isRequestedUpstreamUpdate = (
                $operation -eq 'Update' -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$package.Reference, $rootReference)
            )
            $reasons = New-Object System.Collections.Generic.List[string]
            foreach ($reason in @($package.Reasons)) { $reasons.Add([string]$reason) }
            if ($isRequestedUpstreamUpdate) {
                $reasons.Add("$([string]$request.InstalledSelector) is upstream Scoop-owned; update execution and host mutation remain outside Capsulenv PortableSafe ownership even when the current manifest is declarative.")
            }
            [pscustomobject][ordered]@{
                Reference = [string]$package.Reference
                Version = [string]$package.Version
                Architecture = [string]$package.Architecture
                Classification = [string]$package.Classification
                ManifestPath = [string]$package.ManifestPath
                ManifestSha256 = Get-CapsulenvFileSha256 -Path ([string]$package.ManifestPath)
                Reasons = $reasons.ToArray()
                ReviewItems = @(Get-CapsulenvPackageReviewItems -Package $package)
            }
        }
    )

    $reviewRequired = [bool]$graph.ReviewRequired
    $diff = $null
    if ($operation -eq 'Update') {
        $oldGraph = Get-CapsulenvInstalledScoopReviewGraph -Selector ([string]$request.InstalledSelector)
        $diff = Compare-CapsulenvPackageReviewGraphs -OldGraph $oldGraph -NewGraph $graph
    }
    $nextCommand = if ($operation -eq 'Update') {
        "capsulenv app update $([string]$request.InstalledSelector) --allow-trusted"
    } elseif ($reviewRequired) {
        "capsulenv app install $normalizedReference --allow-trusted"
    } else {
        "capsulenv app install $normalizedReference"
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        RequestReference = [string]$request.RequestReference
        Reference = $normalizedReference
        Operation = $operation
        InstalledSelector = [string]$request.InstalledSelector
        Classification = [string]$plan.Classification
        ExecutionBoundary = if ($reviewRequired) { 'TrustedExecution' } else { 'PortableSafe' }
        ReviewRequired = $reviewRequired
        Graph = $graph
        Diff = $diff
        Packages = $packages
        Checklist = @(Get-CapsulenvPackageReviewChecklist)
        RecommendedAction = if ($reviewRequired) {
            "After reviewing every propagated blocker and package/effect delta, run '$nextCommand' only if upstream Scoop lifecycle execution is acceptable."
        } else {
            "No TrustedExecution review is required; install with '$nextCommand'."
        }
    }
}

function Write-CapsulenvPackageReviewItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Item)

    Write-Host ("  {0}  [{1}]" -f [string]$Item.Field, [string]$Item.Kind) -ForegroundColor Yellow
    Write-Host ("    {0}" -f [string]$Item.Summary) -ForegroundColor DarkGray
    $lines = @($Item.Lines)
    $digits = [Math]::Max(1, ([string][Math]::Max(1, $lines.Count)).Length)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        Write-Host (("    {0," + $digits + "} | {1}") -f ($index + 1), (ConvertTo-CapsulenvReviewDisplayText -Text ([string]$lines[$index])))
    }
}

function Write-CapsulenvPackageReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Review,
        [switch]$Raw
    )

    if ($Raw.IsPresent) {
        $nodes = if ($null -ne $Review.PSObject.Properties['Graph']) { @($Review.Graph.Nodes) } else { @($Review.Packages) }
        foreach ($package in $nodes) {
            Write-Host ("=== {0} :: {1} ===" -f [string]$package.Reference, [string]$package.ManifestPath) -ForegroundColor Cyan
            Get-Content -LiteralPath ([string]$package.ManifestPath) -Raw | Write-Output
        }
        if ($nodes.Count -eq 0) {
            Write-CapsulenvMessage -Level Info -Message "'$($Review.Reference)' has no source manifest surface to review."
        }
        return
    }

    Write-Host ''
    Write-Host 'Trusted package review' -ForegroundColor Cyan
    Write-Host ("  Request        : {0}" -f [string]$Review.RequestReference)
    Write-Host ("  Review basis   : {0} of {1}" -f [string]$Review.Operation, [string]$Review.Reference)
    Write-Host ("  Classification : {0}" -f [string]$Review.Classification)
    Write-Host ("  Execution      : {0}" -f [string]$Review.ExecutionBoundary)
    Write-Host ("  Review required: {0}" -f [bool]$Review.ReviewRequired)

    if ($null -ne $Review.PSObject.Properties['Graph']) {
        Write-Host ''
        Write-Host 'Dependency trust propagation' -ForegroundColor Cyan
        foreach ($node in @($Review.Graph.Nodes)) {
            $direct = if ([bool]$node.DirectReviewRequired) { 'direct-review' } else { 'direct-safe' }
            $effective = [string]$node.ExecutionBoundary
            $suffix = if (@($node.BlockingDescendants).Count -gt 0) {
                ' via ' + (@($node.BlockingDescendants) -join ', ')
            } else { '' }
            Write-Host ("  {0}  [{1} -> {2}]{3}" -f [string]$node.Reference, $direct, $effective, $suffix)
            foreach ($dependency in @($node.Dependencies)) {
                Write-Host ("    depends -> {0}" -f [string]$dependency) -ForegroundColor DarkGray
            }
        }
        if (@($Review.Graph.ReviewPaths).Count -gt 0) {
            Write-Host '  Review paths:' -ForegroundColor DarkYellow
            foreach ($path in @($Review.Graph.ReviewPaths)) {
                Write-Host ("    {0}" -f (@($path.Path) -join ' -> '))
            }
        }
    }

    if ($null -ne $Review.PSObject.Properties['Diff'] -and $null -ne $Review.Diff) {
        Write-Host ''
        Write-Host 'Update DAG / effect delta' -ForegroundColor Cyan
        if (-not [bool]$Review.Diff.CompleteOldClosure) {
            Write-Host '  Old installed dependency closure is incomplete; removed-node/edge conclusions are conservative.' -ForegroundColor Yellow
        }
        foreach ($warning in @($Review.Diff.Warnings)) {
            Write-Host ("  Warning: {0}" -f [string]$warning) -ForegroundColor Yellow
        }
        $changed = @($Review.Diff.Nodes | Where-Object Status -ne 'Unchanged')
        if ($changed.Count -eq 0 -and @($Review.Diff.AddedEdges).Count -eq 0 -and @($Review.Diff.RemovedEdges).Count -eq 0) {
            Write-Host '  No execution-relevant manifest or dependency-edge changes detected.' -ForegroundColor Green
        } else {
            foreach ($node in $changed) {
                Write-Host ("  {0}: {1}  {2} -> {3}" -f [string]$node.Name, [string]$node.Status, [string]$node.OldVersion, [string]$node.NewVersion) -ForegroundColor White
                foreach ($change in @($node.Changes)) {
                    Write-Host ("    [{0}] {1}: {2}" -f [string]$change.Category, [string]$change.Name, [string]$change.Change) -ForegroundColor DarkYellow
                    if ($null -ne $change.OldValue) {
                        $oldText = (@(ConvertTo-CapsulenvReviewLines -Value $change.OldValue) | ForEach-Object { ConvertTo-CapsulenvReviewDisplayText -Text ([string]$_) }) -join ' | '
                        Write-Host ("      - {0}" -f $oldText) -ForegroundColor DarkGray
                    }
                    if ($null -ne $change.NewValue) {
                        $newText = (@(ConvertTo-CapsulenvReviewLines -Value $change.NewValue) | ForEach-Object { ConvertTo-CapsulenvReviewDisplayText -Text ([string]$_) }) -join ' | '
                        Write-Host ("      + {0}" -f $newText) -ForegroundColor DarkGray
                    }
                }
            }
            foreach ($edge in @($Review.Diff.RemovedEdges)) {
                Write-Host ("  dependency removed: {0} -> {1}" -f [string]$edge.From, [string]$edge.To) -ForegroundColor DarkYellow
            }
            foreach ($edge in @($Review.Diff.AddedEdges)) {
                Write-Host ("  dependency added  : {0} -> {1}" -f [string]$edge.From, [string]$edge.To) -ForegroundColor DarkYellow
            }
        }
    }

    if (-not [bool]$Review.ReviewRequired) {
        Write-Host ''
        Write-Host 'No arbitrary/unsupported lifecycle semantics are present in the resolved dependency graph.' -ForegroundColor Green
        Write-Host ([string]$Review.RecommendedAction) -ForegroundColor DarkGray
        return
    }

    foreach ($package in @($Review.Packages)) {
        Write-Host ''
        Write-Host ("Package  {0}  {1}  ({2})" -f [string]$package.Reference, [string]$package.Version, [string]$package.Architecture) -ForegroundColor White
        Write-Host ("  Classification: {0}" -f [string]$package.Classification) -ForegroundColor Yellow
        Write-Host ("  Manifest      : {0}" -f [string]$package.ManifestPath)
        Write-Host ("  SHA-256       : {0}" -f [string]$package.ManifestSha256)
        Write-Host '  Why review:' -ForegroundColor DarkYellow
        foreach ($reason in @($package.Reasons)) { Write-Host ("    - {0}" -f [string]$reason) }

        if (@($package.ReviewItems).Count -gt 0) {
            Write-Host '  Executable / external lifecycle surface:' -ForegroundColor DarkYellow
            foreach ($item in @($package.ReviewItems)) {
                Write-CapsulenvPackageReviewItem -Item $item
            }
        } else {
            Write-Host '  No bounded script fragment can represent this blocker; inspect the complete manifest.' -ForegroundColor DarkYellow
        }

        $literal = ConvertTo-CapsulenvPowerShellSingleQuotedLiteral -Value ([string]$package.ManifestPath)
        Write-Host '  Inspect complete manifest:' -ForegroundColor DarkYellow
        Write-Host ("    Get-Content -LiteralPath {0} -Raw" -f $literal) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Review checklist' -ForegroundColor Cyan
    $number = 1
    foreach ($item in @($Review.Checklist)) {
        Write-Host ("  {0}. {1}" -f $number, [string]$item)
        $number++
    }
    Write-Host ''
    Write-Host 'Next action' -ForegroundColor Cyan
    Write-Host ("  {0}" -f [string]$Review.RecommendedAction)
    Write-Host ("  To inspect the exact source manifests for the full resolved DAG: capsulenv app review {0} --raw" -f [string]$Review.RequestReference) -ForegroundColor DarkGray
}
