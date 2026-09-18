function New-CapsulenvProgramRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExactVersion,
        [string]$MinimumVersion,
        [string]$MaximumVersion,
        [string[]]$RequiredCapabilities = @(),
        [string[]]$AllowedProviders = @('host-scoop', 'capsulenv-local', 'seed', 'provider'),
        [string]$RelativePath,
        [string]$BinName,
        [string]$ShortcutName
    )

    if ($AllowedProviders.Count -eq 0) {
        throw 'Program requirements must allow at least one provider.'
    }
    return [pscustomobject][ordered]@{
        Name = $Name
        ExactVersion = $ExactVersion
        MinimumVersion = $MinimumVersion
        MaximumVersion = $MaximumVersion
        RequiredCapabilities = @($RequiredCapabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        AllowedProviders = @($AllowedProviders | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        RelativePath = $RelativePath
        BinName = $BinName
        ShortcutName = $ShortcutName
    }
}

function New-CapsulenvProgramCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [ValidateSet('host-scoop', 'capsulenv-local', 'seed', 'provider')]
        [string]$Provider,
        [string]$Scope,
        [string]$Version,
        [string[]]$Capabilities = @(),
        [bool]$Trusted = $true,
        [bool]$OwnsLifecycle = $false,
        [string]$Provenance
    )

    return [pscustomobject][ordered]@{
        Name = $Name
        Executable = $Executable
        Root = $Root
        Provider = $Provider.ToLowerInvariant()
        Scope = $Scope
        Version = $Version
        Capabilities = @($Capabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        Trusted = $Trusted
        OwnsLifecycle = $OwnsLifecycle
        Provenance = if ([string]::IsNullOrWhiteSpace($Provenance)) { $Provider } else { $Provenance }
    }
}

function Get-CapsulenvProgramVersionInfo {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return [pscustomobject][ordered]@{
            Raw = ''
            Identity = ''
            Valid = $false
            BaseVersion = [version]::new(0, 0, 0, 0)
        }
    }
    $normalized = $Version.Trim()
    if ($normalized.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    $base = ($normalized -split '[-+]')[0]
    if ($base -notmatch '^\d+(?:\.\d+){0,3}$') {
        return [pscustomobject][ordered]@{
            Raw = $Version.Trim()
            Identity = $normalized.ToLowerInvariant()
            Valid = $false
            BaseVersion = [version]::new(0, 0, 0, 0)
        }
    }
    try {
        return [pscustomobject][ordered]@{
            Raw = $Version.Trim()
            Identity = $normalized.ToLowerInvariant()
            Valid = $true
            BaseVersion = [version]$base
        }
    } catch {
        return [pscustomobject][ordered]@{
            Raw = $Version.Trim()
            Identity = $normalized.ToLowerInvariant()
            Valid = $false
            BaseVersion = [version]::new(0, 0, 0, 0)
        }
    }
}

function ConvertTo-CapsulenvProgramVersion {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Version)

    return (Get-CapsulenvProgramVersionInfo -Version $Version).BaseVersion
}

