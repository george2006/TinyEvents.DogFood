function Invoke-TED04DatabaseDisappearsWhileMarkingProcessed {
    param(
        [string]$Assembly,
        [pscustomobject]$Database,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-D04"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-D04", "1") $scenarioDirectory "publish"

    $workerId = "TE-D04-worker"
    $worker = Start-Worker $Assembly $workerId 0 10000 $scenarioDirectory
    $workerLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
    $databaseRestored = $false

    try {
        $effectBeforeCompletion = Wait-ForEffectBeforeCompletion $Assembly $worker $workerId
        Save-Observation $effectBeforeCompletion $scenarioDirectory "effect-before-outage"
        $originalClaimExpiry = [DateTimeOffset]$effectBeforeCompletion.EarliestClaimExpiresAtUtc

        Stop-DogfoodDatabase $Database

        Wait-ForLogText `
            $worker `
            $workerLog `
            "processing iteration failed" `
            "Completion worker"

        Start-DogfoodDatabase $Database
        $databaseRestored = $true

        $completed = Wait-ForDuplicateCompletion $Assembly $worker $workerId
        Save-Observation $completed $scenarioDirectory "redelivered"

        Wait-ForLogText `
            $worker `
            $workerLog `
            "TinyEvents worker recovered after" `
            "Completion worker"

        $workerSurvived = -not $worker.HasExited
    }
    finally {
        if (!$databaseRestored) {
            Start-DogfoodDatabase $Database
        }

        Stop-Worker $worker
    }

    $failureCounts = Get-WorkerFailureLogCounts $workerLog
    $recoveredClaimExpiry = [DateTimeOffset]$completed.EarliestClaimExpiresAtUtc
    $leaseWasReclaimed = $recoveredClaimExpiry -gt $originalClaimExpiry
    $processEffects = $completed.ProcessEffects.PSObject.Properties[[string]$worker.Id]
    $sameProcessRecordedBothEffects =
        @($completed.ProcessEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $processEffects -and
        $processEffects.Value -eq 2
    $failedAttemptWasNotPersisted = $completed.FailedAttempts -eq 0
    $passed =
        $workerSurvived -and
        $failureCounts -contains 1 -and
        $leaseWasReclaimed -and
        $sameProcessRecordedBothEffects -and
        $failedAttemptWasNotPersisted -and
        $completed.BusinessOperations -eq 1 -and
        $completed.OutboxMessages -eq 1 -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq 1 -and
        $completed.FailedMessages -eq 0 -and
        $completed.Effects -eq 2 -and
        $completed.DuplicateEffects -eq 1

    $result = [ordered]@{
        Scenario = "TE-D04"
        Worker = $workerId
        OriginalClaimExpiry = $originalClaimExpiry.ToString("O")
        RecoveredClaimExpiry = $recoveredClaimExpiry.ToString("O")
        LeaseWasReclaimed = $leaseWasReclaimed
        FailedAttemptWasNotPersisted = $failedAttemptWasNotPersisted
        SameProcessRecordedBothEffects = $sameProcessRecordedBothEffects
        LoggedFailureCounts = $failureCounts
        WorkerSurvived = $workerSurvived
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-DatabaseRecovery.ps1"
    & $runner -Scenario "TE-D04"
}
