function Get-CapsulenvLegacyScoopShimRepairPlan {
    [CmdletBinding()]
    param()

    $entries = New-Object System.Collections.Generic.List[object]
    $previousRoots = @{}
    foreach ($relocation in @(
        (Get-CapsulenvRelocationContext)
        $(try { Get-CapsulenvLastRelocationContext } catch { $null })
    )) {
        if ($null -eq $relocation) { continue }
        foreach ($mapping in @($relocation.PathMappings)) {
            if ($mapping.Name -notin @('ScoopRoot','ScoopGlobalRoot')) { continue }
            $newRoot = [string]$mapping.NewPath
            if (-not $previousRoots.ContainsKey($newRoot)) { $previousRoots[$newRoot] = @() }
            $previousRoots[$newRoot] += [string]$mapping.OldPath
        }
    }

    foreach ($scope in @('User','Global')) {
        $scoopRoot = if ($scope -eq 'User') { Get-CapsulenvScoopRoot } else { Get-CapsulenvScoopGlobalRoot }
        $capsuleRoot = (Get-CapsulenvContext).Root
        if (-not (Test-CapsulenvPathNested -Parent $capsuleRoot -Child $scoopRoot)) { continue }
        $scoopItem = Get-Item -LiteralPath $scoopRoot -Force -ErrorAction SilentlyContinue
        if ($null -eq $scoopItem -or ($scoopItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
        # Only the capsule's configured Scoop roots are eligible, never discovered host Scoop.
        $shimsRoot = Join-Path $scoopRoot 'shims'
        if (-not (Test-Path -LiteralPath $shimsRoot -PathType Container)) { continue }
        $shimsItem = Get-Item -LiteralPath $shimsRoot -Force
        if ($shimsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $oldRoots = @($previousRoots[$scoopRoot] | Where-Object { $_ })
        $expected = @{}
        foreach ($app in @(Get-CapsulenvInstalledScoopApps | Where-Object { $_.ProviderScope -eq $scope -and $_.Ready })) {
            try {
                # Validate the installed version before trusting any bin alias.
                $location = Get-CapsulenvLegacyScoopLocation -Selector $app.Selector
                [void](Resolve-CapsulenvLegacyScoopVersionRoot -Location $location)
                foreach ($bin in @(Get-CapsulenvScoopAppBins -App $app.Selector)) {
                    $alias = [string]$bin.Name
                    $target = [string]$bin.Target
                    if ($alias -notmatch '^[a-zA-Z0-9_.-]+$' -or
                        -not (Test-CapsulenvPathNested -Parent (Join-Path $scoopRoot 'apps') -Child $target)) {
                        continue
                    }
                    $expected[$alias.ToLowerInvariant()] = [pscustomobject]@{
                        Target=$target; App=[string]$app.Name
                    }
                }
            } catch {
                # A missing/ambiguous installed manifest is not authority to change its shims.
                continue
            }
        }

        foreach ($shim in @(Get-ChildItem -LiteralPath $shimsRoot -File -Filter '*.shim' -ErrorAction SilentlyContinue)) {
            if ($shim.Length -gt 65536 -or ($shim.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
            $alias = [System.IO.Path]::GetFileNameWithoutExtension($shim.Name).ToLowerInvariant()
            if (-not $expected.ContainsKey($alias)) { continue }
            $declared = $expected[$alias]
            $content = [System.IO.File]::ReadAllText($shim.FullName)
            $matches = @([regex]::Matches($content, '(?m)^path\s*=\s*"(?<target>[^"\r\n]+)"\s*$'))
            if ($matches.Count -ne 1) {
                $entries.Add([pscustomobject]@{ Path=$shim.FullName; App=$declared.App; Status='Conflict'; Target=''; Replacement=''; Detail='Shim path declaration is ambiguous.' })
                continue
            }
            $target = [string]$matches[0].Groups['target'].Value
            $replacement = [string]$declared.Target
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($target, $replacement)) {
                continue
            }
            $verified = $false
            foreach ($oldRoot in $oldRoots) {
                $oldPrefix = [System.IO.Path]::GetFullPath($oldRoot).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
                $newPrefix = [System.IO.Path]::GetFullPath($scoopRoot).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
                if ($replacement.StartsWith($newPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $oldTarget = $oldPrefix + $replacement.Substring($newPrefix.Length)
                    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($target, $oldTarget)) {
                        $verified = $true
                        break
                    }
                }
            }
            $entries.Add([pscustomobject]@{
                Path=$shim.FullName; App=$declared.App
                Status=if($verified){'Repairable'}else{'Conflict'}
                Target=$target; Replacement=$replacement
                Detail=if($verified){'Verified prior capsule Scoop root and installed bin declaration.'}else{'Shim target does not match a verified previous capsule root.'}
            })
        }
    }
    return $entries.ToArray()
}

function Repair-CapsulenvLegacyScoopShims {
    [CmdletBinding()]
    param()

    $plan = @(Get-CapsulenvLegacyScoopShimRepairPlan)
    $repaired = 0
    foreach ($item in @($plan | Where-Object Status -eq 'Repairable')) {
        $path = [string]$item.Path
        # Revalidate on write. A stale inventory cannot authorize changing a new shim.
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
        $encoding = New-Object System.Text.UTF8Encoding($hasBom, $true)
        $content = [System.IO.File]::ReadAllText($path, $encoding)
        $escaped = [regex]::Escape([string]$item.Target)
        $match = [regex]::Match($content, ('(?m)^(path\s*=\s*")' + $escaped + '("\s*)$'))
        if (-not $match.Success) { continue }
        $updated = $content.Substring(0,$match.Groups[1].Index + $match.Groups[1].Length) +
            [string]$item.Replacement + $content.Substring($match.Groups[2].Index)
        $backupRoot = Join-Path (Get-CapsulenvContext).StateRoot 'scoop-shim-backups'
        [void](New-Item -ItemType Directory -Path $backupRoot -Force)
        $token = [guid]::NewGuid().ToString('N')
        $backup = Join-Path $backupRoot ($token + '.shim')
        $temporary = Join-Path (Split-Path -Parent $path) ('.capsulenv-' + $token + '.tmp')
        try {
            [System.IO.File]::WriteAllText($temporary, $updated, $encoding)
            [System.IO.File]::Replace($temporary, $path, $backup)
            $repaired++
        } finally {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    # A vanished or concurrently replaced shim must not publish a completed location.
    $remaining = @(Get-CapsulenvLegacyScoopShimRepairPlan)
    return [pscustomobject]@{
        Repaired=$repaired
        Conflicts=$remaining
    }
}
function Sync-CapsulenvLegacyScoopShimsAfterRelocation {
    [CmdletBinding()]
    param()

    $root = (Get-CapsulenvContext).StateRoot
    $stampPath = Join-Path $root 'scoop-shim-location.json'
    $roots = @((Get-CapsulenvScoopRoot), (Get-CapsulenvScoopGlobalRoot))
    if (Test-Path -LiteralPath $stampPath -PathType Leaf) {
        try {
            $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
            if ($stamp.SchemaVersion -eq 1 -and
                [string]$stamp.CapsuleId -eq [string](Get-CapsulenvIdentity) -and
                [string]$stamp.UserRoot -eq [string]$roots[0] -and
                [string]$stamp.GlobalRoot -eq [string]$roots[1]) {
                return
            }
        } catch {}
    }

    $result = Repair-CapsulenvLegacyScoopShims
    if (@($result.Conflicts).Count -gt 0) {
        Write-CapsulenvMessage -Level Warning -Message (
            'Portable Scoop shim relocation left {0} unverified target(s) unchanged; run doctor for details.' -f @($result.Conflicts).Count
        )
        return
    }
    [void](New-Item -ItemType Directory -Path $root -Force)
    $data = [ordered]@{
        SchemaVersion=1
        CapsuleId=Get-CapsulenvIdentity
        UserRoot=[string]$roots[0]
        GlobalRoot=[string]$roots[1]
    } | ConvertTo-Json -Compress
    $temp = Join-Path $root ('.scoop-shim-location-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temp, $data, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $stampPath -Force
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
}