function Test-CapsulenvProgramCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Candidate
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $name = [string]$Requirement.Name
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($name, [string]$Candidate.Name)) {
        $reasons.Add('name-mismatch')
    }
    $provider = [string]$Candidate.Provider
    $allowedProviders = @($Requirement.AllowedProviders | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ([string]::IsNullOrWhiteSpace($provider) -or $allowedProviders -notcontains $provider.ToLowerInvariant()) {
        $reasons.Add('provider-not-allowed')
    }
    if (-not [bool]$Candidate.Trusted) {
        $reasons.Add('provider-not-trusted')
    }
    if ([string]::IsNullOrWhiteSpace([string]$Candidate.Executable) -or
        -not (Test-Path -LiteralPath ([string]$Candidate.Executable) -PathType Leaf)) {
        $reasons.Add('executable-missing')
    }

    $candidateVersionInfo = Get-CapsulenvProgramVersionInfo -Version ([string]$Candidate.Version)
    $hasVersionPolicy = (
        -not [string]::IsNullOrWhiteSpace([string]$Requirement.ExactVersion) -or
        -not [string]::IsNullOrWhiteSpace([string]$Requirement.MinimumVersion) -or
        -not [string]::IsNullOrWhiteSpace([string]$Requirement.MaximumVersion)
    )
    if ($hasVersionPolicy -and -not $candidateVersionInfo.Valid) {
        $reasons.Add('version-invalid')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.ExactVersion)) {
        $requiredExactInfo = Get-CapsulenvProgramVersionInfo -Version ([string]$Requirement.ExactVersion)
        if (-not $requiredExactInfo.Valid) {
            $reasons.Add('requirement-version-invalid')
        } elseif ($candidateVersionInfo.Identity -ne $requiredExactInfo.Identity) {
            $reasons.Add('version-not-exact')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.MinimumVersion)) {
        $minimumInfo = Get-CapsulenvProgramVersionInfo -Version ([string]$Requirement.MinimumVersion)
        if (-not $minimumInfo.Valid) {
            $reasons.Add('requirement-version-invalid')
        } elseif ($candidateVersionInfo.Valid -and $candidateVersionInfo.BaseVersion -lt $minimumInfo.BaseVersion) {
            $reasons.Add('below-minimum-version')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.MaximumVersion)) {
        $maximumInfo = Get-CapsulenvProgramVersionInfo -Version ([string]$Requirement.MaximumVersion)
        if (-not $maximumInfo.Valid) {
            $reasons.Add('requirement-version-invalid')
        } elseif ($candidateVersionInfo.Valid -and $candidateVersionInfo.BaseVersion -gt $maximumInfo.BaseVersion) {
            $reasons.Add('above-maximum-version')
        }
    }

    $capabilities = @($Candidate.Capabilities | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($required in @($Requirement.RequiredCapabilities)) {
        if ($capabilities -notcontains ([string]$required).ToLowerInvariant()) {
            $reasons.Add('missing-capability:{0}' -f $required)
        }
    }
    return [pscustomobject][ordered]@{
        Compatible = ($reasons.Count -eq 0)
        Reasons = @($reasons.ToArray())
        Candidate = $Candidate
    }
}

function Resolve-CapsulenvProgram {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$Candidates = @()
    )

    $evaluated = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $check = Test-CapsulenvProgramCandidate -Requirement $Requirement -Candidate $candidate
        $evaluated.Add([pscustomobject][ordered]@{
            Candidate = $candidate
            Compatible = [bool]$check.Compatible
            Reasons = @($check.Reasons)
        })
    }
    $providerRank = @{
        'host-scoop' = 0
        'capsulenv-local' = 1
        'seed' = 2
        'provider' = 3
    }
    $selected = @($evaluated | Where-Object { $_.Compatible } | Sort-Object @{ Expression = { if ($providerRank.ContainsKey([string]$_.Candidate.Provider)) { $providerRank[[string]$_.Candidate.Provider] } else { 99 } } ; Ascending = $true }, @{ Expression = { ConvertTo-CapsulenvProgramVersion -Version ([string]$_.Candidate.Version) } ; Descending = $true }, @{ Expression = { [string]$_.Candidate.Executable } ; Ascending = $true } | Select-Object -First 1)
    $selectedCandidate = $null
    $diagnostics = @('no compatible trusted program realization was found')
    if ($selected.Count -eq 1) {
        $selectedCandidate = $selected[0].Candidate
        $diagnostics = @('selected provider {0} from trusted resolution order' -f $selectedCandidate.Provider)
    }
    $candidateResults = [object[]]$evaluated.ToArray()
    $resolution = New-Object PSObject
    Add-Member -InputObject $resolution -MemberType NoteProperty -Name Requirement -Value $Requirement
    Add-Member -InputObject $resolution -MemberType NoteProperty -Name Succeeded -Value ($null -ne $selectedCandidate)
    Add-Member -InputObject $resolution -MemberType NoteProperty -Name Selected -Value $selectedCandidate
    Add-Member -InputObject $resolution -MemberType NoteProperty -Name Candidates -Value $candidateResults
    Add-Member -InputObject $resolution -MemberType NoteProperty -Name Diagnostics -Value $diagnostics
    return $resolution
}

