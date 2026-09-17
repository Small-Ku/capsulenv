[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CapsuleRoot,
    [Parameter(Mandatory = $true)][string]$Launcher,
    [int]$Iterations = 20,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'windows-measurements.json')
)

# Observational research harness. It does not alter production code.
$ErrorActionPreference = 'Stop'

function Get-Snapshot {
    param([string]$Root)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $map }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $relative = $item.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
        $map[$relative] = [int64]$item.Length
    }
    return $map
}

function Measure-Case {
    param([string]$Name, [scriptblock]$Action)
    $startup = New-Object System.Collections.Generic.List[double]
    $deploy = New-Object System.Collections.Generic.List[double]
    $deltas = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Iterations; $i++) {
        $before = Get-Snapshot $CapsuleRoot
        $sw = [Diagnostics.Stopwatch]::StartNew(); & $Action; $sw.Stop(); $deploy.Add($sw.Elapsed.TotalMilliseconds)
        $after = Get-Snapshot $CapsuleRoot
        $created = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
        $deleted = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
        $logical = [int64](($created | ForEach-Object { $after[$_] } | Measure-Object -Sum).Sum)
        $deltas.Add([pscustomobject]@{ LogicalBytesWritten = $logical; FileCreates = $created.Count; FileDeletes = $deleted.Count; FileRenamesInferred = 0 })
        $sw = [Diagnostics.Stopwatch]::StartNew(); & $Launcher status | Out-Null; $sw.Stop(); $startup.Add($sw.Elapsed.TotalMilliseconds)
    }
    $s = @($startup | Sort-Object); $d = @($deploy | Sort-Object)
    return [pscustomobject]@{
        Variant = $Name; Iterations = $Iterations
        StartupP50Ms = $s[[Math]::Floor(($s.Count - 1) * .50)]
        StartupP95Ms = $s[[Math]::Floor(($s.Count - 1) * .95)]
        DeployP50Ms = $d[[Math]::Floor(($d.Count - 1) * .50)]
        DeployP95Ms = $d[[Math]::Floor(($d.Count - 1) * .95)]
        LogicalDeltas = @($deltas)
        SubprocessCount = $null; NetworkBytes = $null; StateMutations = $null
        Note = 'Logical deltas are a lower bound; physical SSD writes and ETW subprocess/network counters are not collected.'
    }
}

$result = [ordered]@{
    Schema = 1; Host = [Environment]::OSVersion.VersionString
    CapsuleRoot = [IO.Path]::GetFullPath($CapsuleRoot); GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    Cases = @(Measure-Case 'current-baseline' { & $Launcher rehydrate | Out-Null })
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

