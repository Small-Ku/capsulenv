/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CapsuleRoot,
    [Parameter(Mandatory = $true)][string]$Launcher,
    [string]$PortableRoot = $CapsuleRoot,
    [string]$HostRoot = '',
    [string]$DeployArguments = 'rehydrate',
    [int]$Iterations = 20,
    [int]$WarmIterations = 0,
    [int]$ColdIterations = 0,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'windows-measurements.json')
)

# Observational research harness. It does not alter production code.
# It measures logical file deltas and process wall time. Physical SSD writes,
# ETW subprocess counts, and network byte counters are intentionally null
# unless an external collector is attached.
$ErrorActionPreference = 'Stop'
if ($WarmIterations -le 0) { $WarmIterations = $Iterations }
if ($ColdIterations -le 0) { $ColdIterations = $Iterations }

function Get-Snapshot {
    param([string]$Root)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return $map }
    $prefix = ([IO.Path]::GetFullPath($Root)).TrimEnd('\')
    foreach ($item in @(Get-ChildItem -LiteralPath $prefix -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $relative = $item.FullName.Substring($prefix.Length).TrimStart('\')
        $map[$relative] = [pscustomobject]@{ Length = [int64]$item.Length; FullName = $item.FullName }
    }
    return $map
}

function Get-CombinedSnapshot {
    $combined = @{}
    foreach ($rootInfo in @(
        [pscustomobject]@{ Name = 'portable'; Root = $PortableRoot },
        [pscustomobject]@{ Name = 'host'; Root = $HostRoot }
    )) {
        if ([string]::IsNullOrWhiteSpace($rootInfo.Root)) { continue }
        foreach ($entry in (Get-Snapshot $rootInfo.Root).GetEnumerator()) {
            $combined[($rootInfo.Name + ':' + $entry.Key)] = $entry.Value
        }
    }
    return $combined
}

function Compare-Snapshot {
    param([hashtable]$Before, [hashtable]$After)
    $created = @($After.Keys | Where-Object { -not $Before.ContainsKey($_) })
    $deleted = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) })
    $changed = @($After.Keys | Where-Object {
        $Before.ContainsKey($_) -and $After[$_].Length -ne $Before[$_].Length
    })
    $bytes = [int64]0
    foreach ($path in $created) { $bytes += $After[$path].Length }
    foreach ($path in $changed) {
        $delta = $After[$path].Length - $Before[$path].Length
        if ($delta -gt 0) { $bytes += $delta }
    }

    # Snapshot-only rename heuristic: pair created/deleted files with equal
    # sizes. It is explicitly reported as inferred, not a syscall count.
    $createdBySize = @{}
    foreach ($path in $created) {
        $size = [string]$After[$path].Length
        if (-not $createdBySize.ContainsKey($size)) { $createdBySize[$size] = 0 }
        $createdBySize[$size]++
    }
    $renamePairs = 0
    foreach ($path in $deleted) {
        $size = [string]$Before[$path].Length
        if ($createdBySize.ContainsKey($size) -and $createdBySize[$size] -gt 0) {
            $createdBySize[$size]--
            $renamePairs++
        }
    }
    $changedPaths = @($created + $changed)
    $statePaths = @($changedPaths | Where-Object {
        $_ -match '(?i)(state|index|manifest|active|rehydrat|desired|current)'
    })
    $portableBytes = [int64]0
    foreach ($path in $changedPaths | Where-Object { $_ -like 'portable:*' }) {
        if ($created -contains $path) { $portableBytes += $After[$path].Length; continue }
        $delta = $After[$path].Length - $Before[$path].Length
        if ($delta -gt 0) { $portableBytes += $delta }
    }
    return [pscustomobject]@{
        LogicalBytesWritten = $bytes
        PortableBytesWritten = $portableBytes
        FileCreates = $created.Count
        FileDeletes = $deleted.Count
        FileRenamesInferred = $renamePairs
        StateMutationsInferred = $statePaths.Count
        ChangedFiles = $changed.Count
    }
}

function Invoke-Warm {
    param([string[]]$Arguments)
    & $Launcher @Arguments | Out-Null
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "launcher exited with $LASTEXITCODE" }
}

function Invoke-Cold {
    param([string[]]$Arguments)
    $extension = [IO.Path]::GetExtension($Launcher).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $powershell = Join-Path $PSHOME 'powershell.exe'
        $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Launcher) + $Arguments
        $process = Start-Process -FilePath $powershell -ArgumentList $argumentList -Wait -PassThru -WindowStyle Hidden
    } else {
        $process = Start-Process -FilePath $Launcher -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    }
    if ($process.ExitCode -ne 0) { throw "cold launcher exited with $($process.ExitCode)" }
}

function Measure-Variant {
    param([string]$Name, [bool]$Cold, [int]$Count)
    $deploySamples = New-Object System.Collections.Generic.List[double]
    $startupSamples = New-Object System.Collections.Generic.List[double]
    $deltas = New-Object System.Collections.Generic.List[object]
    $deployArgs = @($DeployArguments -split '\s+' | Where-Object { $_ })
    for ($i = 0; $i -lt $Count; $i++) {
        $before = Get-CombinedSnapshot
        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($Cold) { Invoke-Cold $deployArgs } else { Invoke-Warm $deployArgs }
        $sw.Stop(); $deploySamples.Add($sw.Elapsed.TotalMilliseconds)
        $after = Get-CombinedSnapshot
        $delta = Compare-Snapshot $before $after
        $delta | Add-Member -NotePropertyName ElapsedMs -NotePropertyValue $sw.Elapsed.TotalMilliseconds
        $deltas.Add($delta)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($Cold) { Invoke-Cold @('status') } else { Invoke-Warm @('status') }
        $sw.Stop(); $startupSamples.Add($sw.Elapsed.TotalMilliseconds)
    }
    $deploySorted = @($deploySamples | Sort-Object)
    $startupSorted = @($startupSamples | Sort-Object)
    return [pscustomobject]@{
        Variant = $Name
        ColdProcess = $Cold
        Iterations = $Count
        StartupP50Ms = $startupSorted[[Math]::Floor(($startupSorted.Count - 1) * .50)]
        StartupP95Ms = $startupSorted[[Math]::Floor(($startupSorted.Count - 1) * .95)]
        DeployP50Ms = $deploySorted[[Math]::Floor(($deploySorted.Count - 1) * .50)]
        DeployP95Ms = $deploySorted[[Math]::Floor(($deploySorted.Count - 1) * .95)]
        LogicalDeltas = @($deltas)
        DagNodeCount = 8
        DagEdgeCount = 11
        SubprocessCount = $null
        NetworkBytes = $null
        PhysicalPortableBytesWritten = $null
        PhysicalTotalBytesWritten = $null
        Note = 'Logical snapshot deltas only. Attach ETW/storage/network collectors for subprocess, network, and physical write metrics.'
    }
}

$resolvedHostRoot = $null
if (-not [string]::IsNullOrWhiteSpace($HostRoot)) { $resolvedHostRoot = [IO.Path]::GetFullPath($HostRoot) }
$result = [ordered]@{
    Schema = 2
    Host = [Environment]::OSVersion.VersionString
    CapsuleRoot = [IO.Path]::GetFullPath($CapsuleRoot)
    PortableRoot = [IO.Path]::GetFullPath($PortableRoot)
    HostRoot = $resolvedHostRoot
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    EvidenceClass = 'Windows logical runtime measurement; physical and ETW fields remain unmeasured'
    Cases = @(
        (Measure-Variant 'warm' $false $WarmIterations),
        (Measure-Variant 'cold' $true $ColdIterations)
    )
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10
