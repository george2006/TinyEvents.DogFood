function Test-AllWorkersParticipated {
    param(
        [pscustomobject]$Observation,
        [string[]]$WorkerIds
    )

    foreach ($workerId in $WorkerIds) {
        $claims = $Observation.WorkerClaims.PSObject.Properties[$workerId]
        $effects = $Observation.WorkerEffects.PSObject.Properties[$workerId]

        if ($null -eq $claims -or
            $null -eq $effects -or
            $claims.Value -le 0 -or
            $effects.Value -le 0) {
            return $false
        }
    }

    return (
        @($Observation.WorkerClaims.PSObject.Properties).Count -eq $WorkerIds.Count -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq $WorkerIds.Count)
}

function Test-WorkerOwnsResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId
    )

    $claim = $Observation.WorkerClaims.PSObject.Properties[$WorkerId]
    $effect = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]

    return (
        $Observation.BusinessOperations -eq 1 -and
        $Observation.OutboxMessages -eq 1 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 1 -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 0 -and
        $Observation.Effects -eq 1 -and
        $Observation.DuplicateEffects -eq 0 -and
        @($Observation.WorkerClaims.PSObject.Properties).Count -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $claim -and
        $claim.Value -eq 1 -and
        $null -ne $effect -and
        $effect.Value -eq 1)
}

function Test-RetryCompletedResult {
    param(
        [pscustomobject]$Observation,
        [string]$InitialWorkerId,
        [string]$RecoveryWorkerId
    )

    $initialAttempt = $Observation.WorkerAttempts.PSObject.Properties[$InitialWorkerId]
    $recoveryAttempt = $Observation.WorkerAttempts.PSObject.Properties[$RecoveryWorkerId]
    $recoveryClaim = $Observation.WorkerClaims.PSObject.Properties[$RecoveryWorkerId]
    $recoveryEffect = $Observation.WorkerEffects.PSObject.Properties[$RecoveryWorkerId]

    return (
        $Observation.BusinessOperations -eq 1 -and
        $Observation.OutboxMessages -eq 1 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 1 -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 1 -and
        $Observation.ConsumerAttempts -eq 2 -and
        $Observation.Effects -eq 1 -and
        $Observation.DuplicateEffects -eq 0 -and
        @($Observation.WorkerAttempts.PSObject.Properties).Count -eq 2 -and
        @($Observation.WorkerClaims.PSObject.Properties).Count -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $initialAttempt -and
        $initialAttempt.Value -eq 1 -and
        $null -ne $recoveryAttempt -and
        $recoveryAttempt.Value -eq 1 -and
        $null -ne $recoveryClaim -and
        $recoveryClaim.Value -eq 1 -and
        $null -ne $recoveryEffect -and
        $recoveryEffect.Value -eq 1)
}

function Test-TransientRecoveryResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId
    )

    $attempts = $Observation.WorkerAttempts.PSObject.Properties[$WorkerId]
    $effects = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]

    return (
        $Observation.BusinessOperations -eq 2 -and
        $Observation.OutboxMessages -eq 2 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 2 -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 2 -and
        $Observation.ConsumerAttempts -eq 3 -and
        $Observation.Effects -eq 2 -and
        $Observation.DuplicateEffects -eq 0 -and
        @($Observation.WorkerAttempts.PSObject.Properties).Count -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $attempts -and
        $attempts.Value -eq 3 -and
        $null -ne $effects -and
        $effects.Value -eq 2)
}

function Test-PermanentFailureResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId
    )

    $attempts = $Observation.WorkerAttempts.PSObject.Properties[$WorkerId]
    $effects = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]

    return (
        $Observation.BusinessOperations -eq 2 -and
        $Observation.OutboxMessages -eq 2 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 1 -and
        $Observation.FailedMessages -eq 1 -and
        $Observation.FailedAttempts -eq 3 -and
        $Observation.ConsumerAttempts -eq 3 -and
        $Observation.Effects -eq 1 -and
        $Observation.DuplicateEffects -eq 0 -and
        $null -eq $Observation.EarliestNextAttemptAtUtc -and
        $Observation.TerminalError -eq "TE-W11-permanent rejects consumer attempt 3." -and
        @($Observation.WorkerAttempts.PSObject.Properties).Count -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $attempts -and
        $attempts.Value -eq 3 -and
        $null -ne $effects -and
        $effects.Value -eq 1)
}

function Test-LaterConsumerRetryResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId
    )

    $attempts = $Observation.WorkerAttempts.PSObject.Properties[$WorkerId]
    $effects = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]

    return (
        $Observation.BusinessOperations -eq 1 -and
        $Observation.OutboxMessages -eq 1 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 1 -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 1 -and
        $Observation.ConsumerAttempts -eq 2 -and
        $Observation.Effects -eq 2 -and
        $Observation.DuplicateEffects -eq 1 -and
        $null -ne $attempts -and
        $attempts.Value -eq 2 -and
        $null -ne $effects -and
        $effects.Value -eq 2)
}

function Test-DuplicateIdentityResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId,
        [int]$OriginalProcessId,
        [int]$CompetingProcessId
    )

    $workerEffects = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]
    $originalEffects = $Observation.ProcessEffects.PSObject.Properties[[string]$OriginalProcessId]
    $competingEffects = $Observation.ProcessEffects.PSObject.Properties[[string]$CompetingProcessId]

    return (
        $Observation.BusinessOperations -eq 1 -and
        $Observation.OutboxMessages -eq 1 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 1 -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 0 -and
        $Observation.Effects -eq 2 -and
        $Observation.DuplicateEffects -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        @($Observation.ProcessEffects.PSObject.Properties).Count -eq 2 -and
        $null -ne $workerEffects -and
        $workerEffects.Value -eq 2 -and
        $null -ne $originalEffects -and
        $originalEffects.Value -eq 1 -and
        $null -ne $competingEffects -and
        $competingEffects.Value -eq 1)
}

function Test-WorkerCompletedMessagesResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId,
        [int]$ExpectedCount
    )

    $claims = $Observation.WorkerClaims.PSObject.Properties[$WorkerId]
    $effects = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]

    return (
        $Observation.BusinessOperations -eq $ExpectedCount -and
        $Observation.OutboxMessages -eq $ExpectedCount -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq $ExpectedCount -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 0 -and
        $Observation.Effects -eq $ExpectedCount -and
        $Observation.DuplicateEffects -eq 0 -and
        @($Observation.WorkerClaims.PSObject.Properties).Count -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $claims -and
        $claims.Value -eq $ExpectedCount -and
        $null -ne $effects -and
        $effects.Value -eq $ExpectedCount)
}
