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
        [string]$Provenance,
        [string]$AcquisitionProvider
    )

    $currentProvider = $Provider.ToLowerInvariant()
    $originProvider = if ([string]::IsNullOrWhiteSpace($AcquisitionProvider)) {
        $currentProvider
    } else {
        $AcquisitionProvider.ToLowerInvariant()
    }

    return [pscustomobject][ordered]@{
        Name = $Name
        Executable = $Executable
        Root = $Root
        # Provider is the authority that owns the executable currently being
        # selected. AcquisitionProvider records where that immutable payload
        # came from; it must not change the runtime ownership contract.
        Provider = $currentProvider
        AcquisitionProvider = $originProvider
        Scope = $Scope
        Version = $Version
        Capabilities = @($Capabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        Trusted = $Trusted
        OwnsLifecycle = $OwnsLifecycle
        Provenance = if ([string]::IsNullOrWhiteSpace($Provenance)) { $Provider } else { $Provenance }
    }
}

function Get-CapsulenvRealizationAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Manifest)

    $manifestProvider = ([string]$Manifest.Provider).ToLowerInvariant()
    $acquisitionProvider = if ($null -ne $Manifest.PSObject.Properties['AcquisitionProvider'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Manifest.AcquisitionProvider)) {
        ([string]$Manifest.AcquisitionProvider).ToLowerInvariant()
    } else {
        $manifestProvider
    }

    # Schema 1 recorded the acquisition origin in Provider. A materialized
    # seed or provider payload is nevertheless a host-local immutable
    # realization at runtime. Normalize every legacy acquisition-tier value
    # instead of leaking it into the active program authority.
    $currentProvider = $manifestProvider
    if ($manifestProvider -in @('seed', 'provider', 'host-scoop') -and
        ($null -eq $Manifest.PSObject.Properties['AcquisitionProvider'] -or
        [int]$Manifest.SchemaVersion -lt 2)) {
        $currentProvider = 'capsulenv-local'
        $acquisitionProvider = $manifestProvider
    }

    return [pscustomobject][ordered]@{
        Provider = $currentProvider
        AcquisitionProvider = $acquisitionProvider
        Scope = 'host-local'
        OwnsLifecycle = ($currentProvider -eq 'capsulenv-local')
        Provenance = [string]$Manifest.Provenance
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
            PreReleaseIdentifiers = @()
        }
    }
    $normalized = $Version.Trim()
    if ($normalized.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    $withoutBuild = ($normalized -split '\+', 2)[0]
    $versionParts = $withoutBuild -split '-', 2
    $base = [string]$versionParts[0]
    $preReleaseIdentifiers = @()
    if ($versionParts.Count -eq 2) {
        $preRelease = [string]$versionParts[1]
        if ([string]::IsNullOrWhiteSpace($preRelease) -or $preRelease -notmatch '^[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*$') {
            return [pscustomobject][ordered]@{
                Raw = $Version.Trim()
                Identity = $normalized.ToLowerInvariant()
                Valid = $false
                BaseVersion = [version]::new(0, 0, 0, 0)
                PreReleaseIdentifiers = @()
            }
        }
        $preReleaseIdentifiers = @($preRelease.Split('.'))
    }
    if ($base -notmatch '^\d+(?:\.\d+){0,3}$') {
        return [pscustomobject][ordered]@{
            Raw = $Version.Trim()
            Identity = $normalized.ToLowerInvariant()
            Valid = $false
            BaseVersion = [version]::new(0, 0, 0, 0)
            PreReleaseIdentifiers = @()
        }
    }
    try {
        return [pscustomobject][ordered]@{
            Raw = $Version.Trim()
            Identity = $normalized.ToLowerInvariant()
            Valid = $true
            BaseVersion = [version]$base
            PreReleaseIdentifiers = $preReleaseIdentifiers
        }
    } catch {
        return [pscustomobject][ordered]@{
            Raw = $Version.Trim()
            Identity = $normalized.ToLowerInvariant()
            Valid = $false
            BaseVersion = [version]::new(0, 0, 0, 0)
            PreReleaseIdentifiers = @()
        }
    }
}

