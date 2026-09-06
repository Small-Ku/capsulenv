function Update-CapsulenvAppMetadata {
    [CmdletBinding()]
    param()

    [void](Set-CapsulenvSessionEnvironment)
    [void](Invoke-CapsulenvScoopCommand -Arguments @('update'))
}

function Resolve-CapsulenvAppUpdateTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $separator = $Reference.IndexOf('/')
    if ($separator -gt 0) {
        $prefix = $Reference.Substring(0, $separator).ToLowerInvariant()
        if ($prefix -in @('capsule', 'scoop', 'scoop:user', 'scoop:global', 'user', 'global')) {
            $installed = Get-CapsulenvInstalledApp -Selector $Reference
            if ([string]$installed.Provider -eq 'Capsulenv') {
                $state = Get-CapsulenvInstalledPackageState -Name ([string]$installed.Name)
                return [pscustomobject]@{ Provider='Capsulenv'; ProviderScope=$null; Scope='Capsule'; Name=[string]$installed.Name; Reference=[string]$state.Reference }
            }
            return [pscustomobject]@{ Provider='Scoop'; ProviderScope=$installed.ProviderScope; Scope=[string]$installed.Scope; Name=[string]$installed.Name; Reference=[string]$installed.Selector }
        }

        $parsed = Split-CapsulenvPackageReference -Reference $Reference
        $state = Get-CapsulenvInstalledPackageState -Name ([string]$parsed.Name) -AllowMissing
        if ($null -eq $state) {
            throw (New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.Package.NotInstalled' `
                -Message "Package is not installed as a Capsulenv-owned PortableSafe package: $Reference" `
                -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                -TargetObject $Reference `
                -Remediation @("Install it first with 'capsulenv app install $Reference'."))
        }
        return [pscustomobject]@{ Provider='Capsulenv'; ProviderScope=$null; Scope='Capsule'; Name=[string]$state.Name; Reference=$Reference }
    }

    $match = Get-CapsulenvInstalledApp -Selector $Reference
    if ([string]$match.Provider -eq 'Capsulenv') {
        $state = Get-CapsulenvInstalledPackageState -Name ([string]$match.Name)
        return [pscustomobject]@{ Provider='Capsulenv'; ProviderScope=$null; Scope='Capsule'; Name=[string]$match.Name; Reference=[string]$state.Reference }
    }
    return [pscustomobject]@{ Provider='Scoop'; ProviderScope=$match.ProviderScope; Scope=[string]$match.Scope; Name=[string]$match.Name; Reference=[string]$match.Selector }
}

