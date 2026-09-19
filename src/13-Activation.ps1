function New-CapsulenvActivationResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('required', 'optional')]
        [string]$Criticality,
        [Parameter(Mandatory = $true)]
        [ValidateSet('program', 'binding', 'session-service')]
        [string]$Kind,
        $Requirement,
        $Value
    )

    return [pscustomobject][ordered]@{
        Name = $Name
        Criticality = $Criticality
        Kind = $Kind
        Requirement = $Requirement
        Value = $Value
    }
}

function New-CapsulenvActivationBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)]
        [ValidateSet('environment', 'path', 'module-path', 'session-integration')]
        [string]$Kind,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'required'
    )

    return [pscustomobject][ordered]@{
        Name = $Name
        Value = $Value
        Kind = $Kind
        Criticality = $Criticality
    }
}

function ConvertTo-CapsulenvGenerationProgramCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Selection
    )

    $selectionKind = if ($null -ne $Selection.PSObject.Properties['Kind']) { [string]$Selection.Kind } else { 'realization' }
    if ($selectionKind -eq 'host-program') {
        # Host Scoop is mutable outside Capsulenv. Re-discover the selected
        # provider/provenance at activation and validate the current executable
        # and version against the live requirement.
        $current = @(
            Get-CapsulenvProgramCandidates -Requirement $Requirement |
                Where-Object {
                    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Provider, [string]$Selection.Provider) -and
                    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Provenance, [string]$Selection.Provenance) -and
                    (
                        [string]::IsNullOrWhiteSpace([string]$Selection.Scope) -or
                        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Scope, [string]$Selection.Scope)
                    )
                } |
                Select-Object -First 1
        )
        if ($null -eq $current) {
            throw "Host program '$($Selection.Name)' is no longer available from its recorded provider binding."
        }
        return $current
    }
    if ($selectionKind -eq 'seed-acquisition') {
        $source = Resolve-CapsulenvPortableSeedSourcePath -Entry $Selection
        $Selection = Acquire-CapsulenvProgramRealization -Name ([string]$Selection.Name) -Version ([string]$Selection.Version) -SourcePath $source -ExecutableRelativePath ([string]$Selection.ExecutableRelativePath) -ExpectedHash ([string]$Selection.ExpectedHash) -Provider capsulenv-local -AcquisitionProvider seed -Provenance ([string]$Selection.Provenance)
    }
    $relative = [string]$Selection.ExecutableRelativePath
    $executable = Join-Path (Join-Path ([string]$Selection.RealizationRoot) 'payload') ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $authority = Get-CapsulenvRealizationAuthority -Manifest $Selection
    return New-CapsulenvProgramCandidate -Name ([string]$Selection.Name) -Executable $executable -Root ([string]$Selection.RealizationRoot) -Provider $authority.Provider -AcquisitionProvider $authority.AcquisitionProvider -Scope host-local -Version ([string]$Selection.Version) -Trusted:$true -OwnsLifecycle:$authority.OwnsLifecycle -Provenance ([string]$Selection.Provenance)
}

function Get-CapsulenvActiveGenerationProgram {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)

    $active = Get-CapsulenvActiveGeneration
    if ($null -eq $active -or $null -eq $active.Generation) {
        throw "Program '$($Requirement.Name)' has no active generation authority."
    }
    $selection = @($active.Generation.Selections |
        Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, [string]$Requirement.Name) } |
        Select-Object -First 1)
    if ($selection.Count -ne 1) {
        throw "Program '$($Requirement.Name)' is not selected by the active generation authority."
    }

    $candidate = ConvertTo-CapsulenvGenerationProgramCandidate -Requirement $Requirement -Selection $selection[0]
    # Generation metadata predates capability persistence. The binding still
    # validates the executable/version/provider contract here; required
    # capabilities are the binding's explicit contract and are carried on the
    # canonical selected candidate for downstream consumers.
    $candidate.Capabilities = @($candidate.Capabilities + @($Requirement.RequiredCapabilities) | Sort-Object -Unique)
    $check = Test-CapsulenvProgramCandidate -Requirement $Requirement -Candidate $candidate
    if (-not $check.Compatible) {
        throw "Active generation program '$($Requirement.Name)' failed binding validation: $($check.Reasons -join ', ')"
    }
    return $candidate
}

