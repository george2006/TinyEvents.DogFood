function Get-TES01MigrationObservation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect-migrations

    if ($LASTEXITCODE -ne 0) {
        throw "Migration observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Stop-TES01Migrators {
    param([pscustomobject[]]$Migrators)

    foreach ($migrator in $Migrators) {
        $process = $migrator.Process

        if (!$process.HasExited) {
            Stop-Process -Id $process.Id
            $process.WaitForExit()
        }
    }
}

function Invoke-TES01ConcurrentApplicationMigrations {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-S01"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("prepare") $scenarioDirectory "prepare"
    $beforeMigration = Get-TES01MigrationObservation $Assembly
    $beforeMigration |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "before-migration.json")

    $migratorCount = 8
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $migrators = @(
        foreach ($migratorNumber in 1..$migratorCount) {
            Start-LoggedDotNetProcess `
                $Assembly `
                @("migrate") `
                $scenarioDirectory `
                "migrator-$migratorNumber"
        }
    )

    try {
        foreach ($migrator in $migrators) {
            Complete-LoggedProcess $migrator 30000
        }

        $allMigratorsCompleted = $true
    }
    finally {
        Stop-TES01Migrators $migrators
        $stopwatch.Stop()
    }

    $afterMigration = Get-TES01MigrationObservation $Assembly
    $afterMigration |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "after-migration.json")

    $history = @($afterMigration.History)
    $migration = $history | Select-Object -First 1
    $migrationLogs = Join-Path $scenarioDirectory "migrator-*.stdout.log"
    $applyingMigrators = @(
        Select-String -Path $migrationLogs -Pattern "[1401]" -SimpleMatch)
    $currentSchemaObservers = @(
        Select-String -Path $migrationLogs -Pattern "[1402]" -SimpleMatch)
    $databaseWasFresh =
        !$beforeMigration.OutboxTableExists -and
        !$beforeMigration.HistoryTableExists -and
        @($beforeMigration.History).Count -eq 0
    $historyIsExact =
        $afterMigration.OutboxTableExists -and
        $afterMigration.HistoryTableExists -and
        $history.Count -eq 1 -and
        $null -ne $migration -and
        $migration.Version -eq 1 -and
        $migration.Name -eq "001_CreateTinyOutbox" -and
        $migration.Checksum.Length -eq 64 -and
        $null -ne $migration.AppliedAtUtc
    $logsProveSerialization =
        $applyingMigrators.Count -eq 1 -and
        $currentSchemaObservers.Count -eq ($migratorCount - 1)
    $passed =
        $databaseWasFresh -and
        $allMigratorsCompleted -and
        $historyIsExact -and
        $logsProveSerialization

    $result = [ordered]@{
        Scenario = "TE-S01"
        MigratorProcesses = $migratorCount
        DurationMilliseconds = $stopwatch.ElapsedMilliseconds
        DatabaseWasFresh = $databaseWasFresh
        AllMigratorsCompleted = $allMigratorsCompleted
        HistoryIsExact = $historyIsExact
        ApplyingMigrators = $applyingMigrators.Count
        CurrentSchemaObservers = $currentSchemaObservers.Count
        LogsProveSerialization = $logsProveSerialization
        ObservationBeforeMigration = $beforeMigration
        ObservationAfterMigration = $afterMigration
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-SchemaScenarios.ps1"
    & $runner -Scenario "TE-S01"
}
