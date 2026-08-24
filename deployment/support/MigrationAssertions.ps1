function Test-TinyEventsCurrentSchema {
    param([pscustomobject]$Observation)

    return (
        $Observation.OutboxTableExists -and
        $Observation.HistoryTableExists -and
        (Test-TinyEventsCurrentMigrationHistory $Observation.History))
}

function Test-TinyEventsCurrentMigrationHistory {
    param([object[]]$History)

    $migrations = @($History)
    $expectedMigrations = @(
        [pscustomobject]@{
            Version = 1
            Name = "001_CreateTinyOutbox"
        },
        [pscustomobject]@{
            Version = 2
            Name = "002_AddProcessedCleanupIndex"
        })

    if ($migrations.Count -ne $expectedMigrations.Count) {
        return $false
    }

    for ($index = 0; $index -lt $expectedMigrations.Count; $index++) {
        $migration = $migrations[$index]
        $expectedMigration = $expectedMigrations[$index]
        $migrationIsExact =
            $migration.Version -eq $expectedMigration.Version -and
            $migration.Name -eq $expectedMigration.Name -and
            $migration.Checksum.Length -eq 64 -and
            $null -ne $migration.AppliedAtUtc

        if (!$migrationIsExact) {
            return $false
        }
    }

    return $true
}
