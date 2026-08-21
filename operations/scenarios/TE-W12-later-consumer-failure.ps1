function Invoke-TEW12LaterConsumerFailure {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W12"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @("publish-multi-consumer", "TE-W12", "1") `
        $scenarioDirectory `
        "publish"

    $workerId = "TE-W12-worker"
    $worker = Start-FailingWorker $Assembly $workerId "TE-W12" 1 $scenarioDirectory

    try {
        $scheduledRetry = Wait-ForLaterConsumerRetry $Assembly $worker $workerId
        Save-Observation $scheduledRetry $scenarioDirectory "later-consumer-retry"

        $retryAtUtc = [DateTimeOffset]$scheduledRetry.EarliestNextAttemptAtUtc
        $completed = Wait-ForDuplicateCompletion $Assembly $worker $workerId
        Save-Observation $completed $scenarioDirectory "completed"

        $secondAttemptAtUtc = [DateTimeOffset]$completed.LatestConsumerAttemptAtUtc
        $retryRespectedBoundary = $secondAttemptAtUtc -ge $retryAtUtc
        $workerSurvived = -not $worker.HasExited
        $passed =
            $retryRespectedBoundary -and
            $workerSurvived -and
            (Test-LaterConsumerRetryResult $completed $workerId)
    }
    finally {
        Stop-Worker $worker
    }

    $result = [ordered]@{
        Scenario = "TE-W12"
        Worker = $workerId
        RetryRespectedBoundary = $retryRespectedBoundary
        EarlierConsumerInvocations = $completed.Effects
        DuplicateEarlierInvocations = $completed.DuplicateEffects
        WorkerSurvived = $workerSurvived
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W12"
}
