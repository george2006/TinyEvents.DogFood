function Invoke-TEW07LongConsumerLeaseLoss {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W07"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W07", "1") $scenarioDirectory "publish"

    $slowWorkerId = "TE-W07-slow-owner"
    $competingWorkerId = "TE-W07-competitor"
    $slowWorker = Start-Worker $Assembly $slowWorkerId 10000 0 $scenarioDirectory
    $competingWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $slowWorker $slowWorkerId
        Save-Observation $claimed $scenarioDirectory "slow-consumer-claimed"

        $competingWorker = Start-Worker $Assembly $competingWorkerId 0 0 $scenarioDirectory
        $competingCompletion = Wait-ForCompetingCompletion `
            $Assembly `
            $slowWorker `
            $competingWorker `
            $slowWorkerId `
            $competingWorkerId
        Save-Observation $competingCompletion $scenarioDirectory "competitor-completed"

        $bothInvocationsCompleted = Wait-ForDuplicateCompletion $Assembly $slowWorker $slowWorkerId
        Start-Sleep -Milliseconds 500

        $slowWorkerSurvivedLeaseLoss = -not $slowWorker.HasExited
        Save-Observation $bothInvocationsCompleted $scenarioDirectory "slow-consumer-completed"

        $originalClaimExpiry = [DateTimeOffset]$claimed.EarliestClaimExpiresAtUtc
        $competingCompletionDatabaseTime = [DateTimeOffset]$competingCompletion.DatabaseUtcNow
        $leaseExpiredBeforeCompetingCompletion =
            $competingCompletionDatabaseTime -ge $originalClaimExpiry
        $slowWorkerEffect = $bothInvocationsCompleted.WorkerEffects.PSObject.Properties[$slowWorkerId]
        $competingWorkerClaim = $bothInvocationsCompleted.WorkerClaims.PSObject.Properties[$competingWorkerId]
        $competingWorkerEffect = $bothInvocationsCompleted.WorkerEffects.PSObject.Properties[$competingWorkerId]
        $passed =
            $leaseExpiredBeforeCompetingCompletion -and
            $slowWorkerSurvivedLeaseLoss -and
            $competingCompletion.ProcessedMessages -eq 1 -and
            $competingCompletion.Effects -eq 1 -and
            $null -eq $competingCompletion.WorkerEffects.PSObject.Properties[$slowWorkerId] -and
            $bothInvocationsCompleted.BusinessOperations -eq 1 -and
            $bothInvocationsCompleted.OutboxMessages -eq 1 -and
            $bothInvocationsCompleted.PendingMessages -eq 0 -and
            $bothInvocationsCompleted.ProcessingMessages -eq 0 -and
            $bothInvocationsCompleted.ProcessedMessages -eq 1 -and
            $bothInvocationsCompleted.FailedMessages -eq 0 -and
            $bothInvocationsCompleted.FailedAttempts -eq 0 -and
            $bothInvocationsCompleted.Effects -eq 2 -and
            $bothInvocationsCompleted.DuplicateEffects -eq 1 -and
            @($bothInvocationsCompleted.WorkerEffects.PSObject.Properties).Count -eq 2 -and
            $null -ne $slowWorkerEffect -and
            $slowWorkerEffect.Value -eq 1 -and
            $null -ne $competingWorkerClaim -and
            $competingWorkerClaim.Value -eq 1 -and
            $null -ne $competingWorkerEffect -and
            $competingWorkerEffect.Value -eq 1
    }
    finally {
        Stop-Worker $competingWorker
        Stop-Worker $slowWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W07"
        SlowWorker = $slowWorkerId
        CompetingWorker = $competingWorkerId
        ClaimTimeoutMilliseconds = 5000
        ConsumerDurationMilliseconds = 10000
        LeaseExpiredBeforeCompetingCompletion = $leaseExpiredBeforeCompetingCompletion
        CompetingWorkerCompletedFirst = $competingCompletion.Effects -eq 1
        SlowWorkerSurvivedLeaseLoss = $slowWorkerSurvivedLeaseLoss
        ConsumerInvocations = $bothInvocationsCompleted.Effects
        DuplicateInvocations = $bothInvocationsCompleted.DuplicateEffects
        Observation = $bothInvocationsCompleted
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W07"
}
