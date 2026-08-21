function Invoke-TEW04WorkerDeathRecovery {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W04"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W04", "1") $scenarioDirectory "publish"

    $deadWorkerId = "TE-W04-dead-owner"
    $recoveryWorkerId = "TE-W04-recovery"
    $deadWorker = Start-Worker $Assembly $deadWorkerId 30000 0 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $deadWorker $deadWorkerId
        Save-Observation $claimed $scenarioDirectory "claimed-before-kill"
        Stop-Worker $deadWorker

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 0 $scenarioDirectory
        Start-Sleep -Milliseconds 500

        if ($recoveryWorker.HasExited) {
            throw "Recovery worker exited while the dead owner's lease was active. Exit code: $($recoveryWorker.ExitCode)."
        }

        $beforeExpiry = Get-Observation -Assembly $Assembly
        Save-Observation $beforeExpiry $scenarioDirectory "protected-after-kill"

        $claimExpiry = [DateTimeOffset]$beforeExpiry.EarliestClaimExpiresAtUtc
        $databaseNow = [DateTimeOffset]$beforeExpiry.DatabaseUtcNow
        $wasProtectedBeforeExpiry =
            $databaseNow -lt $claimExpiry -and
            $beforeExpiry.ProcessingMessages -eq 1 -and
            $beforeExpiry.Effects -eq 0 -and
            $null -eq $beforeExpiry.WorkerClaims.PSObject.Properties[$recoveryWorkerId]

        $recoveryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = Wait-ForCompletion $Assembly $recoveryWorker $recoveryWorkerId
        $recoveryStopwatch.Stop()
        Save-Observation $completed $scenarioDirectory "recovered"

        $passed = $wasProtectedBeforeExpiry -and (Test-WorkerOwnsResult $completed $recoveryWorkerId)
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $deadWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W04"
        DeadWorker = $deadWorkerId
        RecoveryWorker = $recoveryWorkerId
        ProtectedBeforeExpiry = $wasProtectedBeforeExpiry
        RecoveryDurationMilliseconds = $recoveryStopwatch.ElapsedMilliseconds
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W04"
}