function Compare-CapsulenvProgramVersionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    $baseComparison = [int]$Left.BaseVersion.CompareTo($Right.BaseVersion)
    if ($baseComparison -ne 0) {
        return $baseComparison
    }

    $leftPreRelease = @($Left.PreReleaseIdentifiers)
    $rightPreRelease = @($Right.PreReleaseIdentifiers)
    if ($leftPreRelease.Count -eq 0 -and $rightPreRelease.Count -eq 0) {
        return 0
    }
    if ($leftPreRelease.Count -eq 0) {
        return 1
    }
    if ($rightPreRelease.Count -eq 0) {
        return -1
    }

    $count = [Math]::Max($leftPreRelease.Count, $rightPreRelease.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $leftPreRelease.Count) {
            return -1
        }
        if ($index -ge $rightPreRelease.Count) {
            return 1
        }

        $leftIdentifier = [string]$leftPreRelease[$index]
        $rightIdentifier = [string]$rightPreRelease[$index]
        if ($leftIdentifier -eq $rightIdentifier) {
            continue
        }

        $leftNumeric = $leftIdentifier -match '^(0|[1-9]\d*)$'
        $rightNumeric = $rightIdentifier -match '^(0|[1-9]\d*)$'
        if ($leftNumeric -and $rightNumeric) {
            if ($leftIdentifier.Length -ne $rightIdentifier.Length) {
                return [Math]::Sign($leftIdentifier.Length - $rightIdentifier.Length)
            }
            return [System.StringComparer]::Ordinal.Compare($leftIdentifier, $rightIdentifier)
        }
        if ($leftNumeric -and -not $rightNumeric) {
            return -1
        }
        if (-not $leftNumeric -and $rightNumeric) {
            return 1
        }
        return [System.StringComparer]::Ordinal.Compare($leftIdentifier, $rightIdentifier)
    }
    return 0
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
        } elseif (
            $candidateVersionInfo.Valid -and
            (Compare-CapsulenvProgramVersionInfo -Left $candidateVersionInfo -Right $minimumInfo) -lt 0
        ) {
            $reasons.Add('below-minimum-version')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.MaximumVersion)) {
        $maximumInfo = Get-CapsulenvProgramVersionInfo -Version ([string]$Requirement.MaximumVersion)
        if (-not $maximumInfo.Valid) {
            $reasons.Add('requirement-version-invalid')
        } elseif (
            $candidateVersionInfo.Valid -and
            (Compare-CapsulenvProgramVersionInfo -Left $candidateVersionInfo -Right $maximumInfo) -gt 0
        ) {
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

function Get-CapsulenvDiscoveredProgramTrustDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Installed,
        [Parameter(Mandatory = $true)][string]$Executable
    )
    $selector = [string]$Installed.Selector
    $policy = 'host-scoop-installed-manifest-v1'
    if ($selector -notmatch ('^(?i:scoop:(?:user|global)/{0})$' -f [regex]::Escape([string]$Requirement.Name))) {
        return [pscustomobject][ordered]@{ Trusted = $false; Policy = $policy; Reason = 'host candidate provenance is not an explicit Scoop user/global selector' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Installed.Current) -or
        -not (Test-Path -LiteralPath ([string]$Installed.Current) -PathType Container) -or
        -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Trusted = $false; Policy = $policy; Reason = 'host candidate does not have a live installed root and executable' }
    }
    try {
        $root = [System.IO.Path]::GetFullPath([string]$Installed.Current).TrimEnd([char[]]'\/')
        $fullExecutable = [System.IO.Path]::GetFullPath($Executable)
        $comparison = if (Test-CapsulenvWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not $fullExecutable.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
            return [pscustomobject][ordered]@{ Trusted = $false; Policy = $policy; Reason = 'host executable is outside the selected installed root' }
        }
        if ([string]::IsNullOrWhiteSpace([string]$Installed.Manifest.version)) {
            return [pscustomobject][ordered]@{ Trusted = $false; Policy = $policy; Reason = 'host manifest has no version provenance' }
        }
        return [pscustomobject][ordered]@{ Trusted = $true; Policy = $policy; Reason = 'explicit Scoop selector, manifest, root containment, and executable presence validated' }
    } catch {
        return [pscustomobject][ordered]@{ Trusted = $false; Policy = $policy; Reason = $_.Exception.Message }
    }
}

function Get-CapsulenvLocalRealizationCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)
    $candidates = New-Object System.Collections.Generic.List[object]
    try {
        $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
        $nameRoot = Join-Path $placement.PackagesRoot ([string]$Requirement.Name)
        if (-not (Test-Path -LiteralPath $nameRoot -PathType Container)) { return @() }
        foreach ($manifestPath in @(Get-ChildItem -LiteralPath $nameRoot -Filter 'realization.json' -File -Recurse)) {
            $root = [System.IO.Path]::GetFullPath($manifestPath.DirectoryName)
            $manifest = Read-CapsulenvRealizationManifest -RealizationRoot $root
            if ($null -eq $manifest -or -not (Test-CapsulenvProgramRealization -RealizationRoot $root -ExpectedName ([string]$Requirement.Name))) { continue }
            $payload = Join-Path $root 'payload'
            $executable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payload -ExecutableRelativePath ([string]$manifest.ExecutableRelativePath)
            $authority = Get-CapsulenvRealizationAuthority -Manifest $manifest
            $candidates.Add((New-CapsulenvProgramCandidate -Name ([string]$manifest.Name) -Executable $executable -Root $root -Provider $authority.Provider -AcquisitionProvider $authority.AcquisitionProvider -Scope $authority.Scope -Version ([string]$manifest.Version) -Trusted:$true -OwnsLifecycle:$authority.OwnsLifecycle -Provenance $authority.Provenance))
        }
    } catch { return @() }
    return @($candidates.ToArray())
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
            $installed = $null
        }
        if ($null -eq $installed) { continue }
        try {
            $executable = Resolve-CapsulenvScoopAppExecutable -App $installed.Selector -RelativePath $Requirement.RelativePath -BinName $Requirement.BinName -ShortcutName $Requirement.ShortcutName
        } catch {
            continue
        }
        $provider = [string]$selector.Provider
        $trust = Get-CapsulenvDiscoveredProgramTrustDecision -Requirement $Requirement -Installed $installed -Executable $executable
        $capabilities = if ([System.StringComparer]::OrdinalIgnoreCase.Equals([string]$Requirement.Name, 'pwsh')) { @('interactive') } else { @() }
        $candidate = New-CapsulenvProgramCandidate -Name $Requirement.Name -Executable $executable -Root $installed.Current -Provider $provider -Scope ([string]$selector.Scope) -Version ([string]$installed.Manifest.version) -Capabilities $capabilities -Trusted:$trust.Trusted -OwnsLifecycle:($provider -eq 'capsulenv-local') -Provenance ([string]$installed.Selector)
        $candidate | Add-Member -NotePropertyName TrustPolicy -NotePropertyValue $trust.Policy -Force
        $candidate | Add-Member -NotePropertyName TrustReason -NotePropertyValue $trust.Reason -Force
        $candidates.Add($candidate)
    }
    if ($null -ne (Get-Command Get-CapsulenvLocalRealizationCandidates -ErrorAction SilentlyContinue)) {
        foreach ($candidate in @(Get-CapsulenvLocalRealizationCandidates -Requirement $Requirement)) {
            $candidates.Add($candidate)
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
