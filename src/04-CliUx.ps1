$script:CapsulenvCliCommandCatalog = $null
$script:CapsulenvCliActionCatalog = $null

function Get-CapsulenvCliCommandCatalog {
    [CmdletBinding()]
    param()

    if ($null -ne $script:CapsulenvCliCommandCatalog) {
        return @($script:CapsulenvCliCommandCatalog)
    }

    $script:CapsulenvCliCommandCatalog = @(
        [pscustomobject][ordered]@{ Category='Start'; Name='shell'; Usage='capsulenv shell'; Summary='Open the default ShellOnly capsule shell.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Start'; Name='user-shell'; Usage='capsulenv user-shell [--force]'; Summary='Synchronize explicit User integration and open a User-mode shell.'; Topic='user'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Start'; Name='run'; Usage='capsulenv run <command> [arguments...]'; Summary='Run one command with the capsule process environment.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Packages'; Name='app'; Usage='capsulenv app <plan|review|install|update|list|run|exec> [...]'; Summary='Plan, install, update, inspect, or launch capsule applications.'; Topic='app'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Packages'; Name='bucket'; Usage='capsulenv bucket <list|known|add|remove|update> [...]'; Summary='Manage upstream Scoop bucket metadata without changing Scoop semantics.'; Topic='bucket'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Inspect'; Name='status'; Usage='capsulenv status'; Summary='Show a compact capsule readiness and ownership summary.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Inspect'; Name='doctor'; Usage='capsulenv doctor'; Summary='Run health checks and show remediation for checks needing attention.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Inspect'; Name='context'; Usage='capsulenv context [--json]'; Summary='Show the resolved runtime context and active ownership mode.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Inspect'; Name='version'; Usage='capsulenv version'; Summary='Print the runtime version.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Lifecycle'; Name='bootstrap'; Usage='capsulenv bootstrap'; Summary='Bootstrap the capsule-owned upstream Scoop runtime.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Lifecycle'; Name='rehydrate'; Usage='capsulenv rehydrate [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]'; Summary='Repair relocation-sensitive capsule projections without replaying package scripts.'; Topic='repair'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Lifecycle'; Name='eject'; Usage='capsulenv eject [--force]'; Summary='Check workspace/process state and prepare the capsule for removal.'; Topic='eject'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Lifecycle'; Name='install-user'; Usage='capsulenv install-user [--force]'; Summary='Synchronize Capsulenv-owned current-user integration.'; Topic='user'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Lifecycle'; Name='restore-user'; Usage='capsulenv restore-user'; Summary='Restore Capsulenv-owned current-user integration state.'; Topic='user'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Workspace'; Name='seed'; Usage='capsulenv seed <powershell|git|scoop|weasel> [...]'; Summary='Import selected host configuration into portable capsule storage.'; Topic='seed'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Workspace'; Name='cache'; Usage='capsulenv cache <paths|init|status|link|unlink|repair> [...]'; Summary='Inspect and manage project cache links.'; Topic='cache'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Workspace'; Name='tools'; Usage='capsulenv tools <status|register|unregister|repair> [...]'; Summary='Inspect and repair uv/Pixi portable workspace relocation.'; Topic='tools'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Workspace'; Name='offline'; Usage='capsulenv offline <status|prefetch> [...]'; Summary='Inspect offline readiness or prefetch installed app artifacts.'; Topic='offline'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Workspace'; Name='drift'; Usage='capsulenv drift'; Summary='Compare installed app versions with local bucket manifests.'; Topic='offline'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Integrations'; Name='browser'; Usage='capsulenv browser <app> [--host] [browser arguments...]'; Summary='Launch a configured Gecko browser through the unified app selector.'; Topic='browser'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Integrations'; Name='bitwarden'; Usage='capsulenv bitwarden <setup|status|restore|start|agent-test> [...]'; Summary='Manage bounded Bitwarden SSH Agent integration.'; Topic='bitwarden'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Integrations'; Name='sing-box'; Usage='capsulenv sing-box <status|check|connect|disconnect> [...]'; Summary='Inspect or control the configured private-network integration.'; Topic='sing-box'; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Help'; Name='help'; Usage='capsulenv help [topic] [action]'; Summary='Show command discovery or focused help.'; Topic=''; Hidden=$false },
        [pscustomobject][ordered]@{ Category='Advanced'; Name='repair-persist'; Usage='capsulenv repair-persist [app...] [--dry-run] [--last]'; Summary='Explicitly repair configured persisted-file relocation targets.'; Topic='repair'; Hidden=$true },
        [pscustomobject][ordered]@{ Category='Advanced'; Name='reset'; Usage='capsulenv reset [app...]'; Summary='Reconcile package/runtime projections; this is not scoop reset.'; Topic='repair'; Hidden=$true },
        [pscustomobject][ordered]@{ Category='Advanced'; Name='init'; Usage='capsulenv init [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]'; Summary='Compatibility entrypoint for explicit full initialization.'; Topic='repair'; Hidden=$true }
    )
    return @($script:CapsulenvCliCommandCatalog)
}

function Get-CapsulenvCliActionCatalog {
    [CmdletBinding()]
    param([string]$Group = '')

    if ($null -eq $script:CapsulenvCliActionCatalog) {
        $script:CapsulenvCliActionCatalog = @(
            [pscustomobject][ordered]@{ Group='app'; Name='plan'; Usage='capsulenv app plan <app|bucket/app> [--json]'; Summary='Resolve dependencies and classify manifest semantics without mutation.' },
            [pscustomobject][ordered]@{ Group='app'; Name='review'; Usage='capsulenv app review <app|bucket/app|user/app|global/app> [--raw|--json]'; Summary='Inspect the exact trusted lifecycle surface, manifests, hashes, and review guidance.' },
            [pscustomobject][ordered]@{ Group='app'; Name='install'; Usage='capsulenv app install <app|bucket/app> [--allow-trusted]'; Summary='Install with PortableSafe, or explicitly delegate TrustedExecution to upstream Scoop.' },
            [pscustomobject][ordered]@{ Group='app'; Name='update'; Usage='capsulenv app update <app|bucket/app|scope/app> [--allow-trusted] [--local]'; Summary='Update one installed app without changing its owner.' },
            [pscustomobject][ordered]@{ Group='app'; Name='list'; Usage='capsulenv app list [app]'; Summary='List installed app inventory, or one app shortcut declarations.' },
            [pscustomobject][ordered]@{ Group='app'; Name='run'; Usage='capsulenv app run <app> ["shortcut name"] [-- runtime arguments...]'; Summary='Launch an installed app through the unified runtime selector.' },
            [pscustomobject][ordered]@{ Group='app'; Name='exec'; Usage='capsulenv app exec capsule/<app> <bin> [-- arguments...]'; Summary='Execute a PortableSafe package bin projection.' },
            [pscustomobject][ordered]@{ Group='bucket'; Name='list'; Usage='capsulenv bucket list'; Summary='List configured upstream Scoop buckets.' },
            [pscustomobject][ordered]@{ Group='bucket'; Name='known'; Usage='capsulenv bucket known'; Summary='List buckets known to upstream Scoop.' },
            [pscustomobject][ordered]@{ Group='bucket'; Name='add'; Usage='capsulenv bucket add <name> [repository]'; Summary='Add one upstream Scoop bucket metadata repository.' },
            [pscustomobject][ordered]@{ Group='bucket'; Name='remove'; Usage='capsulenv bucket remove <name>'; Summary='Remove one configured upstream Scoop bucket.' },
            [pscustomobject][ordered]@{ Group='bucket'; Name='update'; Usage='capsulenv bucket update'; Summary='Refresh Scoop core and configured bucket repositories; installed apps are unchanged.' },
            [pscustomobject][ordered]@{ Group='cache'; Name='paths'; Usage='capsulenv cache paths'; Summary='Show resolved portable cache paths.' },
            [pscustomobject][ordered]@{ Group='cache'; Name='init'; Usage='capsulenv cache init'; Summary='Initialize configured portable cache storage.' },
            [pscustomobject][ordered]@{ Group='cache'; Name='status'; Usage='capsulenv cache status [project-path]'; Summary='Inspect cache-link state for a project.' },
            [pscustomobject][ordered]@{ Group='cache'; Name='link'; Usage='capsulenv cache link <profile> [project-path] [--move] [--junction|--symlink|--hardlink]'; Summary='Create a configured project cache projection.' },
            [pscustomobject][ordered]@{ Group='cache'; Name='unlink'; Usage='capsulenv cache unlink <profile> [project-path] [--restore]'; Summary='Remove a project cache projection and optionally restore content.' },
            [pscustomobject][ordered]@{ Group='cache'; Name='repair'; Usage='capsulenv cache repair [--strict]'; Summary='Repair registered project cache projections.' },
            [pscustomobject][ordered]@{ Group='tools'; Name='status'; Usage='capsulenv tools status'; Summary='Show registered portable tool relocation state.' },
            [pscustomobject][ordered]@{ Group='tools'; Name='register'; Usage='capsulenv tools register <uv|pixi> [workspace]'; Summary='Register a uv or Pixi workspace for relocation repair.' },
            [pscustomobject][ordered]@{ Group='tools'; Name='unregister'; Usage='capsulenv tools unregister <uv|pixi> [workspace]'; Summary='Remove a registered uv or Pixi workspace.' },
            [pscustomobject][ordered]@{ Group='tools'; Name='repair'; Usage='capsulenv tools repair [uv|pixi|all] [--dry-run] [--last] [--strict] [--skip-workspaces] [--include-global]'; Summary='Repair portable tool paths after relocation.' },
            [pscustomobject][ordered]@{ Group='offline'; Name='status'; Usage='capsulenv offline status'; Summary='Show current offline-run readiness.' },
            [pscustomobject][ordered]@{ Group='offline'; Name='prefetch'; Usage='capsulenv offline prefetch [installed-app ...]'; Summary='Populate Scoop download cache for installed apps.' },
            [pscustomobject][ordered]@{ Group='seed'; Name='powershell'; Usage='capsulenv seed powershell [--force]'; Summary='Copy host PowerShell profiles into capsule pwsh persisted profiles.' },
            [pscustomobject][ordered]@{ Group='seed'; Name='git'; Usage='capsulenv seed git [--force] [--include-sensitive]'; Summary='Capture flattened host Git global configuration with bounded sensitive-key handling.' },
            [pscustomobject][ordered]@{ Group='seed'; Name='scoop'; Usage='capsulenv seed scoop [--force] [--apply]'; Summary='Capture a foreign Scoop apps/buckets inventory and optionally apply it.' },
            [pscustomobject][ordered]@{ Group='seed'; Name='weasel'; Usage='capsulenv seed weasel [backup|restore] [--force]'; Summary='Cold-copy or restore registry-confirmed Weasel Rime user data.' },
            [pscustomobject][ordered]@{ Group='bitwarden'; Name='setup'; Usage='capsulenv bitwarden setup [always|never|remember-until-lock]'; Summary='Configure bounded Bitwarden SSH Agent integration.' },
            [pscustomobject][ordered]@{ Group='bitwarden'; Name='status'; Usage='capsulenv bitwarden status'; Summary='Inspect Bitwarden SSH Agent integration state.' },
            [pscustomobject][ordered]@{ Group='bitwarden'; Name='restore'; Usage='capsulenv bitwarden restore [--no-start]'; Summary='Restore Capsulenv-owned Bitwarden integration state.' },
            [pscustomobject][ordered]@{ Group='bitwarden'; Name='start'; Usage='capsulenv bitwarden start'; Summary='Start the configured capsule Bitwarden application.' },
            [pscustomobject][ordered]@{ Group='bitwarden'; Name='agent-test'; Usage='capsulenv bitwarden agent-test'; Summary='Test the resolved SSH Agent endpoint.' }
        )
    }

    if ([string]::IsNullOrWhiteSpace($Group)) {
        return @($script:CapsulenvCliActionCatalog)
    }
    return @($script:CapsulenvCliActionCatalog | Where-Object { [string]$_.Group -eq $Group.ToLowerInvariant() })
}

function Get-CapsulenvCliEditDistance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Right
    )

    $leftText = $Left.ToLowerInvariant()
    $rightText = $Right.ToLowerInvariant()
    if ($leftText -eq $rightText) { return 0 }
    if ($leftText.Length -eq 0) { return $rightText.Length }
    if ($rightText.Length -eq 0) { return $leftText.Length }

    $previous = New-Object 'int[]' ($rightText.Length + 1)
    $current = New-Object 'int[]' ($rightText.Length + 1)
    for ($j = 0; $j -le $rightText.Length; $j++) { $previous[$j] = $j }
    for ($i = 1; $i -le $leftText.Length; $i++) {
        $current[0] = $i
        for ($j = 1; $j -le $rightText.Length; $j++) {
            $cost = if ($leftText[$i - 1] -eq $rightText[$j - 1]) { 0 } else { 1 }
            $delete = $previous[$j] + 1
            $insert = $current[$j - 1] + 1
            $replace = $previous[$j - 1] + $cost
            $current[$j] = [Math]::Min($delete, [Math]::Min($insert, $replace))
        }
        $swap = $previous
        $previous = $current
        $current = $swap
    }
    return [int]$previous[$rightText.Length]
}

