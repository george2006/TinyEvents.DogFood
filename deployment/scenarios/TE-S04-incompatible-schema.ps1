function Get-TES04MigrationObservation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect-migrations

    if ($LASTEXITCODE -ne 0) {
        throw "Migration observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Test-TES04CurrentSchema {
    param([pscustomobject]$Observation)

    $history = @($Observation.History)
    $migration = $history | Select-Object -First 1

    return (
        $Observation.OutboxTableExists -and
        $Observation.HistoryTableExists -and
        $history.Count -eq 1 -and
        $null -ne $migration -and
        $migration.Version -eq 1 -and
        $migration.Name -eq "001_CreateTinyOutbox" -and
        $migration.Checksum.Length -eq 64)
}

function Invoke-TES04MissingSchemaCase {
    param(
        [string]$Assembly,
        [string]$ScenarioDirectory
    )

    Invoke-LoggedProcess $Assembly @("prepare") $ScenarioDirectory "missing-prepare"
    $beforeMigration = Get-TES04MigrationObservation $Assembly
    Invoke-LoggedProcess $Assembly @("migrate") $ScenarioDirectory "missing-migrate"
    $afterMigration = Get-TES04MigrationObservation $Assembly

    $wasMissing =
        !$beforeMigration.OutboxTableExists -and
        !$beforeMigration.HistoryTableExists -and
        @($beforeMigration.History).Count -eq 0
    $wasCreated = Test-TES04CurrentSchema $afterMigration

    return [ordered]@{
        SchemaWasMissing = $wasMissing
        SchemaWasCreated = $wasCreated
        AcceptancePassed = $wasMissing -and $wasCreated
        BeforeMigration = $beforeMigration
        AfterMigration = $afterMigration
    }
}

function Invoke-TES04PartialSchemaCase {
    param(
        [string]$Assembly,
        [string]$ScenarioDirectory
    )

    Invoke-LoggedProcess $Assembly @("reset") $ScenarioDirectory "partial-reset"
    Invoke-LoggedProcess `
        $Assembly `
        @("remove-outbox-table") `
        $ScenarioDirectory `
        "partial-remove-outbox"
    $beforeMigration = Get-TES04MigrationObservation $Assembly
    $exitCode = Invoke-LoggedProcessForExitCode `
        $Assembly `
        @("migrate") `
        $ScenarioDirectory `
        "partial-migrate"
    $afterMigration = Get-TES04MigrationObservation $Assembly
    $standardError = Get-Content `
        (Join-Path $ScenarioDirectory "partial-migrate.stderr.log") `
        -Raw

    $wasPartial =
        !$beforeMigration.OutboxTableExists -and
        $beforeMigration.HistoryTableExists -and
        @($beforeMigration.History).Count -eq 1
    $wasRejected = $exitCode -ne 0
    $diagnosticWasActionable =
        $standardError -match "TinyOutbox" -and
        $standardError -match "missing|does not exist|inconsistent"

    return [ordered]@{
        SchemaWasPartial = $wasPartial
        MigrationExitCode = $exitCode
        PartialSchemaWasRejected = $wasRejected
        DiagnosticWasActionable = $diagnosticWasActionable
        AcceptancePassed =
            $wasPartial -and
            $wasRejected -and
            $diagnosticWasActionable
        BeforeMigration = $beforeMigration
        AfterMigration = $afterMigration
    }
}

function Invoke-TES04ChecksumConflictCase {
    param(
        [string]$Assembly,
        [string]$ScenarioDirectory
    )

    $conflictingChecksum = "0" * 64
    Invoke-LoggedProcess $Assembly @("reset") $ScenarioDirectory "checksum-reset"
    Invoke-LoggedProcess `
        $Assembly `
        @("replace-migration-checksum", $conflictingChecksum) `
        $ScenarioDirectory `
        "checksum-replace"
    $beforeMigration = Get-TES04MigrationObservation $Assembly
    $exitCode = Invoke-LoggedProcessForExitCode `
        $Assembly `
        @("migrate") `
        $ScenarioDirectory `
        "checksum-migrate"
    $standardError = Get-Content `
        (Join-Path $ScenarioDirectory "checksum-migrate.stderr.log") `
        -Raw

    $conflictWasPresent =
        @($beforeMigration.History).Count -eq 1 -and
        $beforeMigration.History[0].Checksum -eq $conflictingChecksum
    $wasRejected = $exitCode -ne 0
    $diagnosticWasActionable =
        $standardError -match "checksum" -and
        $standardError -match "version 1"

    return [ordered]@{
        ChecksumConflictWasPresent = $conflictWasPresent
        MigrationExitCode = $exitCode
        ChecksumConflictWasRejected = $wasRejected
        DiagnosticWasActionable = $diagnosticWasActionable
        AcceptancePassed =
            $conflictWasPresent -and
            $wasRejected -and
            $diagnosticWasActionable
        BeforeMigration = $beforeMigration
    }
}

function Invoke-TES04IncompatibleSchema {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-S04"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $missingSchema = Invoke-TES04MissingSchemaCase `
        $Assembly `
        $scenarioDirectory
    $partialSchema = Invoke-TES04PartialSchemaCase `
        $Assembly `
        $scenarioDirectory
    $checksumConflict = Invoke-TES04ChecksumConflictCase `
        $Assembly `
        $scenarioDirectory
    $passed =
        $missingSchema.AcceptancePassed -and
        $partialSchema.AcceptancePassed -and
        $checksumConflict.AcceptancePassed

    $result = [ordered]@{
        Scenario = "TE-S04"
        MissingSchema = $missingSchema
        PartialSchema = $partialSchema
        ChecksumConflict = $checksumConflict
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-SchemaScenarios.ps1"
    & $runner -Scenario "TE-S04"
}
