function Invoke-TEW08ActiveShutdown {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W08-active"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W08", "1") $scenarioDirectory "publish"

    $stoppingWorkerId = "TE-W08-stopping-worker"
    $recoveryWorkerId = "TE-W08-recovery"
    $stoppingWorkerHandle = Start-TimedWorker $Assembly $stoppingWorkerId 3000 30000 0 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $stoppingWorkerHandle.Process $stoppingWorkerId
        Save-Observation $claimed $scenarioDirectory "claimed-before-shutdown"
        Wait-ForWorkerExit $stoppingWorkerHandle $stoppingWorkerId

        $afterShutdown = Get-Observation -Assembly $Assembly
        Save-Observation $afterShutdown $scenarioDirectory "after-shutdown"

        $claimExpiry = [DateTimeOffset]$afterShutdown.EarliestClaimExpiresAtUtc
        $databaseNow = [DateTimeOffset]$afterShutdown.DatabaseUtcNow
        $workerLog = Get-Content (Join-Path $scenarioDirectory "$stoppingWorkerId.stdout.log") -Raw
        $reportedGracefulShutdown = $workerLog.Contains("Application is shutting down")
        $cancellationLeftRecoverableClaim =
            $reportedGracefulShutdown -and
            $databaseNow -lt $claimExpiry -and
            $afterShutdown.ProcessingMessages -eq 1 -and
            $afterShutdown.ProcessedMessages -eq 0 -and
            $afterShutdown.FailedMessages -eq 0 -and
            $afterShutdown.FailedAttempts -eq 0 -and
            $afterShutdown.Effects -eq 0

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 0 $scenarioDirectory
        $recovered = Wait-ForCompletion $Assembly $recoveryWorker $recoveryWorkerId
        Save-Observation $recovered $scenarioDirectory "recovered"
        $passed =
            $cancellationLeftRecoverableClaim -and
            (Test-WorkerOwnsResult $recovered $recoveryWorkerId)
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $stoppingWorkerHandle.Process
    }

    $result = [ordered]@{
        Scenario = "TE-W08-active"
        ExitCode = $stoppingWorkerHandle.Process.ExitCode
        ReportedGracefulShutdown = $reportedGracefulShutdown
        CancellationLeftRecoverableClaim = $cancellationLeftRecoverableClaim
        ObservationAfterShutdown = $afterShutdown
        ObservationAfterRecovery = $recovered
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W08-active"
}
