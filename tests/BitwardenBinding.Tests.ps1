Describe 'Capsulenv host Bitwarden attach-only integration' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'does not treat an available Bitwarden executable as a live attachment' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-bitwarden-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/Bitwarden.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        'bitwarden' | Set-Content -LiteralPath $executable -Encoding UTF8
        {
            & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name bitwarden
                $candidate = New-CapsulenvProgramCandidate -Name bitwarden -Executable $Executable -Provider host-scoop -Version 2026.1.0
                Resolve-CapsulenvBitwardenBinding -App bitwarden -Requirement $requirement -Candidates @($candidate) -Criticality required
            } $temporaryRoot $executable
        } | Should -Throw '*not running*'
    }

    It 'attaches only to the exact live host process and never claims ownership' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-bitwarden-live-' + [Guid]::NewGuid().ToString('N'))
        $sleep = @(Get-Command sleep -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
        $process = Start-Process -FilePath $sleep.Source -ArgumentList '30' -PassThru
        try {
            $result = & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name bitwarden
                $candidate = New-CapsulenvProgramCandidate -Name bitwarden -Executable $Executable -Provider host-scoop -Version 2026.1.0
                Resolve-CapsulenvBitwardenBinding -App bitwarden -Requirement $requirement -Candidates @($candidate) -Criticality required
            } $temporaryRoot $sleep.Source

            $result.Succeeded | Should -BeTrue
            $result.ProgramAvailable | Should -BeTrue
            $result.Attached | Should -BeTrue
            $result.OwnedProcess | Should -BeFalse
            $result.CanStop | Should -BeFalse
            $stop = Stop-CapsulenvBitwardenSessionIntegration -Binding $result
            $stop.Stopped | Should -BeFalse
            $stop.Restored | Should -BeTrue
            Get-Process -Id $process.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        } finally {
            if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { Stop-Process -Id $process.Id -Force }
        }
    }

    It 'uses ssh-add to probe endpoint reachability instead of accepting a string' {
        $probe = & $script:Module {
            Test-CapsulenvBitwardenSshAgentEndpoint -Endpoint 'agent://unreachable'
        }
        $probe.Reachable | Should -BeFalse
        $probe.Diagnostics | Should -Match 'real socket|named pipe'
    }

    It 'rejects a required unreachable agent even when Bitwarden is attached' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-bitwarden-agent-' + [Guid]::NewGuid().ToString('N'))
        $sleep = @(Get-Command sleep -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
        $process = Start-Process -FilePath $sleep.Source -ArgumentList '30' -PassThru
        try {
            {
                & $script:Module {
                    param($CapsuleRoot, $Executable)
                    Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                    $requirement = New-CapsulenvProgramRequirement -Name bitwarden
                    $candidate = New-CapsulenvProgramCandidate -Name bitwarden -Executable $Executable -Provider host-scoop -Version 2026.1.0
                    Invoke-CapsulenvBitwardenSessionIntegration -App bitwarden -Requirement $requirement -Candidates @($candidate) -SshAuthSock 'agent://unreachable' -Criticality required
                } $temporaryRoot $sleep.Source
            } | Should -Throw '*unreachable*'
        } finally {
            if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { Stop-Process -Id $process.Id -Force }
        }
    }

    It 'degrades optional integration when no trusted Bitwarden program is available' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-bitwarden-optional-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
        $result = & $script:Module {
            param($CapsuleRoot)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name bitwarden
            Invoke-CapsulenvBitwardenSessionIntegration -App bitwarden -Requirement $requirement -Candidates @() -SshAuthSock 'agent://host' -Criticality optional
        } $temporaryRoot
        $result.Succeeded | Should -BeFalse
        $result.Diagnostics -join ' ' | Should -Match 'Optional'
    }
}
