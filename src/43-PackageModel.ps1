function Get-CapsulenvPackageRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.Packages.Root) -AllowMissing
}

function Get-CapsulenvPackageShimRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.Packages.Shims) -AllowMissing
}

function Get-CapsulenvPackagePersistRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.Packages.Persist) -AllowMissing
}

function Get-CapsulenvPackageCacheRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.Packages.Cache) -AllowMissing
}

function Get-CapsulenvPackageStateRoot {
    [CmdletBinding()]
    param()

    return Join-Path (Get-CapsulenvContext).StateRoot 'packages'
}

function Get-CapsulenvPackageArchitecture {
    [CmdletBinding()]
    param()

    switch -Regex ([string]$env:PROCESSOR_ARCHITECTURE) {
        '^(?i:ARM64)$' { return 'arm64' }
        '^(?i:x86)$' { return '32bit' }
        default { return '64bit' }
    }
}

function Test-CapsulenvPortableFileNameComponent {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Value,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [bool]$AllowEmpty
    }
    if (
        $Value -in @('.', '..') -or
        $Value -match '[\\/:*?"<>|]' -or
        $Value -match '[\x00-\x1f]' -or
        $Value.EndsWith('.') -or
        $Value.EndsWith(' ')
    ) {
        return $false
    }
    $baseName = @($Value -split '\.', 2)[0]
    if ($baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        return $false
    }
    return $true
}

function Test-CapsulenvEnvironmentVariableName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    if ($Value.Contains('=') -or $Value -match '[\x00-\x1f]') {
        return $false
    }
    return $true
}

function Split-CapsulenvPackageReference {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw 'Package reference must not be empty.'
    }

    $bucket = $null
    $name = $Reference
    $separator = $Reference.IndexOf('/')
    if ($separator -ge 0) {
        if ($separator -eq 0 -or $separator -eq ($Reference.Length - 1) -or $Reference.IndexOf('/', $separator + 1) -ge 0) {
            throw "Invalid package reference '$Reference'. Use <app> or <bucket>/<app>."
        }
        $bucket = $Reference.Substring(0, $separator)
        $name = $Reference.Substring($separator + 1)
    }

    foreach ($part in @($bucket, $name)) {
        if ([string]::IsNullOrWhiteSpace([string]$part)) {
            continue
        }
        if (-not (Test-CapsulenvPortableFileNameComponent -Value ([string]$part))) {
            throw "Invalid package reference component '$part'."
        }
    }

    return [pscustomobject]@{
        Bucket = $bucket
        Name = $name
        Reference = if ($bucket) { "$bucket/$name" } else { $name }
    }
}

function Get-CapsulenvPackageManifestPropertyRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Architecture
    )

    $exists = $false
    $value = $null
    $baseProperty = Get-CapsulenvJsonPropertyRecord -Object $Manifest -Name $Name
    if ($null -ne $baseProperty) {
        $exists = $true
        $value = $baseProperty.Value
    }

    $architectureMap = Get-CapsulenvJsonPropertyRecord -Object $Manifest -Name 'architecture'
    if ($null -ne $architectureMap) {
        $architectureManifest = Get-CapsulenvJsonPropertyRecord -Object $architectureMap.Value -Name $Architecture
        if ($null -ne $architectureManifest) {
            $architectureProperty = Get-CapsulenvJsonPropertyRecord -Object $architectureManifest.Value -Name $Name
            if ($null -ne $architectureProperty) {
                $exists = $true
                $value = $architectureProperty.Value
            }
        }
    }

    return [pscustomobject]@{
        Exists = $exists
        Value = $value
    }
}

function ConvertTo-CapsulenvPackageValueArray {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) {
        return [pscustomobject]@{ Items = @() }
    }
    if ($Value -is [string]) {
        return [pscustomobject]@{ Items = @([string]$Value) }
    }
    return [pscustomobject]@{ Items = @($Value) }
}

function Test-CapsulenvPackageRelativePath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Path,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [bool]$AllowEmpty
    }
    if (
        [System.IO.Path]::IsPathRooted($Path) -or
        $Path -match '^[\\/]' -or
        $Path -match '^[A-Za-z]:'
    ) {
        return $false
    }
    foreach ($segment in @($Path -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.') {
            continue
        }
        if ($segment -eq '..' -or -not (Test-CapsulenvPortableFileNameComponent -Value $segment)) {
            return $false
        }
    }
    return $true
}

