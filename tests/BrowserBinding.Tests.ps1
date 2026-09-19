Describe 'Capsulenv provider-agnostic browser bindings' {
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

    It 'binds a trusted host browser to a portable profile with an exclusive lease' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-binding-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/firefox.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        'browser' | Set-Content -LiteralPath $executable -Encoding UTF8
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $session = Initialize-CapsulenvSession -Role browser-test
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0 -Provenance scoop:user/firefox
            $binding = Resolve-CapsulenvBrowserBinding -App firefox -Requirement $requirement -Candidates @($candidate) -SessionId $session.SessionId
            [pscustomobject]@{
                Succeeded = $binding.Succeeded
                Provider = $binding.Program.Provider
                ProfilePath = $binding.ProfilePath
                LeasePolicy = $binding.Lease.Policy
                CapsuleRoot = $CapsuleRoot
                SessionId = $session.SessionId
                Lease = $binding.Lease
            }
        } $temporaryRoot $executable

        try {
            $result.Succeeded | Should -BeTrue
            $result.Provider | Should -Be 'host-scoop'
            $result.LeasePolicy | Should -Be 'exclusive'
            $result.ProfilePath | Should -Not -BeLike '*scoop*'
            $result.ProfilePath | Should -BeLike "$temporaryRoot*"
        } finally {
            [void](Release-CapsulenvStateLease -Lease $result.Lease)
        }
    }

    It 'rejects a second writer and never falls back to an unrelated host profile' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-conflict-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/firefox.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        'browser' | Set-Content -LiteralPath $executable -Encoding UTF8
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $session = Initialize-CapsulenvSession -Role browser-test
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
            $first = Resolve-CapsulenvBrowserBinding -App firefox -Requirement $requirement -Candidates @($candidate) -SessionId $session.SessionId
            $secondThrows = $false
            try {
                Resolve-CapsulenvBrowserBinding -App firefox -Requirement $requirement -Candidates @($candidate) -SessionId $session.SessionId | Out-Null
            } catch {
                $secondThrows = $true
            }
            [void](Release-CapsulenvStateLease -Lease $first.Lease)
            $optional = Resolve-CapsulenvBrowserBinding -App firefox -Requirement $requirement -Candidates @() -Criticality optional
            [pscustomobject]@{
                SecondThrows = $secondThrows
                OptionalSucceeded = $optional.Succeeded
                OptionalProfile = $optional.ProfilePath
            }
        } $temporaryRoot $executable

        $result.SecondThrows | Should -BeTrue
        $result.OptionalSucceeded | Should -BeFalse
        $result.OptionalProfile | Should -BeNullOrEmpty
    }

    It 'uses one canonical portable profile for provider-qualified browser selectors' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-identity-' + [Guid]::NewGuid().ToString('N'))
        $paths = & $script:Module {
            param($CapsuleRoot)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            @('firefox', 'scoop/firefox', 'scoop:user/firefox', 'capsule/firefox') |
                ForEach-Object { Get-CapsulenvPortableBrowserProfilePath -App $_ }
        } $temporaryRoot

        @($paths | Select-Object -Unique).Count | Should -Be 1
    }

    It 'fails before leasing a profile when Gecko compatibility evidence disagrees' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-compatibility-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/firefox.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        'browser' | Set-Content -LiteralPath $executable -Encoding UTF8
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $first = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
            $second = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider capsulenv-local -Version 2.0.0
            $session = Initialize-CapsulenvSession -Role browser-compatibility
            $binding = Resolve-CapsulenvBrowserBinding -App firefox -Requirement $requirement -Candidates @($first) -SessionId $session.SessionId
            [void](Release-CapsulenvStateLease -Lease $binding.Lease)
            $throws = $false
            try {
                Resolve-CapsulenvBrowserBinding -App scoop/firefox -Requirement $requirement -Candidates @($second) -SessionId $session.SessionId | Out-Null
            } catch {
                $throws = $_.Exception.Message -match 'compatibility'
            }
            [pscustomobject]@{ Throws = $throws; Profile = $binding.ProfilePath }
        } $temporaryRoot $executable

        $result.Throws | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $result.Profile '.capsulenv-gecko-compatibility.json') | Should -BeTrue
    }

    It 'waits using the nested binding returned by Start-CapsulenvPortableBrowser' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-wait-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/browser.sh'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        "#!/bin/sh`nsleep 1`n" | Set-Content -LiteralPath $executable -NoNewline
        & chmod +x $executable
        $browser = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
            Start-CapsulenvPortableBrowser -App firefox -Requirement $requirement -Candidates @($candidate)
        } $temporaryRoot $executable

        { Wait-CapsulenvPortableBrowser -Browser $browser | Out-Null } | Should -Not -Throw
    }
    It 'waits for the launched browser process before releasing its lease' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-wait-contract-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/browser.sh'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        [System.IO.File]::WriteAllLines($executable, @('#!/bin/sh', 'sleep 1'))
        & chmod +x $executable
        $browser = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
            Start-CapsulenvPortableBrowser -App firefox -Requirement $requirement -Candidates @($candidate)
        } $temporaryRoot $executable
        $started = [DateTime]::UtcNow
        Wait-CapsulenvPortableBrowser -Browser $browser | Out-Null
        $elapsed = ([DateTime]::UtcNow - $started).TotalMilliseconds
        $elapsed | Should -BeGreaterThan 500
        $browser.Process.HasExited | Should -BeTrue
    }

    It 'rejects an existing nonempty profile without compatibility provenance' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-unknown-profile-' + [Guid]::NewGuid().ToString('N'))
        $profile = & $script:Module {
            param($CapsuleRoot)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $path = Get-CapsulenvPortableBrowserProfilePath -App firefox -Create
            'legacy profile' | Set-Content -LiteralPath (Join-Path $path 'prefs.js') -Encoding UTF8
            $path
        } $temporaryRoot
        $result = & $script:Module {
            param($ProfilePath)
            $program = [pscustomobject]@{ Version = '150.0.0' }
            Test-CapsulenvBrowserProfileCompatibility -App firefox -ProfilePath $ProfilePath -Program $program
        } $profile
        $result.Compatible | Should -BeFalse
        $result.Established | Should -BeFalse
        $result.Diagnostic | Should -Match 'refusing to auto-bless'
    }

    It 'terminates a browser when post-spawn ownership registration fails' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-rollback-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/browser.sh'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        [System.IO.File]::WriteAllLines($executable, @('#!/bin/sh', 'sleep 5'))
        & chmod +x $executable
        Mock Register-CapsulenvOwnedProcessRecord { throw 'synthetic registration failure' } -ModuleName Capsulenv
        $throws = $false
        try {
            & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name firefox
                $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
                Start-CapsulenvPortableBrowser -App firefox -Requirement $requirement -Candidates @($candidate) | Out-Null
            } $temporaryRoot $executable
        } catch {
            $throws = $true
        }
        $throws | Should -BeTrue
        $children = @(Get-Process | Where-Object { $_.Path -eq $executable })
        $children | Should -BeNullOrEmpty
    }

    It 'releases the exclusive profile lease when the exact browser process exits' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-browser-exit-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/browser.sh'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        "#!/bin/sh`nsleep 1`n" | Set-Content -LiteralPath $executable -NoNewline
        & chmod +x $executable
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
            Start-CapsulenvPortableBrowser -App firefox -Requirement $requirement -Candidates @($candidate)
        } $temporaryRoot $executable

        try {
            $result.Process.WaitForExit()
            Start-Sleep -Milliseconds 500
            $reacquired = & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name firefox
                $candidate = New-CapsulenvProgramCandidate -Name firefox -Executable $Executable -Provider host-scoop -Version 1.0.0
                $session = Initialize-CapsulenvSession -Role browser-reacquire
                $binding = Resolve-CapsulenvBrowserBinding -App scoop:user/firefox -Requirement $requirement -Candidates @($candidate) -SessionId $session.SessionId
                [void](Release-CapsulenvStateLease -Lease $binding.Lease)
                $true
            } $temporaryRoot $executable
            $reacquired | Should -BeTrue
        } finally {
            if ($null -ne $result.Binding.Lease) {
                [void](Release-CapsulenvStateLease -Lease $result.Binding.Lease)
            }
        }
    }
}

