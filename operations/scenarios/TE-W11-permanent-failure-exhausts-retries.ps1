function Invoke-TEW11PermanentFailureExhaustsRetries {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W11"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W11-permanent", "1") $scenarioDirectory "publish-permanent"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W11-unrelated", "1") $scenarioDirectory "publish-unrelated"

    $workerId = "TE-W11-worker"
    $worker = Start-FailingWorker $Assembly $workerId "TE-W11-permanent" 3 $scenarioDirectory

    try {
        $firstRetry = Wait-ForRetryAttemptState $Assembly $worker $workerId 1
        Save-Observation $firstRetry $scenarioDirectory "first-retry"

        $firstRetryAtUtc = [DateTimeOffset]$firstRetry.EarliestNextAttemptAtUtc
        $unrelatedMessageContinued =
            $firstRetry.ProcessedMessages -eq 1 -and
            $firstRetry.Effects -eq 1

        $secondRetry = Wait-ForRetryAttemptState $Assembly $worker $workerId 2
        Save-Observation $secondRetry $scenarioDirectory "second-retry"

        $secondAttemptAtUtc = [DateTimeOffset]$secondRetry.LatestConsumerAttemptAtUtc
        $secondRetryAtUtc = [DateTimeOffset]$secondRetry.EarliestNextAttemptAtUtc
        $secondAttemptRespectedBoundary = $secondAttemptAtUtc -ge $firstRetryAtUtc

        $failed = Wait-ForPermanentFailure $Assembly $worker $workerId
        Save-Observation $failed $scenarioDirectory "terminal-failure"

        $thirdAttemptAtUtc = [DateTimeOffset]$failed.LatestConsumerAttemptAtUtc
        $thirdAttemptRespectedBoundary = $thirdAttemptAtUtc -ge $secondRetryAtUtc
        $workerSurvived = -not $worker.HasExited
        $passed =
            $unrelatedMessageContinued -and
            $secondAttemptRespectedBoundary -and
            $thirdAttemptRespectedBoundary -and
            $workerSurvived -and
            (Test-PermanentFailureResult $failed $workerId)
    }
    finally {
        Stop-Worker $worker
    }

    $result = [ordered]@{
        Scenario = "TE-W11"
        Worker = $workerId
        UnrelatedMessageContinued = $unrelatedMessageContinued
        SecondAttemptRespectedBoundary = $secondAttemptRespectedBoundary
        ThirdAttemptRespectedBoundary = $thirdAttemptRespectedBoundary
        WorkerSurvived = $workerSurvived
        Observation = $failed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W11"
}
