function Invoke-TEW05EffectBeforeDeath {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W05"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W05", "1") $scenarioDirectory "publish"

    $deadWorkerId = "TE-W05-dead-owner"
    $recoveryWorkerId = "TE-W05-recovery"
    $deadWorker = Start-Worker $Assembly $deadWorkerId 0 30000 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $effectPersisted = Wait-ForEffectBeforeCompletion $Assembly $deadWorker $deadWorkerId
        Save-Observation $effectPersisted $scenarioDirectory "effect-before-kill"
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
            $beforeExpiry.ProcessedMessages -eq 0 -and
            $beforeExpiry.Effects -eq 1 -and
            $beforeExpiry.DuplicateEffects -eq 0 -and
            $null -eq $beforeExpiry.WorkerClaims.PSObject.Properties[$recoveryWorkerId]

        $completed = Wait-ForDuplicateCompletion $Assembly $recoveryWorker $recoveryWorkerId
        Save-Observation $completed $scenarioDirectory "redelivered"

        $deadWorkerEffect = $completed.WorkerEffects.PSObject.Properties[$deadWorkerId]
        $recoveryWorkerClaim = $completed.WorkerClaims.PSObject.Properties[$recoveryWorkerId]
        $recoveryWorkerEffect = $completed.WorkerEffects.PSObject.Properties[$recoveryWorkerId]
        $passed =
            $wasProtectedBeforeExpiry -and
            $completed.BusinessOperations -eq 1 -and
            $completed.OutboxMessages -eq 1 -and
            $completed.PendingMessages -eq 0 -and
            $completed.ProcessingMessages -eq 0 -and
            $completed.ProcessedMessages -eq 1 -and
            $completed.FailedMessages -eq 0 -and
            $completed.FailedAttempts -eq 0 -and
            $completed.Effects -eq 2 -and
            $completed.DuplicateEffects -eq 1 -and
            @($completed.WorkerEffects.PSObject.Properties).Count -eq 2 -and
            $null -ne $deadWorkerEffect -and
            $deadWorkerEffect.Value -eq 1 -and
            $null -ne $recoveryWorkerClaim -and
            $recoveryWorkerClaim.Value -eq 1 -and
            $null -ne $recoveryWorkerEffect -and
            $recoveryWorkerEffect.Value -eq 1
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $deadWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W05"
        DeadWorker = $deadWorkerId
        RecoveryWorker = $recoveryWorkerId
        ProtectedBeforeExpiry = $wasProtectedBeforeExpiry
        ConsumerInvocations = $completed.Effects
        DuplicateInvocations = $completed.DuplicateEffects
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W05"
}
