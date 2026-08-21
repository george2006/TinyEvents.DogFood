function Get-Observation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "Operational observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Save-Observation {
    param(
        [pscustomobject]$Observation,
        [string]$ArtifactDirectory,
        [string]$Name
    )

    $Observation | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ArtifactDirectory "$Name.json")
}

function Wait-ForClaim {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before claiming the message. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $claim = $observation.WorkerClaims.PSObject.Properties[$WorkerId]

        if ($observation.ProcessingMessages -eq 1 -and
            $observation.Effects -eq 0 -and
            $null -ne $claim -and
            $claim.Value -eq 1 -and
            $null -ne $observation.EarliestClaimExpiresAtUtc) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not claim the message within twenty seconds."
}

function Wait-ForCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before completing the message. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.Effects -eq 1 -and
            $observation.ProcessingMessages -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not complete the message within thirty seconds."
}

function Wait-ForEffectBeforeCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before persisting the consumer effect. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $claim = $observation.WorkerClaims.PSObject.Properties[$WorkerId]
        $effect = $observation.WorkerEffects.PSObject.Properties[$WorkerId]

        if ($observation.ProcessingMessages -eq 1 -and
            $observation.ProcessedMessages -eq 0 -and
            $observation.Effects -eq 1 -and
            $observation.DuplicateEffects -eq 0 -and
            $null -ne $claim -and
            $claim.Value -eq 1 -and
            $null -ne $effect -and
            $effect.Value -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not persist the consumer effect before completion within twenty seconds."
}

function Wait-ForDuplicateCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before completing the redelivery. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.Effects -eq 2 -and
            $observation.DuplicateEffects -eq 1 -and
            $observation.ProcessingMessages -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not complete the expected redelivery within thirty seconds."
}

function Wait-ForCompetingCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$OriginalWorker,
        [System.Diagnostics.Process]$CompetingWorker,
        [string]$OriginalWorkerId,
        [string]$CompetingWorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($OriginalWorker.HasExited) {
            throw "Original worker '$OriginalWorkerId' exited before its slow consumer completed. Exit code: $($OriginalWorker.ExitCode)."
        }

        if ($CompetingWorker.HasExited) {
            throw "Competing worker '$CompetingWorkerId' exited before completing the reclaimed message. Exit code: $($CompetingWorker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $originalEffect = $observation.WorkerEffects.PSObject.Properties[$OriginalWorkerId]
        $competingClaim = $observation.WorkerClaims.PSObject.Properties[$CompetingWorkerId]
        $competingEffect = $observation.WorkerEffects.PSObject.Properties[$CompetingWorkerId]

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.Effects -eq 1 -and
            $null -eq $originalEffect -and
            $null -ne $competingClaim -and
            $competingClaim.Value -eq 1 -and
            $null -ne $competingEffect -and
            $competingEffect.Value -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Competing worker '$CompetingWorkerId' did not complete while '$OriginalWorkerId' remained active."
}

function Wait-ForScheduledRetry {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before scheduling the retry. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $workerAttempt = $observation.WorkerAttempts.PSObject.Properties[$WorkerId]

        if ($observation.PendingMessages -eq 1 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 0 -and
            $observation.FailedMessages -eq 0 -and
            $observation.FailedAttempts -eq 1 -and
            $observation.ConsumerAttempts -eq 1 -and
            $observation.Effects -eq 0 -and
            $null -ne $observation.EarliestNextAttemptAtUtc -and
            $null -ne $workerAttempt -and
            $workerAttempt.Value -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not schedule the retry within twenty seconds."
}

function Wait-ForRetryCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before completing the retry. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 1 -and
            $observation.ConsumerAttempts -eq 2 -and
            $observation.Effects -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not complete the retry within twenty seconds."
}
