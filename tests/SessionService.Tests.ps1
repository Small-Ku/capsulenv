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

    It 'does not call an alive process ready when its configured TCP endpoint is closed' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-readiness-' + [Guid]::NewGuid().ToString('N'))
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        $sleep = @(Get-Command sleep -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
        $process = Start-Process -FilePath $sleep.Source -ArgumentList @('30') -PassThru
        try {
            $result = & $script:Module {
                param($Process, $Port)
                Test-CapsulenvSessionServiceReady -Process $Process -ReadinessProbe { param($Child) Test-CapsulenvTcpEndpoint -Address '127.0.0.1' -Port $Port } -HealthProbe { param($Child) $true } -TimeoutMilliseconds 150
            } $process $port
            $result.Ready | Should -BeFalse
            $result.Healthy | Should -BeFalse
        } finally {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not treat detached spawn as ready and stops only the exact owned service' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-' + [Guid]::NewGuid().ToString('N'))
        $sleep = Join-Path $temporaryRoot 'sing-box.sh'
        $config = Join-Path $temporaryRoot 'state/portable/sing-box/config.json'
        $pidPath = Join-Path $temporaryRoot 'sing-box.pid'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $sleep) -Force)
        "#!/bin/sh`necho \`$PPID > '$pidPath'`nsleep 30`n" | Set-Content -LiteralPath $sleep -NoNewline
        Mock Start-Process { Start-CapsulenvTestSleepProcess -Seconds 30 } -ModuleName Capsulenv
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force)
        '{}' | Set-Content -LiteralPath $config -NoNewline
        $result = & $script:Module {
            param($CapsuleRoot, $Executable, $ConfigPath)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $session = Initialize-CapsulenvSession -Role service-test
            $requirement = New-CapsulenvProgramRequirement -Name sing-box
            $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0
            $proxyBefore = [Environment]::GetEnvironmentVariable('CAPSULENV_TEST_SESSION_PROXY', 'Process')
            $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality required -ConfigPath $ConfigPath -ReadinessProbe { param($Process) -not $Process.HasExited } -ProxyEnvironment @{ CAPSULENV_TEST_SESSION_PROXY = 'http://127.0.0.1:45999' }
            $started = Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate) -SessionId $session.SessionId
            $stopped = Stop-CapsulenvSessionService -Binding $started
            [pscustomobject]@{
                Started = $started.Succeeded
                Ready = $started.Readiness.Ready
                Attached = $started.Attached
                Owned = ($started.ProcessRecord.Ownership -eq 'owned')
                ConfigArgument = ($started.Arguments -contains $ConfigPath)
                Stopped = $stopped.Stopped
                ProxyBefore = $proxyBefore
                ProxyAfter = [Environment]::GetEnvironmentVariable('CAPSULENV_TEST_SESSION_PROXY', 'Process')
            }
        } $temporaryRoot $sleep $config

        $result.Started | Should -BeTrue
        $result.Ready | Should -BeTrue
        $result.Attached | Should -BeFalse
        $result.Owned | Should -BeTrue
        $result.ConfigArgument | Should -BeTrue
        $result.Stopped | Should -BeTrue
        $result.ProxyAfter | Should -BeNullOrEmpty
    }

    It 'restores proxy environment when an owned service exits' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-proxy-exit-' + [Guid]::NewGuid().ToString('N'))
        $sleep = @(Get-Command sleep -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $before = [Environment]::GetEnvironmentVariable('CAPSULENV_TEST_SESSION_PROXY_EXIT', 'Process')
            $requirement = New-CapsulenvProgramRequirement -Name sing-box
            $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $Executable -Provider host-scoop -Version 1.0.0
            $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality required -ReadinessProbe { param($Process) -not $Process.HasExited } -ProxyEnvironment @{ CAPSULENV_TEST_SESSION_PROXY_EXIT = 'http://127.0.0.1:45998' }
            $definition.Arguments = @('30')
            $started = Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate) -ReadinessTimeoutMilliseconds 500
            $started.Process.WaitForExit()
            for ($attempt = 0; $attempt -lt 20 -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CAPSULENV_TEST_SESSION_PROXY_EXIT', 'Process')); $attempt++) {
                Start-Sleep -Milliseconds 100
            }
            [pscustomobject]@{ Before = $before; After = [Environment]::GetEnvironmentVariable('CAPSULENV_TEST_SESSION_PROXY_EXIT', 'Process') }
        } $temporaryRoot $sleep.Source

        $result.After | Should -BeNullOrEmpty
    }
    It 'fails optional activation when readiness never arrives and cleans the owned process' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-fail-' + [Guid]::NewGuid().ToString('N'))
        $truePath = if (Test-Path -LiteralPath '/bin/true' -PathType Leaf) {
            '/bin/true'
        } else {
            (Get-Command pwsh.exe, pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        }
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
        $sleep = @(Get-Command sleep -CommandType Application -ErrorAction Stop | Select-Object -First 1)[0]
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
        $testPwsh = Get-CapsulenvTestPowerShellExecutable
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        $scriptText = "#!/bin/sh`necho \`$\`$ > '$pidPath'`nsleep 30`n"
        $scriptText | Set-Content -LiteralPath $executable -NoNewline
        Mock Start-Process { Start-CapsulenvTestSleepProcess -Seconds 30 -WritePidPath $pidPath } -ModuleName Capsulenv
        {
            & $script:Module {
                param($CapsuleRoot, $Executable, $ProgramExecutable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name sing-box
                $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable $ProgramExecutable -Provider host-scoop -Version 1.0.0
                $definition = New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $requirement -Criticality required -ReadinessProbe { throw 'probe failure' }
                $definition.Arguments = @($Executable)
                Start-CapsulenvSessionService -Definition $definition -Candidates @($candidate)
            } $temporaryRoot $executable $testPwsh
        } | Should -Throw '*probe failure*'
        if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
            $spawnedPid = [int](Get-Content -LiteralPath $pidPath -Raw)
            Start-Sleep -Milliseconds 100
            Get-Process -Id $spawnedPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'derives bootstrap proxy environment from the configured inbound type' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-proxy-map-' + [Guid]::NewGuid().ToString('N'))
        $config = Join-Path $temporaryRoot 'config.json'
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        [ordered]@{
            inbounds = @(
                [ordered]@{ type = 'mixed'; listen = '127.0.0.1'; listen_port = 47891 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $config -Encoding UTF8

        $result = & $script:Module {
            param($ConfigPath)
            $endpoint = Get-CapsulenvSessionServiceTcpEndpoint -ConfigPath $ConfigPath
            $environment = Get-CapsulenvSessionServiceProxyEnvironment -Endpoint $endpoint
            [pscustomobject]@{
                Type = $endpoint.Type
                Http = $environment.HTTP_PROXY
                Https = $environment.HTTPS_PROXY
                HasAllProxy = $environment.ContainsKey('ALL_PROXY')
            }
        } $config

        $result.Type | Should -Be 'mixed'
        $result.Http | Should -Be 'http://127.0.0.1:47891'
        $result.Https | Should -Be 'http://127.0.0.1:47891'
        $result.HasAllProxy | Should -BeFalse
    }

    It 'runs provider acquisition inside a non-recursive bootstrap service scope and always stops it' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-service-bootstrap-scope-' + [Guid]::NewGuid().ToString('N'))
        $config = Join-Path $temporaryRoot 'state/portable/sing-box/config.json'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force)
        [ordered]@{
            inbounds = @(
                [ordered]@{ type = 'mixed'; listen = '127.0.0.1'; listen_port = 47892 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $config -Encoding UTF8

        Mock Resolve-CapsulenvProgramWithAcquisition {
            $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable '/bin/true' -Provider capsulenv-local -AcquisitionProvider seed -Scope host-local -Version 1.0.0 -Capabilities @('proxy') -Trusted:$true -OwnsLifecycle:$true -Provenance 'bootstrap/test'
            [pscustomobject]@{ Succeeded = $true; Selected = $candidate }
        } -ModuleName Capsulenv

        Mock Start-CapsulenvSessionService {
            [pscustomobject]@{
                Succeeded = $true
                Attached = $false
                ProcessRecord = [pscustomobject]@{ Ownership = 'owned' }
                StateLease = $null
                SessionId = 'bootstrap-test'
            }
        } -ModuleName Capsulenv

        Mock Stop-CapsulenvSessionService {
            [pscustomobject]@{ Stopped = $true }
        } -ModuleName Capsulenv

        {
            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name pwsh
                Invoke-CapsulenvProviderBootstrapNetworkScope -Requirement $requirement -Operation { throw 'provider operation failed' }
            } $temporaryRoot
        } | Should -Throw '*provider operation failed*'

        Should -Invoke Resolve-CapsulenvProgramWithAcquisition -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Start-CapsulenvSessionService -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Stop-CapsulenvSessionService -ModuleName Capsulenv -Times 1 -Exactly
    }

}