function Find-CapsulenvCliSuggestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [Parameter(Mandatory = $true)][string[]]$Candidates
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) { return $null }
    $normalized = $InputText.ToLowerInvariant()
    $best = $null
    $bestDistance = [int]::MaxValue
    foreach ($candidate in @($Candidates | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        $candidateText = ([string]$candidate).ToLowerInvariant()
        if ($candidateText.StartsWith($normalized, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($candidateText, [System.StringComparison]::OrdinalIgnoreCase)) {
            $distance = [Math]::Abs($candidateText.Length - $normalized.Length)
        } else {
            $distance = Get-CapsulenvCliEditDistance -Left $normalized -Right $candidateText
        }
        if ($distance -lt $bestDistance) {
            $bestDistance = $distance
            $best = [string]$candidate
        }
    }

    $maximumDistance = if ($normalized.Length -le 4) { 1 } elseif ($normalized.Length -le 8) { 2 } else { 3 }
    if ($bestDistance -le $maximumDistance) { return $best }
    return $null
}

function Get-CapsulenvCliCommandSuggestion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command)
    $candidates = @((Get-CapsulenvCliCommandCatalog | Where-Object { -not $_.Hidden }).Name)
    return Find-CapsulenvCliSuggestion -InputText $Command -Candidates $candidates
}

function Get-CapsulenvCliActionSuggestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Action
    )
    $candidates = @((Get-CapsulenvCliActionCatalog -Group $Group).Name)
    if ($candidates.Count -eq 0) { return $null }
    return Find-CapsulenvCliSuggestion -InputText $Action -Candidates $candidates
}

function ConvertTo-CapsulenvCliUsageText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Usage)
    $trimmed = $Usage.Trim()
    if ($trimmed -match '^(?i)capsulenv(?:\.cmd)?\s') { return ($trimmed -replace '^(?i)capsulenv\.cmd\s+', 'capsulenv ') }
    return 'capsulenv ' + $trimmed
}

function New-CapsulenvCliUnknownActionError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Id = 'Capsulenv.Cli.UnknownAction'
    )

    $actions = @(Get-CapsulenvCliActionCatalog -Group $Group)
    $remediation = New-Object System.Collections.Generic.List[string]
    $suggestion = Get-CapsulenvCliActionSuggestion -Group $Group -Action $Action
    if (-not [string]::IsNullOrWhiteSpace([string]$suggestion)) {
        $remediation.Add(("Did you mean 'capsulenv {0} {1}'?" -f $Group, $suggestion))
    }
    if ($actions.Count -gt 0) {
        $remediation.Add(('Available actions: {0}' -f (@($actions.Name) -join ', ')))
    }
    $remediation.Add(("Run 'capsulenv help {0}' for details." -f $Group))
    return New-CapsulenvDiagnosticErrorRecord `
        -Id $Id `
        -Message ("Unknown {0} action '{1}'." -f $Group, $Action) `
        -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
        -TargetObject $Action `
        -Remediation $remediation.ToArray()
}

