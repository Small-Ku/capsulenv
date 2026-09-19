Describe 'Capsulenv final composition authority gates' {
    It 'binds every generation selection semantic to the realization manifest' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $realizationSource = Get-Content -LiteralPath (Join-Path $root 'src/12-Realization.ps1') -Raw
        if ($realizationSource -notmatch 'ExpectedVersion[^\r\n]*\$selection\.Version') { throw 'Generation validation omits ExpectedVersion binding.' }
        if ($realizationSource -notmatch 'ExpectedProvider[^\r\n]*\$selection\.Provider') { throw 'Generation validation omits ExpectedProvider binding.' }
        if ($realizationSource -notmatch 'ExpectedProvenance[^\r\n]*\$selection\.Provenance') { throw 'Generation validation omits ExpectedProvenance binding.' }
        if ($realizationSource -notmatch 'ExpectedExecutableRelativePath[^\r\n]*\$selection\.ExecutableRelativePath') { throw 'Generation validation omits executable-path binding.' }
    }

    It 'stops session-scoped services when the child shell exits normally' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $environmentSource = Get-Content -LiteralPath (Join-Path $root 'src/30-Environment.ps1') -Raw
        if ($environmentSource -notmatch 'finally\s*\{[\s\S]*Stop-CapsulenvActiveSessionServices') { throw 'Child-shell finally block does not stop active session services.' }
    }

    It 'keeps discovered Scoop trust decisions explicit' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $resolutionSource = Get-Content -LiteralPath (Join-Path $root 'src/08-ProgramResolution.ps1') -Raw
        if ($resolutionSource -notmatch 'Get-CapsulenvDiscoveredProgramTrustDecision') { throw 'Scoop discovery has no explicit trust decision.' }
        if ($resolutionSource -notmatch '-Trusted:\$trust\.Trusted') { throw 'Discovered Scoop candidates do not consume the trust decision.' }
    }
}
