function Invoke-TEW10TransientFailureRecovers {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W10"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W10-retry", "1") $scenarioDirectory "publish-retry"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W10-unrelated", "1") $scenarioDirectory "publish-unrelated"

    $workerId = "TE-W10-worker"
    $worker = Start-Worker $Assembly $workerId 0 0 $scenarioDirectory

    try {
        $firstRetry = Wait-ForTransientRetryState $Assembly $worker $workerId 1
        Save-Observation $firstRetry $scenarioDirectory "first-retry"

        $firstRetryAtUtc = [DateTimeOffset]$firstRetry.EarliestNextAttemptAtUtc
        $unrelatedMessageContinued =
            $firstRetry.ProcessedMessages -eq 1 -and
            $firstRetry.Effects -eq 1

        $secondRetry = Wait-ForTransientRetryState $Assembly $worker $workerId 2
        Save-Observation $secondRetry $scenarioDirectory "second-retry"

        $secondAttemptAtUtc = [DateTimeOffset]$secondRetry.LatestConsumerAttemptAtUtc
        $secondRetryAtUtc = [DateTimeOffset]$secondRetry.EarliestNextAttemptAtUtc
        $secondAttemptRespectedBoundary = $secondAttemptAtUtc -ge $firstRetryAtUtc

        $completed = Wait-ForTransientRecovery $Assembly $worker $workerId
        Save-Observation $completed $scenarioDirectory "completed"

        $thirdAttemptAtUtc = [DateTimeOffset]$completed.LatestConsumerAttemptAtUtc
        $thirdAttemptRespectedBoundary = $thirdAttemptAtUtc -ge $secondRetryAtUtc
        $workerSurvived = -not $worker.HasExited
        $passed =
            $unrelatedMessageContinued -and
            $secondAttemptRespectedBoundary -and
            $thirdAttemptRespectedBoundary -and
            $workerSurvived -and
            (Test-TransientRecoveryResult $completed $workerId)
    }
    finally {
        Stop-Worker $worker
    }

    $result = [ordered]@{
        Scenario = "TE-W10"
        Worker = $workerId
        UnrelatedMessageContinued = $unrelatedMessageContinued
        SecondAttemptRespectedBoundary = $secondAttemptRespectedBoundary
        ThirdAttemptRespectedBoundary = $thirdAttemptRespectedBoundary
        WorkerSurvived = $workerSurvived
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W10"
}
