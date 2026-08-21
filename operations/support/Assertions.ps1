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