function Get-CapsulenvProgramCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    $selectors = @(
        [pscustomobject]@{ Selector = 'scoop:user/{0}' -f $Requirement.Name; Provider = 'host-scoop'; Scope = 'user' },
        [pscustomobject]@{ Selector = 'scoop:global/{0}' -f $Requirement.Name; Provider = 'host-scoop'; Scope = 'global' }
    )
    foreach ($selector in $selectors) {
        try {
            $installed = Get-CapsulenvInstalledApp -Selector $selector.Selector -AllowMissing
        } catch {
            # A partially materialized Scoop app is not a usable candidate.
            # Discovery must fail closed for that selector and continue with
            # other providers or the active capsule-local generation.
            continue
        }
        if ($null -eq $installed) { continue }
        try {
            $executable = Resolve-CapsulenvScoopAppExecutable -App $installed.Selector -RelativePath $Requirement.RelativePath -BinName $Requirement.BinName -ShortcutName $Requirement.ShortcutName
        } catch {
            continue
        }
        $provider = [string]$selector.Provider
        $candidates.Add((New-CapsulenvProgramCandidate -Name $Requirement.Name -Executable $executable -Root $installed.Current -Provider $provider -Scope ([string]$selector.Scope) -Version ([string]$installed.Manifest.version) -Trusted:$true -OwnsLifecycle:($provider -eq 'capsulenv-local') -Provenance ([string]$installed.Selector)))
    }
    $active = Get-CapsulenvActiveGeneration
    if ($null -ne $active) {
        foreach ($selection in @($active.Generation.Selections)) {
            if ([string]$selection.Kind -ne 'realization' -and -not [string]::IsNullOrWhiteSpace([string]$selection.Kind)) {
                continue
            }
            if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$selection.Name, [string]$Requirement.Name)) {
                continue
            }
            $realizationRoot = [string]$selection.RealizationRoot
            if (-not (Test-CapsulenvProgramRealization -RealizationRoot $realizationRoot -ExpectedName ([string]$selection.Name) -ExpectedHash ([string]$selection.SourceHash))) {
                continue
            }
            $manifest = Read-CapsulenvRealizationManifest -RealizationRoot $realizationRoot
            if ($null -eq $manifest) { continue }
            $relative = ([string]$manifest.ExecutableRelativePath).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $executable = Join-Path (Join-Path $realizationRoot 'payload') $relative
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { continue }
            $candidates.Add((New-CapsulenvProgramCandidate -Name ([string]$manifest.Name) -Executable $executable -Root $realizationRoot -Provider 'capsulenv-local' -Scope 'host-local' -Version ([string]$manifest.Version) -Trusted:$true -OwnsLifecycle:$true -Provenance ([string]$manifest.Provenance)))
        }
    }
    return @($candidates.ToArray())
}

function Get-CapsulenvProgramResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$Candidates
    )

    $available = if ($PSBoundParameters.ContainsKey('Candidates')) {
        @($Candidates)
    } else {
        @(Get-CapsulenvProgramCandidates -Requirement $Requirement)
    }
    return Resolve-CapsulenvProgram -Requirement $Requirement -Candidates $available
}

function Invoke-CapsulenvResolveCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $unknown = @($Arguments | Where-Object { $_ -like '--*' -and $_ -ne '--json' })
    $positionals = @($Arguments | Where-Object { $_ -notlike '--*' })
    if ($unknown.Count -gt 0 -or $positionals.Count -ne 1) {
        throw 'Usage: resolve <app> [--json]'
    }
    $requirement = New-CapsulenvProgramRequirement -Name ([string]$positionals[0])
    $resolution = Get-CapsulenvProgramResolution -Requirement $requirement
    if ($Arguments -contains '--json') {
        $resolution | ConvertTo-Json -Depth 8 | Write-Output
    } else {
        $resolution | Format-List
    }
    if ($resolution.Succeeded) {
        return $resolution.Selected.Executable
    }
}

##MOD_EXEC## Export-ModuleMember -Function New-CapsulenvProgramRequirement, New-CapsulenvProgramCandidate, Test-CapsulenvProgramCandidate, Resolve-CapsulenvProgram, Get-CapsulenvProgramCandidates, Get-CapsulenvProgramResolution