function Get-CapsulenvPackagePathLeaf {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $segments = @($Path -split '[\\/]')
    if ($segments.Count -eq 0) { return '' }
    return [string]$segments[-1]
}

function Get-CapsulenvPackageUrlDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Url)

    $source = $Url
    $fileName = $null
    $fragmentIndex = $source.IndexOf('#/')
    if ($fragmentIndex -ge 0) {
        $fileName = $source.Substring($fragmentIndex + 2)
        $source = $source.Substring(0, $fragmentIndex)
    }

    $uri = $null
    try {
        $uri = [Uri]$source
    } catch {
        throw "Package URL is invalid: $Url"
    }
    if ($uri.Scheme -notin @('http', 'https', 'file')) {
        throw "Package URL uses an unsupported scheme '$($uri.Scheme)': $Url"
    }

    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    }
    if (
        [string]::IsNullOrWhiteSpace($fileName) -or
        [System.IO.Path]::IsPathRooted($fileName) -or
        -not (Test-CapsulenvPortableFileNameComponent -Value $fileName)
    ) {
        throw "Package URL does not resolve to a safe local filename: $Url"
    }

    $lowerName = $fileName.ToLowerInvariant()
    $archiveKind = if ($lowerName.EndsWith('.zip')) {
        'Zip'
    } elseif (
        $lowerName.EndsWith('.7z') -or
        $lowerName.EndsWith('.tar') -or
        $lowerName.EndsWith('.tar.gz') -or
        $lowerName.EndsWith('.tgz') -or
        $lowerName.EndsWith('.tar.xz') -or
        $lowerName.EndsWith('.tar.bz2') -or
        $lowerName.EndsWith('.gz') -or
        $lowerName.EndsWith('.bz2') -or
        $lowerName.EndsWith('.xz') -or
        $lowerName.EndsWith('.msi')
    ) {
        'UnsupportedArchive'
    } else {
        'File'
    }

    return [pscustomobject]@{
        Url = $source
        OriginalUrl = $Url
        FileName = $fileName
        ArchiveKind = $archiveKind
    }
}

function Get-CapsulenvPackageHashDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Hash)

    $value = $Hash.Trim()
    if ($value -match '^(?i:sha256):([0-9a-fA-F]{64})$') {
        return [pscustomobject]@{ Algorithm = 'SHA256'; Hex = $Matches[1].ToLowerInvariant() }
    }
    if ($value -match '^[0-9a-fA-F]{64}$') {
        return [pscustomobject]@{ Algorithm = 'SHA256'; Hex = $value.ToLowerInvariant() }
    }
    return $null
}

function Resolve-CapsulenvPackageManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $parsed = Split-CapsulenvPackageReference -Reference $Reference
    $bucketsRoot = Join-Path (Get-CapsulenvScoopRoot) 'buckets'
    if (-not (Test-Path -LiteralPath $bucketsRoot -PathType Container)) {
        throw 'No Scoop buckets are available. Run capsulenv bootstrap or update the stock Scoop buckets first.'
    }

    $bucketNames = New-Object System.Collections.Generic.List[string]
    if ($parsed.Bucket) {
        $bucketNames.Add([string]$parsed.Bucket)
    } else {
        if (Test-Path -LiteralPath (Join-Path $bucketsRoot 'main') -PathType Container) {
            $bucketNames.Add('main')
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $bucketsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if (-not ($bucketNames -contains $directory.Name)) {
                $bucketNames.Add($directory.Name)
            }
        }
    }

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($bucketName in $bucketNames.ToArray()) {
        $path = Join-Path (Join-Path (Join-Path $bucketsRoot $bucketName) 'bucket') ($parsed.Name + '.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        try {
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        } catch {
            throw "Failed to parse Scoop manifest '$path': $($_.Exception.Message)"
        }
        $matches.Add([pscustomobject]@{
            Name = [string]$parsed.Name
            Bucket = [string]$bucketName
            Reference = ('{0}/{1}' -f $bucketName, $parsed.Name)
            Path = [System.IO.Path]::GetFullPath($path)
            Manifest = $manifest
        })
        if ($parsed.Bucket -or $bucketName -eq 'main') {
            break
        }
    }

    if ($matches.Count -eq 0) {
        throw "Scoop manifest was not found in the capsule buckets: $Reference"
    }
    if (-not $parsed.Bucket -and $matches.Count -gt 1) {
        $bucketList = @($matches | ForEach-Object { [string]$_.Bucket }) -join ', '
        throw "Package '$($parsed.Name)' exists in multiple non-main buckets. Use <bucket>/$($parsed.Name). Matches: $bucketList"
    }
    return $matches[0]
}

function Get-CapsulenvPackageManifestPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [ValidateSet('64bit', '32bit', 'arm64')]
        [string]$Architecture = (Get-CapsulenvPackageArchitecture)
    )

    $resolved = Resolve-CapsulenvPackageManifest -Reference $Reference
    $manifest = $resolved.Manifest
    $versionProperty = Get-CapsulenvJsonPropertyRecord -Object $manifest -Name 'version'
    if ($null -eq $versionProperty -or [string]::IsNullOrWhiteSpace([string]$versionProperty.Value)) {
        throw "Scoop manifest has no version: $($resolved.Path)"
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    $version = [string]$versionProperty.Value
    if (-not (Test-CapsulenvPortableFileNameComponent -Value $version)) {
        $reasons.Add("version cannot be represented as a portable package directory: $version")
    }
    $capabilities = New-Object System.Collections.Generic.List[string]
    $trustedScript = $false
    $externalInstaller = $false

    # Scoop's root schema is intentionally closed. Mirror that boundary here so
    # a newly introduced install-affecting manifest property cannot silently be
    # ignored and still acquire PortableSafe classification. Metadata-only
    # fields remain accepted even though Capsulenv does not execute them.
    $knownRootProperties = @(
        '$schema', '_comment', '##', 'architecture', 'autoupdate', 'bin',
        'persist', 'checkver', 'cookie', 'depends', 'description',
        'env_add_path', 'env_set', 'extract_dir', 'extract_to', 'hash',
        'homepage', 'innosetup', 'installer', 'license', 'notes',
        'post_install', 'post_uninstall', 'pre_install', 'pre_uninstall',
        'psmodule', 'shortcuts', 'suggest', 'uninstaller', 'url', 'version'
    )
    foreach ($property in @($manifest.PSObject.Properties)) {
        if ($knownRootProperties -notcontains [string]$property.Name) {
            $reasons.Add("Unsupported Scoop manifest property: $($property.Name)")
        }
    }

    $architectureMapRecord = Get-CapsulenvJsonPropertyRecord -Object $manifest -Name 'architecture'
    if ($null -ne $architectureMapRecord -and $null -ne $architectureMapRecord.Value) {
        foreach ($architectureProperty in @($architectureMapRecord.Value.PSObject.Properties)) {
            if ([string]$architectureProperty.Name -notin @('32bit', '64bit', 'arm64')) {
                $reasons.Add("Unsupported Scoop architecture key: $($architectureProperty.Name)")
            }
        }
        $selectedArchitectureRecord = Get-CapsulenvJsonPropertyRecord -Object $architectureMapRecord.Value -Name $Architecture
        if ($null -ne $selectedArchitectureRecord -and $null -ne $selectedArchitectureRecord.Value) {
            $knownArchitectureProperties = @(
                'bin', 'checkver', 'env_add_path', 'env_set', 'extract_dir',
                'hash', 'installer', 'post_install', 'post_uninstall',
                'pre_install', 'pre_uninstall', 'shortcuts', 'uninstaller', 'url'
            )
            foreach ($property in @($selectedArchitectureRecord.Value.PSObject.Properties)) {
                if ($knownArchitectureProperties -notcontains [string]$property.Name) {
                    $reasons.Add("Unsupported Scoop architecture manifest property: $($property.Name)")
                }
            }
        }
    }

    foreach ($unsupportedPropertyName in @('cookie', 'psmodule')) {
        $unsupportedProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name $unsupportedPropertyName -Architecture $Architecture
        if ($unsupportedProperty.Exists -and $null -ne $unsupportedProperty.Value) {
            $reasons.Add("PortableSafe does not implement Scoop '$unsupportedPropertyName' semantics")
        }
    }
    $innoSetupProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'innosetup' -Architecture $Architecture
    if ($innoSetupProperty.Exists -and [bool]$innoSetupProperty.Value) {
        $externalInstaller = $true
        $reasons.Add('innosetup requires external installer extraction semantics')
    }

    foreach ($hookName in @('pre_install', 'post_install', 'pre_uninstall', 'post_uninstall')) {
        $hook = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name $hookName -Architecture $Architecture
        if ($hook.Exists -and $null -ne $hook.Value -and @($hook.Value).Count -gt 0) {
            $trustedScript = $true
            $reasons.Add("$hookName requires arbitrary lifecycle execution")
        }
    }
    foreach ($installerName in @('installer', 'uninstaller')) {
        $installer = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name $installerName -Architecture $Architecture
        if (-not $installer.Exists -or $null -eq $installer.Value) {
            continue
        }
        $scriptProperty = Get-CapsulenvJsonPropertyRecord -Object $installer.Value -Name 'script'
        if ($null -ne $scriptProperty -and $null -ne $scriptProperty.Value -and @($scriptProperty.Value).Count -gt 0) {
            $trustedScript = $true
            $reasons.Add("$installerName.script requires arbitrary lifecycle execution")
        } else {
            $externalInstaller = $true
            $reasons.Add("$installerName requires an external installer lifecycle")
        }
    }

    $urlProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'url' -Architecture $Architecture
    $hashProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'hash' -Architecture $Architecture
    $urlValues = @(if ($urlProperty.Exists) { (ConvertTo-CapsulenvPackageValueArray -Value $urlProperty.Value).Items } else { @() })
    $hashValues = @(if ($hashProperty.Exists) { (ConvertTo-CapsulenvPackageValueArray -Value $hashProperty.Value).Items } else { @() })
    if ($urlValues.Count -eq 0) {
        $reasons.Add('url is missing for the selected architecture')
    }
    if ($hashValues.Count -eq 0) {
        $reasons.Add('hash is missing for the selected architecture')
    }
    if ($urlValues.Count -ne $hashValues.Count) {
        $reasons.Add("url/hash item counts differ ($($urlValues.Count) vs $($hashValues.Count))")
    }

    $downloads = New-Object System.Collections.Generic.List[object]
    $downloadCount = [Math]::Min($urlValues.Count, $hashValues.Count)
    for ($index = 0; $index -lt $downloadCount; $index++) {
        try {
            $urlDescriptor = Get-CapsulenvPackageUrlDescriptor -Url ([string]$urlValues[$index])
        } catch {
            $reasons.Add($_.Exception.Message)
            continue
        }
        $hashDescriptor = Get-CapsulenvPackageHashDescriptor -Hash ([string]$hashValues[$index])
        if ($null -eq $hashDescriptor) {
            $reasons.Add("Only SHA-256 hashes are supported by PortableSafe: $($hashValues[$index])")
            continue
        }
        if ($urlDescriptor.ArchiveKind -eq 'UnsupportedArchive') {
            $reasons.Add("PortableSafe extraction does not yet support archive type: $($urlDescriptor.FileName)")
        }
        $downloads.Add([pscustomobject]@{
            Index = $index
            Url = [string]$urlDescriptor.Url
            OriginalUrl = [string]$urlDescriptor.OriginalUrl
            FileName = [string]$urlDescriptor.FileName
            ArchiveKind = [string]$urlDescriptor.ArchiveKind
            HashAlgorithm = [string]$hashDescriptor.Algorithm
            Hash = [string]$hashDescriptor.Hex
        })
    }
    if ($downloads.Count -gt 0) {
        $capabilities.Add('Download')
        $capabilities.Add('VerifyHash')
        if (@($downloads | Where-Object { $_.ArchiveKind -eq 'Zip' }).Count -gt 0) {
            $capabilities.Add('Extract')
        }
    }

    $extractDir = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'extract_dir' -Architecture $Architecture
    $extractTo = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'extract_to' -Architecture $Architecture
    $extractDirValues = @(if ($extractDir.Exists) { (ConvertTo-CapsulenvPackageValueArray -Value $extractDir.Value).Items } else { @() })
    $extractToValues = @(if ($extractTo.Exists) { (ConvertTo-CapsulenvPackageValueArray -Value $extractTo.Value).Items } else { @() })
    foreach ($path in @($extractDirValues)) {
        if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$path))) {
            $reasons.Add("extract_dir escapes the package root: $path")
        }
    }
    foreach ($path in @($extractToValues)) {
        if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$path) -AllowEmpty)) {
            $reasons.Add("extract_to escapes the package root: $path")
        }
    }
    foreach ($shape in @(
        [pscustomobject]@{ Name = 'extract_dir'; Values = $extractDirValues },
        [pscustomobject]@{ Name = 'extract_to'; Values = $extractToValues }
    )) {
        if ($shape.Values.Count -gt 1 -and $shape.Values.Count -ne $urlValues.Count) {
            $reasons.Add("$($shape.Name) must contain one value or match the url count")
        }
    }

    if ($extractDirValues.Count -gt 0) {
        foreach ($download in $downloads.ToArray()) {
            $extractDirValue = if ($extractDirValues.Count -eq 1) {
                [string]$extractDirValues[0]
            } elseif ([int]$download.Index -lt $extractDirValues.Count) {
                [string]$extractDirValues[[int]$download.Index]
            } else {
                ''
            }
            if (-not [string]::IsNullOrWhiteSpace($extractDirValue) -and [string]$download.ArchiveKind -ne 'Zip') {
                $reasons.Add("extract_dir is only implemented for ZIP artifacts in PortableSafe: $($download.FileName)")
            }
        }
    }

    $binProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'bin' -Architecture $Architecture
    $persistProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'persist' -Architecture $Architecture
    $envPathProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'env_add_path' -Architecture $Architecture
    $envSetProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'env_set' -Architecture $Architecture
    $shortcutProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'shortcuts' -Architecture $Architecture
    $dependsProperty = Get-CapsulenvPackageManifestPropertyRecord -Manifest $manifest -Name 'depends' -Architecture $Architecture

    if ($binProperty.Exists -and $null -ne $binProperty.Value) { $capabilities.Add('Shim') }
    if ($persistProperty.Exists -and $null -ne $persistProperty.Value) { $capabilities.Add('Persist') }
    if (
        ($envPathProperty.Exists -and $null -ne $envPathProperty.Value) -or
        ($envSetProperty.Exists -and $null -ne $envSetProperty.Value)
    ) { $capabilities.Add('ProcessEnvironment') }
    if ($shortcutProperty.Exists -and $null -ne $shortcutProperty.Value) { $capabilities.Add('ShortcutDeclaration') }
    if ($dependsProperty.Exists -and $null -ne $dependsProperty.Value) { $capabilities.Add('Dependencies') }

    foreach ($field in @(
        [pscustomobject]@{ Name = 'env_add_path'; Property = $envPathProperty; AllowEmpty = $false }
    )) {
        if (-not $field.Property.Exists -or $null -eq $field.Property.Value) { continue }
        foreach ($path in @((ConvertTo-CapsulenvPackageValueArray -Value $field.Property.Value).Items)) {
            if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$path))) {
                $reasons.Add("$($field.Name) escapes the package root: $path")
            }
        }
    }

    if ($envSetProperty.Exists -and $null -ne $envSetProperty.Value) {
        if ($envSetProperty.Value -is [string] -or $envSetProperty.Value -is [System.Array]) {
            $reasons.Add('env_set must be a JSON object of process environment variables')
        } else {
            foreach ($property in @($envSetProperty.Value.PSObject.Properties)) {
                if (-not (Test-CapsulenvEnvironmentVariableName -Value ([string]$property.Name))) {
                    $reasons.Add("env_set contains an invalid environment variable name: $($property.Name)")
                }
                if ($null -ne $property.Value -and $property.Value -isnot [string] -and $property.Value -is [System.Collections.IEnumerable]) {
                    $reasons.Add("env_set value must be scalar text: $($property.Name)")
                }
            }
        }
    }

    if ($persistProperty.Exists -and $null -ne $persistProperty.Value) {
        $persistItems = @(if ($persistProperty.Value -is [string]) { [string]$persistProperty.Value } else { @($persistProperty.Value) })
        foreach ($item in $persistItems) {
            $parts = @(if ($item -is [string]) { [string]$item } else { @($item) })
            if ($parts.Count -lt 1 -or $parts.Count -gt 2) {
                $reasons.Add('persist entries must be a path or [source, target] tuple')
                continue
            }
            foreach ($part in $parts) {
                if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$part))) {
                    $reasons.Add("persist path escapes the package root: $part")
                }
            }
        }
    }

    if ($binProperty.Exists -and $null -ne $binProperty.Value) {
        $binItems = @(if ($binProperty.Value -is [string]) { [string]$binProperty.Value } else { @($binProperty.Value) })
        foreach ($item in $binItems) {
            $parts = @(if ($item -is [string]) { [string]$item } else { @($item) })
            if ($parts.Count -lt 1 -or $parts.Count -gt 3) {
                $reasons.Add('bin entries must be a path or [path, alias, args] tuple')
                continue
            }
            if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$parts[0])) ) {
                $reasons.Add("bin path escapes the package root: $($parts[0])")
            }
            if ($parts.Count -ge 3 -and -not [string]::IsNullOrWhiteSpace([string]$parts[2])) {
                $reasons.Add('PortableSafe bin fixed arguments are not implemented yet')
            }
            $alias = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
                [string]$parts[1]
            } else {
                [System.IO.Path]::GetFileNameWithoutExtension((Get-CapsulenvPackagePathLeaf -Path ([string]$parts[0])))
            }
            if (
                -not (Test-CapsulenvPortableFileNameComponent -Value $alias) -or
                $alias -in @('capsulenv', 'scoop')
            ) {
                $reasons.Add("bin alias is reserved or invalid for a Capsulenv shim: $alias")
            }
        }
    }

    if ($shortcutProperty.Exists -and $null -ne $shortcutProperty.Value) {
        foreach ($shortcut in @($shortcutProperty.Value)) {
            $parts = @($shortcut)
            if ($parts.Count -lt 2 -or $parts.Count -gt 4) {
                $reasons.Add('shortcut entries must contain target, name, optional arguments and optional custom icon')
                continue
            }
            if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$parts[0]))) {
                $reasons.Add("shortcut target escapes the package root: $($parts[0])")
            }
            $shortcutName = [string]$parts[1]
            if (
                -not (Test-CapsulenvPackageRelativePath -Path $shortcutName) -or
                $shortcutName.EndsWith('\') -or
                $shortcutName.EndsWith('/')
            ) {
                $reasons.Add("shortcut name cannot be represented safely in Capsulenv host integration: $shortcutName")
            }
            if (
                $parts.Count -ge 4 -and
                -not [string]::IsNullOrWhiteSpace([string]$parts[3]) -and
                -not (Test-CapsulenvPackageRelativePath -Path ([string]$parts[3]))
            ) {
                $reasons.Add("shortcut icon escapes the package root: $($parts[3])")
            }
        }
    }

    $dependencies = @()
    if ($dependsProperty.Exists -and $null -ne $dependsProperty.Value) {
        $dependencies = @((ConvertTo-CapsulenvPackageValueArray -Value $dependsProperty.Value).Items | ForEach-Object { [string]$_ })
        foreach ($dependency in $dependencies) {
            try { [void](Split-CapsulenvPackageReference -Reference $dependency) } catch { $reasons.Add($_.Exception.Message) }
        }
    }

    $classification = if ($trustedScript) {
        'TrustedScript'
    } elseif ($externalInstaller) {
        'ExternalInstaller'
    } elseif ($reasons.Count -gt 0) {
        'Unsupported'
    } else {
        'PortableSafe'
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        Name = [string]$resolved.Name
        Version = $version
        Bucket = [string]$resolved.Bucket
        Reference = [string]$resolved.Reference
        ManifestPath = [string]$resolved.Path
        Architecture = $Architecture
        Classification = $classification
        Capabilities = @($capabilities | Sort-Object -Unique)
        Reasons = $reasons.ToArray()
        Dependencies = @($dependencies)
        Downloads = $downloads.ToArray()
        ExtractDir = @($extractDirValues)
        ExtractTo = @($extractToValues)
        Bin = if ($binProperty.Exists) { $binProperty.Value } else { $null }
        Persist = if ($persistProperty.Exists) { $persistProperty.Value } else { $null }
        EnvAddPath = if ($envPathProperty.Exists) { $envPathProperty.Value } else { $null }
        EnvSet = if ($envSetProperty.Exists) { $envSetProperty.Value } else { $null }
        Shortcuts = if ($shortcutProperty.Exists) { $shortcutProperty.Value } else { $null }
        SourceManifest = $manifest
    }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvPackageManifestPlan
