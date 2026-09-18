Describe 'Capsulenv SessionService lifecycle' {
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

    It 'does not treat detached spawn as ready and stops only the exact owned service' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-' + [Guid]::NewGuid().ToString('N'))
        $sleep = Join-Path $temporaryRoot 'sing-box.sh'
        $config = Join-Path $temporaryRoot 'state/portable/sing-box/config.json'
        $pidPath = Join-Path $temporaryRoot 'sing-box.pid'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $sleep) -Force)
        "#!/bin/sh`necho \`$PPID > '$pidPath'`nsleep 30`n" | Set-Content -LiteralPath $sleep -NoNewline
        & chmod +x $sleep
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force)
        '{}' | Set-Content -LiteralPath $config -NoNewline
        $result = & $script:Module {
            param($CapsuleRoot, $Executable, $ConfigPath)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $session = Initialize-CapsulenvSession -Role service-test
            $requirement = New-CapsulenvProgramRequirement -Name sing-box
            $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0
            $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality required -ConfigPath $ConfigPath -ReadinessProbe { param($Process) -not $Process.HasExited }
            $started = Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate) -SessionId $session.SessionId
            $stopped = Stop-CapsulenvSessionService -Binding $started
            [pscustomobject]@{
                Started = $started.Succeeded
                Ready = $started.Readiness.Ready
                Attached = $started.Attached
                Owned = ($started.ProcessRecord.Ownership -eq 'owned')
                ConfigArgument = ($started.Arguments -contains $ConfigPath)
                Stopped = $stopped.Stopped
            }
        } $temporaryRoot $sleep $config

        $result.Started | Should -BeTrue
        $result.Ready | Should -BeTrue
        $result.Attached | Should -BeFalse
        $result.Owned | Should -BeTrue
        $result.ConfigArgument | Should -BeTrue
        $result.Stopped | Should -BeTrue
    }

    It 'fails optional activation when readiness never arrives and cleans the owned process' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-fail-' + [Guid]::NewGuid().ToString('N'))
        $truePath = if (Test-Path -LiteralPath '/bin/true' -PathType Leaf) { '/bin/true' } else { 'true' }
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name sing-box
            $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0
            $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality optional -ReadinessProbe { $false }
            Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate) -ReadinessTimeoutMilliseconds 100
        } $temporaryRoot $truePath

        $result.Succeeded | Should -BeFalse
        $result.Diagnostics -join ' ' | Should -Match 'readiness'
    }

    It 'keeps an attached healthy service non-stoppable' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-attached-' + [Guid]::NewGuid().ToString('N'))
        $sleep = @(Get-Command true -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
        $process = Start-Process -FilePath $sleep.Source -ArgumentList '30' -PassThru
        $result = & $script:Module {
            param($Executable, $ProcessId)
            $program = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0 -Provenance host-scoop/sing-box
            $record = [pscustomobject]@{
                PID = $ProcessId
                Ownership = 'attached'
                Role = 'sing-box'
                Provenance = 'host-scoop/sing-box'
                ProcessStartIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $ProcessId
            }
            $binding = New-CapsulenvAttachedSessionServiceBinding -ProcessRecord $record -Program $program -ServiceName sing-box -HealthProbe { param($Process) -not $Process.HasExited }
            $stop = Stop-CapsulenvSessionService -Binding $binding
            [pscustomobject]@{
                Attached = $binding.Attached
                Owned = $binding.OwnedProcess
                Stopped = $stop.Stopped
            }
        } $sleep.Source $process.Id
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $result.Attached | Should -BeTrue
        $result.Owned | Should -BeFalse
        $result.Stopped | Should -BeFalse
    }

    It 'requires a readiness contract for a required service' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-no-readiness-' + [Guid]::NewGuid().ToString('N'))
        $sleep = @(Get-Command sleep -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
        {
            & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name sing-box
                $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0
                $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality required
                Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate)
            } $temporaryRoot $sleep.Source
        } | Should -Throw '*readiness probe*'
    }

    It 'cleans the exact spawned process when readiness machinery throws' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-probe-throw-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'sing-box.sh'
        $pidPath = Join-Path $temporaryRoot 'pid'
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        $scriptText = @'
#!/bin/sh
echo $$ > __PID_PATH__
sleep 30
'@.Replace('__PID_PATH__', $pidPath)
        $scriptText | Set-Content -LiteralPath $executable -NoNewline
        & chmod +x $executable
        {
            & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name sing-box
                $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0
                $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality required -ReadinessProbe { throw 'probe failure' }
                Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate)
            } $temporaryRoot $executable
        } | Should -Throw '*probe failure*'
        $spawnedPid = [int](Get-Content -LiteralPath $pidPath -Raw)
        Start-Sleep -Milliseconds 100
        Get-Process -Id $spawnedPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
