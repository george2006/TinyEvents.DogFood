function Get-TES03MigrationObservation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect-migrations

    if ($LASTEXITCODE -ne 0) {
        throw "Migration observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Get-TES03InterruptionObservation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect-migration-interruption

    if ($LASTEXITCODE -ne 0) {
        throw "Migration interruption observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Wait-TES03ForBlockedMigration {
    param(
        [string]$Assembly,
        [TimeSpan]$Timeout
    )

    $deadline = [DateTimeOffset]::UtcNow.Add($Timeout)

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $observation = Get-TES03InterruptionObservation $Assembly
        $migrationIsBlockedWithItsLock =
            $observation.IsInstalled -and
            $observation.BlockedMigratorCount -eq 1 -and
            $observation.BlockedMigratorsHoldingLock -eq 1 -and
            $observation.MigrationLockHolderCount -eq 1

        if ($migrationIsBlockedWithItsLock) {
            return $observation
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Migration did not reach the database-controlled interruption within $Timeout."
}

function Wait-TES03ForMigrationLockRelease {
    param(
        [string]$Assembly,
        [TimeSpan]$Timeout
    )

    $deadline = [DateTimeOffset]::UtcNow.Add($Timeout)

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $observation = Get-TES03InterruptionObservation $Assembly

        if ($observation.MigrationLockHolderCount -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 200
    }

    throw "The database did not release the interrupted migration lock within $Timeout."
}

function Test-TES03FinalMigrationState {
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
        $migration.Checksum.Length -eq 64 -and
        $null -ne $migration.AppliedAtUtc)
}

function Get-TES03InterruptedStateClassification {
    param([pscustomobject]$Observation)

    $history = @($Observation.History)
    $migrationWasNotCommitted =
        !$Observation.OutboxTableExists -and
        $history.Count -eq 0

    if ($migrationWasNotCommitted) {
        if ($Observation.HistoryTableExists) {
            return "EmptyHistoryInfrastructure"
        }

        return "NoMigrationInfrastructure"
    }

    if (Test-TES03FinalMigrationState $Observation) {
        return "CommittedMigration"
    }

    return "Inconsistent"
}

function Invoke-TES03InterruptedMigration {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-S03"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("prepare") $scenarioDirectory "prepare"
    $beforeMigration = Get-TES03MigrationObservation $Assembly
    $migrationProcess = $null
    $processOutputSaved = $false

    try {
        Invoke-LoggedProcess `
            $Assembly `
            @("install-migration-interruption") `
            $scenarioDirectory `
            "install-interruption"
        $installedInterruption = Get-TES03InterruptionObservation $Assembly
        $migrationProcess = Start-LoggedDotNetProcess `
            $Assembly `
            @("migrate") `
            $scenarioDirectory `
            "interrupted-migrator"
        $blockedInterruption = Wait-TES03ForBlockedMigration `
            $Assembly `
            ([TimeSpan]::FromSeconds(30))
        $killedProcessExitCode = Stop-LoggedProcess $migrationProcess
        $processOutputSaved = $true
        $afterLockRelease = Wait-TES03ForMigrationLockRelease `
            $Assembly `
            ([TimeSpan]::FromSeconds(30))
        $afterProcessDeath = Get-TES03MigrationObservation $Assembly
    }
    finally {
        if ($null -ne $migrationProcess -and !$processOutputSaved) {
            $null = Stop-LoggedProcess $migrationProcess
        }

        Invoke-LoggedProcess `
            $Assembly `
            @("remove-migration-interruption") `
            $scenarioDirectory `
            "remove-interruption"
    }

    $removedInterruption = Get-TES03InterruptionObservation $Assembly
    Invoke-LoggedProcess $Assembly @("migrate") $scenarioDirectory "recovery-migrator"
    $afterRecovery = Get-TES03MigrationObservation $Assembly

    $beforeMigrationWasFresh =
        !$beforeMigration.OutboxTableExists -and
        !$beforeMigration.HistoryTableExists -and
        @($beforeMigration.History).Count -eq 0
    $interruptionWasInstalled =
        $installedInterruption.IsInstalled -and
        $installedInterruption.BlockedMigratorCount -eq 0 -and
        $installedInterruption.BlockedMigratorsHoldingLock -eq 0 -and
        $installedInterruption.MigrationLockHolderCount -eq 0
    $migrationWasInterruptedInsideDdl =
        $blockedInterruption.IsInstalled -and
        $blockedInterruption.BlockedMigratorCount -eq 1 -and
        $blockedInterruption.BlockedMigratorsHoldingLock -eq 1 -and
        $blockedInterruption.MigrationLockHolderCount -eq 1
    $interruptedProcessWasTerminated = $killedProcessExitCode -ne 0
    $migrationLockWasReleased =
        $afterLockRelease.MigrationLockHolderCount -eq 0
    $interruptedStateClassification =
        Get-TES03InterruptedStateClassification $afterProcessDeath
    $interruptedStateWasResumable =
        $interruptedStateClassification -ne "Inconsistent"
    $interruptionWasRemoved =
        !$removedInterruption.IsInstalled -and
        $removedInterruption.BlockedMigratorCount -eq 0 -and
        $removedInterruption.BlockedMigratorsHoldingLock -eq 0 -and
        $removedInterruption.MigrationLockHolderCount -eq 0
    $recoveryMigrationIsExact =
        Test-TES03FinalMigrationState $afterRecovery
    $passed =
        $beforeMigrationWasFresh -and
        $interruptionWasInstalled -and
        $migrationWasInterruptedInsideDdl -and
        $interruptedProcessWasTerminated -and
        $migrationLockWasReleased -and
        $interruptedStateWasResumable -and
        $interruptionWasRemoved -and
        $recoveryMigrationIsExact

    $result = [ordered]@{
        Scenario = "TE-S03"
        BeforeMigrationWasFresh = $beforeMigrationWasFresh
        InterruptionWasInstalled = $interruptionWasInstalled
        MigrationWasInterruptedInsideDdl = $migrationWasInterruptedInsideDdl
        BlockedMigratorCount = $blockedInterruption.BlockedMigratorCount
        BlockedMigratorsHoldingLock =
            $blockedInterruption.BlockedMigratorsHoldingLock
        MigrationLockHolderCount =
            $blockedInterruption.MigrationLockHolderCount
        InterruptedProcessExitCode = $killedProcessExitCode
        InterruptedProcessWasTerminated = $interruptedProcessWasTerminated
        MigrationLockWasReleased = $migrationLockWasReleased
        InterruptedStateClassification = $interruptedStateClassification
        InterruptedStateWasResumable = $interruptedStateWasResumable
        InterruptionWasRemoved = $interruptionWasRemoved
        RecoveryMigrationIsExact = $recoveryMigrationIsExact
        ObservationBeforeMigration = $beforeMigration
        ObservationAfterProcessDeath = $afterProcessDeath
        ObservationAfterRecovery = $afterRecovery
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-SchemaScenarios.ps1"
    & $runner -Scenario "TE-S03"
}