function Invoke-CapsulenvAppCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        Show-CapsulenvHelp -Topic app
        return
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    if ($action -in @('help', '--help', '-h')) {
        if ($remaining.Count -gt 1) {
            throw (New-CapsulenvCliUsageError -Message 'app help accepts at most one action.' -Usage 'capsulenv app help [action]' -Topic app)
        }
        $helpAction = if ($remaining.Count -eq 1) { [string]$remaining[0] } else { $null }
        Show-CapsulenvHelp -Topic app -Action $helpAction
        return
    }
    if ($remaining.Count -eq 1 -and [string]$remaining[0] -in @('--help', '-h')) {
        Show-CapsulenvHelp -Topic app -Action $action
        return
    }
    switch ($action) {
        'plan' {
            $json = $remaining -contains '--json'
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -ne '--json' })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $references.Count -ne 1) {
                throw (New-CapsulenvCliUsageError -Message 'app plan requires exactly one package reference.' -Usage 'capsulenv app plan <app|bucket/app> [--json]' -Topic app)
            }
            $plan = Get-CapsulenvPackageInstallPlan -Reference ([string]$references[0])
            if ($json) {
                ConvertTo-CapsulenvPackageInstallPlanContract -Plan $plan |
                    ConvertTo-Json -Depth 8 |
                    Write-Output
                break
            }
            $plan.Packages |
                Select-Object Reference, Version, Architecture, Classification,
                    @{ Name = 'Capabilities'; Expression = { @($_.Capabilities) -join ',' } },
                    @{ Name = 'Reasons'; Expression = { @($_.Reasons) -join '; ' } } |
                Format-Table -AutoSize
            if ([string]$plan.Classification -ne 'PortableSafe') {
                Write-CapsulenvMessage -Level Warning -Message "TrustedExecution review is required. Run 'capsulenv app review $([string]$plan.Reference)' to inspect the exact lifecycle surface before allowing upstream Scoop execution."
            }
        }
        'review' {
            $raw = $remaining -contains '--raw'
            $json = $remaining -contains '--json'
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin @('--raw', '--json') })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $references.Count -ne 1 -or ($raw -and $json)) {
                throw (New-CapsulenvCliUsageError -Message 'app review requires one package reference and at most one output mode.' -Usage 'capsulenv app review <app|bucket/app|scoop/app|scoop:user/app|scoop:global/app> [--raw|--json]' -Topic app)
            }
            $review = Get-CapsulenvPackageReviewPlan -Reference ([string]$references[0])
            if ($json) {
                $review | ConvertTo-Json -Depth 12 | Write-Output
                break
            }
            Write-CapsulenvPackageReview -Review $review -Raw:$raw
        }
        'install' {
            $allowTrusted = $remaining -contains '--allow-trusted'
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -ne '--allow-trusted' })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $references.Count -ne 1) {
                throw (New-CapsulenvCliUsageError -Message 'app install requires exactly one package reference.' -Usage 'capsulenv app install <app|bucket/app> [--allow-trusted]' -Topic app)
            }
            $reference = [string]$references[0]
            $plan = Get-CapsulenvPackageInstallPlan -Reference $reference
            if ([string]$plan.Classification -eq 'PortableSafe') {
                Install-CapsulenvPortablePackage -Reference $reference |
                    Select-Object Name, Version, Architecture, Reference, InstallRoot |
                    Format-Table -AutoSize
                break
            }
            if (-not $allowTrusted) {
                $blocked = @($plan.BlockedPackages | ForEach-Object {
                    '{0} [{1}] {2}' -f $_.Reference, $_.Classification, (@($_.Reasons) -join '; ')
                }) -join [Environment]::NewLine
                throw (New-CapsulenvDiagnosticErrorRecord `
                    -Id 'Capsulenv.Package.TrustedExecutionRequired' `
                    -Message "Package requires semantics outside PortableSafe. Review the plan before using TrustedExecution.`n$blocked" `
                    -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
                    -TargetObject $reference `
                    -Context ([ordered]@{ Reference = $reference; BlockedPackages = @($plan.BlockedPackages) }) `
                    -Remediation @(
                        "Run 'capsulenv app review $reference' to inspect lifecycle scripts, complete manifests and review guidance.",
                        "Use 'capsulenv app review $reference --raw' when you need the exact source manifest.",
                        'Use --allow-trusted only if upstream Scoop lifecycle execution is acceptable.'
                    ))
            }

            [void](Set-CapsulenvSessionEnvironment)
            Write-CapsulenvMessage -Level Warning -Message "Delegating '$reference' to unmodified upstream Scoop. Third-party lifecycle code may execute and is outside Capsulenv's PortableSafe guarantees."
            [void](Invoke-CapsulenvScoopCommand -Arguments @('install', $reference))
        }
        'update' {
            $allowTrusted = $remaining -contains '--allow-trusted'
            $localOnly = $remaining -contains '--local'
            $all = $remaining -contains '--all'
            $knownFlags = @('--allow-trusted', '--local', '--all')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $knownFlags })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if (
                $unknownFlags.Count -gt 0 -or
                ($all -and $references.Count -gt 0) -or
                (-not $all -and $references.Count -ne 1) -or
                ($all -and $allowTrusted)
            ) {
                throw (New-CapsulenvCliUsageError `
                    -Message 'app update accepts one installed app, or --all for Capsulenv-owned PortableSafe packages.' `
                    -Usage 'capsulenv app update <app|bucket/app|capsule/app|scoop/app|scoop:user/app|scoop:global/app> [--allow-trusted] [--local] | capsulenv app update --all [--local]' `
                    -Topic app)
            }

            if (-not $localOnly) {
                Update-CapsulenvAppMetadata
            }
            if ($all) {
                $states = @(Get-CapsulenvInstalledPackageStates -Strict | Sort-Object Name)
                foreach ($state in $states) {
                    Update-CapsulenvPortablePackage -Reference ([string]$state.Reference) |
                        Select-Object Name, Version, Architecture, Reference, InstallRoot |
                        Format-Table -AutoSize
                }
                break
            }

            $target = Resolve-CapsulenvAppUpdateTarget -Reference ([string]$references[0])
            if ([string]$target.Provider -eq 'Capsulenv') {
                Update-CapsulenvPortablePackage -Reference ([string]$target.Reference) |
                    Select-Object Name, Version, Architecture, Reference, InstallRoot |
                    Format-Table -AutoSize
                break
            }
            if (-not $allowTrusted) {
                throw (New-CapsulenvDiagnosticErrorRecord `
                    -Id 'Capsulenv.Package.TrustedUpdateRequired' `
                    -Message "'$($target.Reference)' is owned by upstream Scoop, so its update may execute package lifecycle code." `
                    -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
                    -TargetObject ([string]$target.Reference) `
                    -Remediation @(
                        "Run 'capsulenv app review $($target.Reference)' to inspect the current source manifest and dependency graph that Scoop would use for the update.",
                        "Re-run with --allow-trusted only after that review, or use upstream Scoop directly."
                    ))
            }
            [void](Set-CapsulenvSessionEnvironment)
            Write-CapsulenvMessage -Level Warning -Message "Delegating update of '$($target.Reference)' to unmodified upstream Scoop. Package lifecycle code and host mutation are outside Capsulenv's PortableSafe guarantees."
            $scoopArguments = if ([string]$target.ProviderScope -eq 'Global') {
                @('update', [string]$target.Name, '--global')
            } else {
                @('update', [string]$target.Name)
            }
            [void](Invoke-CapsulenvScoopCommand -Arguments $scoopArguments)
        }
        'list' {
            if ($remaining.Count -gt 1) {
                throw (New-CapsulenvCliUsageError -Message 'app list accepts at most one app selector.' -Usage 'capsulenv app list [app]' -Topic app)
            }
            if ($remaining.Count -eq 0) {
                Get-CapsulenvInstalledAppInventory |
                    Select-Object Provider, ScoopScope, App, Selector, Version, Bucket, Ready |
                    Format-Table -AutoSize
                break
            }
            Get-CapsulenvScoopAppShortcuts -App ([string]$remaining[0]) |
                Select-Object Provider, @{ Name='ScoopScope'; Expression={ [string]$_.ProviderScope } }, App, Selector, Name, Target, Arguments, Architecture |
                Format-Table -AutoSize
        }
        'run' {
            if ($remaining.Count -lt 1) {
                throw (New-CapsulenvCliUsageError -Message 'app run requires an installed app selector.' -Usage 'capsulenv app run <app> ["shortcut name"] [-- runtime arguments...]' -Topic app)
            }
            $selector = [string]$remaining[0]
            $tail = @($remaining | Select-Object -Skip 1)
            $separatorIndex = [Array]::IndexOf([object[]]$tail, '--')
            $before = @(
                if ($separatorIndex -ge 0) {
                    if ($separatorIndex -gt 0) { $tail[0..($separatorIndex - 1)] }
                } else { $tail }
            )
            if ($before.Count -gt 1) {
                throw (New-CapsulenvCliUsageError -Message 'app run accepts at most one shortcut name before --.' -Usage 'capsulenv app run <app> ["shortcut name"] [-- runtime arguments...]' -Topic app)
            }
            $runtime = @(
                if ($separatorIndex -ge 0 -and $separatorIndex -lt ($tail.Count - 1)) {
                    $tail[($separatorIndex + 1)..($tail.Count - 1)]
                }
            )
            $shortcutName = if ($before.Count -eq 1) { [string]$before[0] } else { $null }
            [void](Start-CapsulenvScoopShortcut -App $selector -ShortcutName $shortcutName -Arguments $runtime)
        }
        'exec' {
            if ($remaining.Count -lt 2) {
                throw (New-CapsulenvCliUsageError -Message 'app exec requires an installed app selector and bin alias.' -Usage 'capsulenv app exec <installed-app> <bin> [-- arguments...]' -Topic app)
            }
            $selector = [string]$remaining[0]
            $binName = [string]$remaining[1]
            $tail = @($remaining | Select-Object -Skip 2)
            if ($tail.Count -gt 0 -and [string]$tail[0] -eq '--') {
                $tail = @($tail | Select-Object -Skip 1)
            }
            return Invoke-CapsulenvInstalledAppExecutable -App $selector -BinName $binName -Arguments $tail
        }
        default {
            throw (New-CapsulenvCliUnknownActionError -Group app -Action $action -Id 'Capsulenv.Cli.UnknownAppAction')
        }
    }
}