function Resolve-CapsulenvActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Resources,
        [object[]]$Bindings = @(),
        [object[]]$SessionIntegrations = @(),
        [object[]]$SessionServices = @()
    )

    $active = Get-CapsulenvActiveGeneration
    $requiredFailures = New-Object System.Collections.Generic.List[string]
    $diagnostics = New-Object System.Collections.Generic.List[string]
    $resolvedPrograms = New-Object System.Collections.Generic.List[object]
    $environment = [ordered]@{}
    $pathEntries = New-Object System.Collections.Generic.List[string]
    $moduleEntries = New-Object System.Collections.Generic.List[string]
    $integrationEntries = New-Object System.Collections.Generic.List[object]
    $serviceEntries = New-Object System.Collections.Generic.List[object]

    foreach ($resource in @($Resources)) {
        $kind = [string]$resource.Kind
        if ($kind -eq 'binding') {
            $bindingValue = $resource.Value
            $bindingKind = 'session-integration'
            $bindingName = [string]$resource.Name
            if ($null -ne $bindingValue -and $bindingValue.PSObject.Properties['Kind']) {
                $bindingKind = [string]$bindingValue.Kind
            }
            if ($null -ne $bindingValue -and $bindingValue.PSObject.Properties['Name']) {
                $bindingName = [string]$bindingValue.Name
            }
            $value = if ($null -eq $bindingValue) { '' } else { [string]$bindingValue.Value }
            if ($bindingValue -is [string]) {
                $value = [string]$bindingValue
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                $message = "Binding resource '$($resource.Name)' has no value."
                if ([string]$resource.Criticality -eq 'required') { $requiredFailures.Add($message) } else { $diagnostics.Add($message + ' Optional resource skipped.') }
                continue
            }
            $binding = [pscustomobject][ordered]@{
                Name = $bindingName
                Value = $value
                Kind = $bindingKind
                Criticality = [string]$resource.Criticality
            }
            switch ($bindingKind) {
                'environment' { $environment[$binding.Name] = $value }
                'path' { $pathEntries.Add($value) }
                'module-path' { $moduleEntries.Add($value) }
                'session-integration' { $integrationEntries.Add($binding) }
                default {
                    $message = "Binding resource '$($resource.Name)' has unknown kind '$bindingKind'."
                    if ([string]$resource.Criticality -eq 'required') { $requiredFailures.Add($message) } else { $diagnostics.Add($message + ' Optional resource skipped.') }
                }
            }
            continue
        }
        if ($kind -eq 'session-service') {
            $service = $resource.Value
            $serviceName = [string]$resource.Name
            $available = $false
            if ($null -ne $service) {
                if ($service.PSObject.Properties['Name']) { $serviceName = [string]$service.Name }
                $available = if ($service.PSObject.Properties['Available']) { [bool]$service.Available } else { $true }
            }
            if (-not $available) {
                $message = "SessionService resource '$serviceName' is unavailable."
                if ([string]$resource.Criticality -eq 'required') { $requiredFailures.Add($message) } else { $diagnostics.Add($message + ' Optional resource skipped.') }
            } else {
                $serviceEntries.Add($service)
            }
            continue
        }
        $requirement = $resource.Requirement
        $selection = $null
        if ($null -ne $active) {
            $selection = @($active.Generation.Selections | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, [string]$resource.Name) }) | Select-Object -First 1
        }
        if ($null -eq $selection) {
            $message = "Program '$($resource.Name)' has no active generation selection."
            if ([string]$resource.Criticality -eq 'required') {
                $requiredFailures.Add($message)
            } else {
                $diagnostics.Add($message + ' Optional resource skipped.')
            }
            continue
        }
        if ($null -eq $requirement -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$resource.Name, [string]$requirement.Name) -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$resource.Name, [string]$selection.Name)) {
            $message = "Program resource '$($resource.Name)' identities disagree with its requirement and generation selection."
            if ([string]$resource.Criticality -eq 'required') { $requiredFailures.Add($message) } else { $diagnostics.Add($message + ' Optional resource skipped.') }
            continue
        }
        try {
            $candidate = ConvertTo-CapsulenvGenerationProgramCandidate -Requirement $requirement -Selection $selection
        } catch {
            $message = "Program '$($resource.Name)' failed active-generation revalidation: $($_.Exception.Message)"
            if ([string]$resource.Criticality -eq 'required') {
                $requiredFailures.Add($message)
            } else {
                $diagnostics.Add($message + ' Optional resource skipped.')
            }
            continue
        }
        $resolution = Resolve-CapsulenvProgram -Requirement $requirement -Candidates @($candidate)
        if (-not $resolution.Succeeded) {
            $message = "Program '$($resource.Name)' failed active-generation validation."
            if ([string]$resource.Criticality -eq 'required') {
                $requiredFailures.Add($message)
            } else {
                $diagnostics.Add($message + ' Optional resource skipped.')
            }
            continue
        }
        $resolvedPrograms.Add($resolution.Selected)
    }

    foreach ($binding in @($Bindings)) {
        $value = [string]$binding.Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            $message = "Binding '$($binding.Name)' has no value."
            if ([string]$binding.Criticality -eq 'required') {
                $requiredFailures.Add($message)
            } else {
                $diagnostics.Add($message + ' Optional binding skipped.')
            }
            continue
        }
        switch ([string]$binding.Kind) {
            'environment' { $environment[[string]$binding.Name] = $value }
            'path' { $pathEntries.Add($value) }
            'module-path' { $moduleEntries.Add($value) }
            'session-integration' { $integrationEntries.Add($binding) }
            default {
                $message = "Binding '$($binding.Name)' has unknown kind '$($binding.Kind)'."
                if ([string]$binding.Criticality -eq 'required') { $requiredFailures.Add($message) } else { $diagnostics.Add($message + ' Optional binding skipped.') }
            }
        }
    }

    foreach ($integration in @($SessionIntegrations)) {
        if ($null -ne $integration) {
            $integrationEntries.Add($integration)
        }
    }
    foreach ($service in @($SessionServices)) {
        $available = if ($null -ne $service.PSObject.Properties['Available']) { [bool]$service.Available } else { $true }
        $criticality = if ($null -ne $service.PSObject.Properties['Criticality']) { [string]$service.Criticality } else { 'optional' }
        if (-not $available) {
            $message = "SessionService '$($service.Name)' is unavailable."
            if ($criticality -eq 'required') { $requiredFailures.Add($message) } else { $diagnostics.Add($message + ' Optional service skipped.') }
            continue
        }
        $serviceEntries.Add($service)
    }

    $existingPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    $existingModules = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
    $path = @($pathEntries.ToArray() + @($existingPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) -join [System.IO.Path]::PathSeparator
    $modulePath = @($moduleEntries.ToArray() + @($existingModules | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) -join [System.IO.Path]::PathSeparator
    $activeGenerationId = $null
    if ($null -ne $active) {
        $activeGenerationId = [string]$active.Generation.GenerationId
    }
    return [pscustomobject][ordered]@{
        Succeeded = ($requiredFailures.Count -eq 0)
        ActiveGenerationId = $activeGenerationId
        ResolvedPrograms = @($resolvedPrograms.ToArray())
        Environment = [pscustomobject]$environment
        Path = $path
        PSModulePath = $modulePath
        SessionIntegrations = @($integrationEntries.ToArray())
        SessionServices = @($serviceEntries.ToArray())
        RequiredFailures = @($requiredFailures.ToArray())
        Diagnostics = @($diagnostics.ToArray())
    }
}

function Invoke-CapsulenvActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [switch]$Apply
    )

    if (-not $Plan.Succeeded) {
        throw ('Activation failed closed: {0}' -f (@($Plan.RequiredFailures) -join '; '))
    }
    if ($Apply) {
        foreach ($property in @($Plan.Environment.PSObject.Properties)) {
            [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
        }
        [Environment]::SetEnvironmentVariable('PATH', [string]$Plan.Path, 'Process')
        [Environment]::SetEnvironmentVariable('PSModulePath', [string]$Plan.PSModulePath, 'Process')
    }
    return $Plan
}

##MOD_EXEC## Export-ModuleMember -Function New-CapsulenvActivationResource, New-CapsulenvActivationBinding, Resolve-CapsulenvActivation, Invoke-CapsulenvActivation