function ConvertTo-CapsulenvCliErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Command
    )

    if (Test-CapsulenvDiagnosticErrorRecord -ErrorRecord $ErrorRecord) { return $ErrorRecord }
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '^Usage:\s*(.+)$') {
        $usage = ConvertTo-CapsulenvCliUsageText -Usage ([string]$Matches[1])
        $topic = $Command
        $catalogMatch = Get-CapsulenvCliCommandCatalog | Where-Object { [string]$_.Name -eq $Command } | Select-Object -First 1
        if ($null -ne $catalogMatch -and -not [string]::IsNullOrWhiteSpace([string]$catalogMatch.Topic)) {
            $topic = [string]$catalogMatch.Topic
        }
        return New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.Cli.Usage' `
            -Message ("Invalid arguments for '{0}'." -f $Command) `
            -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
            -TargetObject $Command `
            -Remediation @(
                ('Usage: {0}' -f $usage),
                ("Run 'capsulenv help {0}' for details." -f $topic)
            ) `
            -Cause $ErrorRecord
    }
    if ($message -match '^Unknown\s+([A-Za-z0-9-]+)\s+action:\s*(.+)$') {
        return New-CapsulenvCliUnknownActionError -Group ([string]$Matches[1]).ToLowerInvariant() -Action ([string]$Matches[2])
    }
    return $ErrorRecord
}

function Write-CapsulenvCliOverview {
    [CmdletBinding()]
    param()

    Write-Host 'capsulenv — portable Windows development environment'
    Write-Host ''
    Write-Host 'Start'
    Write-Host '  capsulenv                  Open the default ShellOnly shell; no separate init step is required.'
    Write-Host '  capsulenv user-shell       Enter explicit persistent User integration.'
    Write-Host ''

    $catalog = @(Get-CapsulenvCliCommandCatalog | Where-Object { -not $_.Hidden -and $_.Category -notin @('Start', 'Help') })
    foreach ($category in @('Packages', 'Inspect', 'Lifecycle', 'Workspace', 'Integrations')) {
        $items = @($catalog | Where-Object { [string]$_.Category -eq $category })
        if ($items.Count -eq 0) { continue }
        Write-Host $category
        foreach ($item in $items) {
            Write-Host ('  {0,-12} {1}' -f ([string]$item.Name), ([string]$item.Summary))
        }
        Write-Host ''
    }
    Write-Host "Help"
    Write-Host "  capsulenv help <topic> [action]"
    Write-Host "  You can also use '<group> help' or '<group> <action> --help'."
}

function Write-CapsulenvCliCommandHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command)

    $item = Get-CapsulenvCliCommandCatalog | Where-Object { [string]$_.Name -eq $Command.ToLowerInvariant() } | Select-Object -First 1
    if ($null -eq $item) { return $false }
    Write-Host ([string]$item.Name)
    Write-Host ('  Usage: {0}' -f ([string]$item.Usage))
    Write-Host ('  {0}' -f ([string]$item.Summary))
    if (-not [string]::IsNullOrWhiteSpace([string]$item.Topic) -and [string]$item.Topic -ne [string]$item.Name) {
        Write-Host ("  More:  capsulenv help {0}" -f ([string]$item.Topic))
    }
    return $true
}

function Write-CapsulenvCliActionHelp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Action
    )

    $item = Get-CapsulenvCliActionCatalog -Group $Group | Where-Object { [string]$_.Name -eq $Action.ToLowerInvariant() } | Select-Object -First 1
    if ($null -eq $item) { return $false }
    Write-Host ('{0} {1}' -f ([string]$item.Group), ([string]$item.Name))
    Write-Host ('  Usage: {0}' -f ([string]$item.Usage))
    Write-Host ('  {0}' -f ([string]$item.Summary))
    return $true
}
