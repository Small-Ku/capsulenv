function New-CapsulenvOrderedDictionary {
    return New-Object System.Collections.Specialized.OrderedDictionary
}

function Read-CapsulenvIniFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $data = New-CapsulenvOrderedDictionary
    $currentSection = $null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $data
    }

    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('#')) {
            continue
        }
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1]
            if (-not $data.Contains($currentSection)) {
                $data.Add($currentSection, (New-CapsulenvOrderedDictionary))
            }
            continue
        }
        if ($null -eq $currentSection) {
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $section = $data[$currentSection]
        if ($section.Contains($key)) {
            $section[$key] = $value
        } else {
            $section.Add($key, $value)
        }
    }

    return $data
}

function Write-CapsulenvIniFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($sectionName in $Data.Keys) {
        $lines.Add("[$sectionName]")
        $section = $Data[$sectionName]
        foreach ($key in $section.Keys) {
            $lines.Add("$key=$($section[$key])")
        }
        $lines.Add('')
    }

    $parent = Split-Path -Parent $Path
    if ($parent) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $temporaryPath = "$Path.capsulenv.$PID.tmp"
    try {
        [System.IO.File]::WriteAllLines($temporaryPath, $lines, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-CapsulenvIniValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    if (-not $Data.Contains($Section)) {
        $Data.Add($Section, (New-CapsulenvOrderedDictionary))
    }
    if ($Data[$Section].Contains($Name)) {
        $Data[$Section][$Name] = $Value
    } else {
        $Data[$Section].Add($Name, $Value)
    }
}
