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

    if ($Reference -match '^(?i:(user|global))/') {
        $installed = Get-CapsulenvInstalledScoopApp -Selector $Reference
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

function Get-CapsulenvPackageReviewPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $request = Resolve-CapsulenvPackageReviewRequest -Reference $Reference
    $plan = Get-CapsulenvPackageInstallPlan -Reference ([string]$request.PlanReference)
    $normalizedReference = [string]$plan.Reference
    $operation = [string]$request.Operation
    $packages = @(
        foreach ($package in @($plan.Packages)) {
            $isRequestedUpstreamUpdate = (
                $operation -eq 'Update' -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$package.Reference, $normalizedReference)
            )
            if ([string]$package.Classification -eq 'PortableSafe' -and -not $isRequestedUpstreamUpdate) { continue }
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

    $reviewRequired = ($operation -eq 'Update' -or [string]$plan.Classification -ne 'PortableSafe')
    $nextCommand = if ($operation -eq 'Update') {
        "capsulenv app update $([string]$request.InstalledSelector) --allow-trusted"
    } elseif ($reviewRequired) {
        "capsulenv app install $normalizedReference --allow-trusted"
    } else {
        "capsulenv app install $normalizedReference"
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        RequestReference = [string]$request.RequestReference
        Reference = $normalizedReference
        Operation = $operation
        InstalledSelector = [string]$request.InstalledSelector
        Classification = [string]$plan.Classification
        ExecutionBoundary = if ($reviewRequired) { 'TrustedExecution' } else { 'PortableSafe' }
        ReviewRequired = $reviewRequired
        Packages = $packages
        Checklist = @(Get-CapsulenvPackageReviewChecklist)
        RecommendedAction = if ($reviewRequired) {
            "After reviewing every listed manifest/effect, run '$nextCommand' only if upstream Scoop lifecycle execution is acceptable."
        } else {
            if ($operation -eq 'Update') {
                "The current source manifest fits PortableSafe, but '$([string]$request.InstalledSelector)' remains upstream Scoop-owned; its update still uses upstream semantics. Review ownership before running '$nextCommand'."
            } else {
                "No TrustedExecution review is required; install with '$nextCommand'."
            }
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
        foreach ($package in @($Review.Packages)) {
            Write-Host ("=== {0} :: {1} ===" -f [string]$package.Reference, [string]$package.ManifestPath) -ForegroundColor Cyan
            Get-Content -LiteralPath ([string]$package.ManifestPath) -Raw | Write-Output
        }
        if (@($Review.Packages).Count -eq 0) {
            Write-CapsulenvMessage -Level Info -Message "'$($Review.Reference)' is fully PortableSafe; there is no trusted manifest surface to review."
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
    Write-Host ("  To inspect the exact source manifests: capsulenv app review {0} --raw" -f [string]$Review.RequestReference) -ForegroundColor DarkGray
}
