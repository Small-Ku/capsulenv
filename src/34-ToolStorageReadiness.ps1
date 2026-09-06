function Get-CapsulenvToolStorageReadyMarkerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $payload = New-Object System.Collections.Generic.List[string]
    $payload.Add('tool-storage-schema=1')
    $payload.Add(('create-directories={0}' -f [bool]$Plan.CreateDirectories))
    foreach ($name in @($Plan.Variables.Keys | Sort-Object)) {
        $payload.Add(('variable:{0}={1}' -f $name, [string]$Plan.Variables[$name]))
    }
    foreach ($directory in @($Plan.Directories | Sort-Object)) {
        $payload.Add(('directory:{0}' -f [string]$directory))
    }
    foreach ($file in @($Plan.Files | Sort-Object)) {
        $payload.Add(('file:{0}' -f [string]$file))
    }
    foreach ($entry in @($Plan.PathEntries | Sort-Object)) {
        $payload.Add(('path:{0}' -f [string]$entry))
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($payload -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $markerRoot = Resolve-CapsulenvPath -Path '.capsulenv' -AllowMissing
    return Join-Path $markerRoot ("tool-storage-{0}.ready" -f $hash.Substring(0, 16))
}

function Test-CapsulenvToolStorageReady {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    if (-not $Plan.Enabled -or -not [bool]$Plan.CreateDirectories) {
        return $true
    }
    $markerPath = [string]$Plan.ReadyMarker
    if ([string]::IsNullOrWhiteSpace($markerPath)) {
        return $false
    }
    return Test-Path -LiteralPath $markerPath -PathType Leaf
}

function Complete-CapsulenvToolStorageReadyMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Plan)

    $markerPath = [string]$Plan.ReadyMarker
    if ([string]::IsNullOrWhiteSpace($markerPath)) {
        throw 'ToolStorage plan is missing its readiness marker path.'
    }
    $markerRoot = Split-Path -Parent $markerPath
    if (-not (Test-Path -LiteralPath $markerRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $markerRoot -Force)
    }
    foreach ($stale in @(Get-ChildItem -LiteralPath $markerRoot -Filter 'tool-storage-*.ready' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-CapsulenvSamePath -Left $stale.FullName -Right $markerPath)) {
            Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    [System.IO.File]::WriteAllText($markerPath, 'ready', [System.Text.UTF8Encoding]::new($false))
    return $markerPath
}
