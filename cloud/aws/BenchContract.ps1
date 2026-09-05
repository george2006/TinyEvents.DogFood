Set-StrictMode -Version Latest

function Assert-BenchPhases {
    param([object[]]$Phases)
    if ($Phases.Count -lt 1 -or $Phases.Count -gt 12) { throw 'A phase plan requires 1..12 phases.' }
    $names = @()
    foreach ($phase in $Phases) {
        if ($phase.name -cnotmatch '^[a-z][a-z0-9-]{0,31}$' -or $names -contains $phase.name) { throw 'Phase names must be safe and unique.' }
        $names += $phase.name
        Assert-ScenarioInteger $phase 'durationSeconds' 1 86400
        Assert-ScenarioInteger $phase 'rate' 0 2000
        Assert-ScenarioInteger $phase 'contentBytes' 0 16384
        if ($phase.rate % 20 -ne 0) { throw 'Phase rate must be zero or a multiple of 20.' }
        foreach ($p in $phase.PSObject.Properties.Name) {
            if (@('name','durationSeconds','rate','contentBytes') -cnotcontains $p) { throw "Unknown phase property '$p'." }
        }
    }
    if (($Phases | Measure-Object durationSeconds -Sum).Sum -gt 86400) { throw 'Phase plan exceeds 24 hours.' }
    if (($Phases | Measure-Object rate -Sum).Sum -eq 0) { throw 'At least one phase must publish work.' }
}

function Assert-BenchVariants {
    param($Document)
    if ($Document.variants -isnot [array] -or $Document.variants.Count -lt 1 -or $Document.variants.Count -gt 64) {
        throw 'A bench scenario requires 1..64 explicit variants.'
    }
    $names = @()
    $requiredMinutes = 10
    foreach ($v in $Document.variants) {
        if ($v.name -cnotmatch '^[a-z][a-z0-9-]{0,62}$' -or $names -contains $v.name) { throw 'Variant names must be safe and unique.' }
        $names += $v.name
        Assert-ScenarioInteger $v 'workerCount' 1 24
        Assert-ScenarioInteger $v 'batchSize' 1 100
        Assert-ScenarioInteger $v 'backlog' 0 100000
        Assert-ScenarioInteger $v 'retentionSeconds' 1 86400
        Assert-ScenarioInteger $v 'slowMilliseconds' 0 1000
        Assert-ScenarioInteger $v 'minimumBacklogGrowth' 0 100000
        foreach ($p in @('cleanupEnabled','automaticDiagnostics','requireRateTarget')) {
            if ($v.$p -isnot [bool]) { throw "Variant '$p' must be a boolean." }
        }
        if (@('full','minimal') -cnotcontains $v.monitoring) { throw 'Monitoring must be full or minimal.' }
        if ($v.automaticDiagnostics -and $v.monitoring -ne 'full') { throw 'Diagnostic runs require full monitoring.' }
        if ($v.phases -isnot [array]) { throw 'Phases must be an array.' }
        if ($v.backlog -gt 0) {
            if ($v.phases.Count -gt 0 -or $v.cleanupEnabled -or $v.minimumBacklogGrowth -gt 0) { throw 'Backlog variants require no phases, no cleanup and no growth assertion.' }
            $seconds = 0
        } else {
            Assert-BenchPhases $v.phases
            if ($v.minimumBacklogGrowth -gt 0) {
                foreach ($name in @('baseline','overload','recovery')) {
                    if (@($v.phases | Where-Object name -CEQ $name).Count -ne 1) { throw 'Growth assertions require baseline, overload and recovery phases.' }
                }
                if (($v.phases | Where-Object name -CEQ 'recovery').rate -ne 0) { throw 'Recovery must stop input so drain can be verified.' }
            }
            $seconds = ($v.phases | Measure-Object durationSeconds -Sum).Sum
        }
        foreach ($p in $v.PSObject.Properties.Name) {
            if (@('name','workerCount','batchSize','backlog','retentionSeconds','slowMilliseconds',
                'minimumBacklogGrowth','cleanupEnabled','automaticDiagnostics','requireRateTarget','monitoring','phases') -cnotcontains $p) {
                throw "Unknown variant property '$p'."
            }
        }
        # Preload/build, staggered managed startup, bounded drain, collector cleanup,
        # post-run SQL and uploads. Declared maximum is a kill deadline, not a forecast.
        $requiredMinutes += [Math]::Ceiling($seconds / 60) + 25 + $v.workerCount
    }
    if ($Document.estimatedMaximumMinutes -lt $requiredMinutes) { throw "Bench scenario needs a runtime budget of at least $requiredMinutes minutes." }
}
