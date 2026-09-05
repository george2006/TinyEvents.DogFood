Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'BenchContract.ps1')

function Assert-ScenarioInteger {
    param($Document, [string]$Name, [long]$Minimum, [long]$Maximum)
    $property = $Document.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [ValueType] -or
        $property.Value -is [bool] -or $property.Value -is [double] -or
        $property.Value -is [decimal] -or $property.Value -lt $Minimum -or $property.Value -gt $Maximum) {
        throw "Scenario '$Name' must be an integer between $Minimum and $Maximum."
    }
}

function Read-LabScenario {
    param([Parameter(Mandatory)][string]$Path)
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $document -or $document -is [array]) { throw 'Scenario must be one JSON object.' }
    Assert-ScenarioInteger $document 'schemaVersion' 1 1
    foreach ($name in @('name', 'runner', 'storageProvider')) {
        if ($null -eq $document.PSObject.Properties[$name] -or $document.$name -isnot [string]) {
            throw "Scenario '$name' must be a string."
        }
    }
    if ($document.name -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}$') { throw 'Invalid scenario name.' }
    if ($document.storageProvider -cne 'PostgreSql') { throw 'Cloud scenarios support PostgreSql only.' }
    Assert-ScenarioInteger $document 'estimatedMaximumMinutes' 1 1740
    $allowed = @('schemaVersion', 'name', 'description', 'runner', 'storageProvider', 'estimatedMaximumMinutes')
    switch -CaseSensitive ($document.runner) {
        'bench' {
            $allowed += 'variants'
            Assert-BenchVariants $document
            $minimumMinutes = 1
        }
        'cloud-smoke' {
            $allowed += @('messageCount', 'repetitions')
            Assert-ScenarioInteger $document 'messageCount' 1 10000
            Assert-ScenarioInteger $document 'repetitions' 1 1
            $minimumMinutes = 15
        }
        'memory-soak' {
            $allowed += @('durationSeconds', 'rate', 'workerCount', 'windowSeconds', 'settlementSeconds')
            Assert-ScenarioInteger $document 'durationSeconds' 1 86400
            Assert-ScenarioInteger $document 'rate' 20 2000
            if ($document.rate % 20 -ne 0) { throw 'Scenario rate must be a multiple of 20 for the exact work mix.' }
            Assert-ScenarioInteger $document 'workerCount' 1 24
            Assert-ScenarioInteger $document 'windowSeconds' 1 10
            Assert-ScenarioInteger $document 'settlementSeconds' 15 600
            # Startup, drain, summaries and two bounded uploads must fit too.
            $minimumMinutes = [Math]::Ceiling(($document.durationSeconds + $document.settlementSeconds) / 60) + 15
        }
        'worker-scaling' {
            $allowed += @('backlog', 'workerCounts', 'repetitions')
            Assert-ScenarioInteger $document 'backlog' 100 100000
            Assert-ScenarioInteger $document 'repetitions' 1 10
            if ($null -eq $document.PSObject.Properties['workerCounts'] -or
                $document.workerCounts -isnot [array] -or $document.workerCounts.Count -lt 2 -or
                $document.workerCounts.Count -gt 24 -or $document.workerCounts[0] -ne 1) {
                throw 'Worker counts must be an ordered array starting with the one-worker baseline.'
            }
            $previous = 0
            foreach ($count in $document.workerCounts) {
                Assert-ScenarioInteger ([pscustomobject]@{ count = $count }) 'count' 1 24
                if ($count -le $previous) { throw 'Worker counts must be strictly increasing without duplicates.' }
                $previous = $count
            }
            $minimumMinutes = $document.workerCounts.Count * $document.repetitions * 5 + 15
        }
        default { throw "Unknown cloud scenario runner '$($document.runner)'." }
    }
    foreach ($property in $document.PSObject.Properties) {
        if ($allowed -cnotcontains $property.Name) { throw "Unknown scenario property '$($property.Name)'." }
    }
    if ($document.estimatedMaximumMinutes -lt $minimumMinutes) {
        throw "Scenario duration budget must be at least $minimumMinutes minutes, including collection and upload."
    }
    return $document
}

function Assert-ScenarioFitsLab {
    param($Scenario, [DateTimeOffset]$ExpiresAt, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    $requiredMinutes = $Scenario.estimatedMaximumMinutes + 5
    if ($ExpiresAt -le $Now.AddMinutes($requiredMinutes)) {
        throw "Scenario needs $requiredMinutes minutes before lab expiry, including a five-minute admission margin. Use a fresh lab; expiry is not extended automatically."
    }
}
