function Invoke-TED03DatabaseDisappearsDuringConsumer {
    param(
        [string]$Assembly,
        [string]$ComposeFile,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-D03"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-D03", "1") $scenarioDirectory "publish"

    $workerId = "TE-D03-worker"
    $worker = Start-Worker $Assembly $workerId 10000 0 $scenarioDirectory
    $workerLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
    $sqlServerRestored = $false

    try {
        $claimed = Wait-ForClaim $Assembly $worker $workerId
        Save-Observation $claimed $scenarioDirectory "consumer-active"
        $originalClaimExpiry = [DateTimeOffset]$claimed.EarliestClaimExpiresAtUtc

        Stop-SqlServer $ComposeFile

        Wait-ForLogText `
            $worker `
            $workerLog `
            "processing iteration failed" `
            "Active consumer worker"

        Start-SqlServer $ComposeFile
        $sqlServerRestored = $true

        $completed = Wait-ForCompletion $Assembly $worker $workerId
        Save-Observation $completed $scenarioDirectory "recovered"

        Wait-ForLogText `
            $worker `
            $workerLog `
            "TinyEvents worker recovered after" `
            "Active consumer worker"

        $workerSurvived = -not $worker.HasExited
    }
    finally {
        if (!$sqlServerRestored) {
            Start-SqlServer $ComposeFile
        }

        Stop-Worker $worker
    }

    $failureCounts = Get-WorkerFailureLogCounts $workerLog
    $recoveredClaimExpiry = [DateTimeOffset]$completed.EarliestClaimExpiresAtUtc
    $leaseWasReclaimed = $recoveredClaimExpiry -gt $originalClaimExpiry
    $processEffects = $completed.ProcessEffects.PSObject.Properties[[string]$worker.Id]
    $sameProcessCompletedAfterRecovery =
        @($completed.ProcessEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $processEffects -and
        $processEffects.Value -eq 1
    $failedAttemptWasNotPersisted = $completed.FailedAttempts -eq 0
    $passed =
        $workerSurvived -and
        $failureCounts -contains 1 -and
        $leaseWasReclaimed -and
        $sameProcessCompletedAfterRecovery -and
        $failedAttemptWasNotPersisted -and
        (Test-WorkerOwnsResult $completed $workerId)

    $result = [ordered]@{
        Scenario = "TE-D03"
        Worker = $workerId
        OriginalClaimExpiry = $originalClaimExpiry.ToString("O")
        RecoveredClaimExpiry = $recoveredClaimExpiry.ToString("O")
        LeaseWasReclaimed = $leaseWasReclaimed
        FailedAttemptWasNotPersisted = $failedAttemptWasNotPersisted
        SameProcessCompletedAfterRecovery = $sameProcessCompletedAfterRecovery
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
    & $runner -Scenario "TE-D03"
}
