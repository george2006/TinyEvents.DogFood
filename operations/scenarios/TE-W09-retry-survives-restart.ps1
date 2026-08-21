function Invoke-TEW09RetrySurvivesRestart {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W09"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W09", "1") $scenarioDirectory "publish"

    $initialWorkerId = "TE-W09-initial-worker"
    $recoveryWorkerId = "TE-W09-recovery-worker"
    $initialWorker = Start-Worker $Assembly $initialWorkerId 0 0 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $scheduledRetry = Wait-ForScheduledRetry $Assembly $initialWorker $initialWorkerId
        Save-Observation $scheduledRetry $scenarioDirectory "retry-scheduled"
        Stop-Worker $initialWorker

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 0 $scenarioDirectory
        Start-Sleep -Milliseconds 500

        if ($recoveryWorker.HasExited) {
            throw "Recovery worker exited before the retry became eligible. Exit code: $($recoveryWorker.ExitCode)."
        }

        $beforeEligibility = Get-Observation -Assembly $Assembly
        Save-Observation $beforeEligibility $scenarioDirectory "protected-before-retry"

        $retryAtUtc = [DateTimeOffset]$scheduledRetry.EarliestNextAttemptAtUtc
        $databaseNow = [DateTimeOffset]$beforeEligibility.DatabaseUtcNow
        $recoveryAttemptBeforeEligibility =
            $beforeEligibility.WorkerAttempts.PSObject.Properties[$recoveryWorkerId]
        $retryWasProtected =
            $databaseNow -lt $retryAtUtc -and
            $beforeEligibility.PendingMessages -eq 1 -and
            $beforeEligibility.ProcessingMessages -eq 0 -and
            $beforeEligibility.ConsumerAttempts -eq 1 -and
            $beforeEligibility.FailedAttempts -eq 1 -and
            $beforeEligibility.Effects -eq 0 -and
            $null -eq $recoveryAttemptBeforeEligibility

        $completed = Wait-ForRetryCompletion $Assembly $recoveryWorker $recoveryWorkerId
        Save-Observation $completed $scenarioDirectory "retry-completed"

        $completionDatabaseTime = [DateTimeOffset]$completed.DatabaseUtcNow
        $completedAfterRetryBoundary = $completionDatabaseTime -ge $retryAtUtc
        $passed =
            $retryWasProtected -and
            $completedAfterRetryBoundary -and
            (Test-RetryCompletedResult $completed $initialWorkerId $recoveryWorkerId)
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $initialWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W09"
        InitialWorker = $initialWorkerId
        RecoveryWorker = $recoveryWorkerId
        RetryAtUtc = $retryAtUtc.ToString("O")
        RetryWasProtected = $retryWasProtected
        CompletedAfterRetryBoundary = $completedAfterRetryBoundary
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W09"
}

