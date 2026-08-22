function Get-Observation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "Operational observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Get-PublishingLoadResult {
    param([string]$OutputPath)

    $json = Get-Content -LiteralPath $OutputPath |
        Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "Publishing load command produced no result."
    }

    return $json | ConvertFrom-Json
}

function Get-ScenarioCount {
    param(
        [pscustomobject]$Counts,
        [string]$ScenarioId
    )

    $count = $Counts.PSObject.Properties[$ScenarioId]

    if ($null -eq $count) {
        return 0
    }

    return $count.Value
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

function Wait-ForRetryAttemptState {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId,
        [int]$ExpectedAttemptCount
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited while scheduling retry attempt $ExpectedAttemptCount. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 1 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 1 -and
            $observation.FailedMessages -eq 0 -and
            $observation.FailedAttempts -eq $ExpectedAttemptCount -and
            $observation.ConsumerAttempts -eq $ExpectedAttemptCount -and
            $observation.Effects -eq 1 -and
            $null -ne $observation.EarliestNextAttemptAtUtc -and
            $null -ne $observation.LatestConsumerAttemptAtUtc) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not reach transient retry attempt $ExpectedAttemptCount within twenty seconds."
}

function Wait-ForTransientRecovery {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before transient recovery completed. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 2 -and
            $observation.FailedMessages -eq 0 -and
            $observation.FailedAttempts -eq 2 -and
            $observation.ConsumerAttempts -eq 3 -and
            $observation.Effects -eq 2 -and
            $observation.DuplicateEffects -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not recover from transient failures within twenty seconds."
}

function Wait-ForPermanentFailure {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before the permanent failure became terminal. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 1 -and
            $observation.FailedMessages -eq 1 -and
            $observation.FailedAttempts -eq 3 -and
            $observation.ConsumerAttempts -eq 3 -and
            $observation.Effects -eq 1 -and
            $observation.DuplicateEffects -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not exhaust the permanent failure within twenty seconds."
}

function Wait-ForLaterConsumerRetry {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before the later consumer scheduled its retry. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 1 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 0 -and
            $observation.FailedMessages -eq 0 -and
            $observation.FailedAttempts -eq 1 -and
            $observation.ConsumerAttempts -eq 1 -and
            $observation.Effects -eq 1 -and
            $observation.DuplicateEffects -eq 0 -and
            $null -ne $observation.EarliestNextAttemptAtUtc) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not schedule the later-consumer retry within twenty seconds."
}

function Wait-ForDuplicateIdentityReclaim {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$OriginalWorker,
        [System.Diagnostics.Process]$CompetingWorker,
        [DateTimeOffset]$OriginalClaimExpiry
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($OriginalWorker.HasExited -or $CompetingWorker.HasExited) {
            throw "A duplicate-identity worker exited before the expired claim was reassigned."
        }

        $observation = Get-Observation -Assembly $Assembly
        $currentClaimExpiry = $observation.EarliestClaimExpiresAtUtc

        if ($observation.ProcessingMessages -eq 1 -and
            $observation.Effects -eq 0 -and
            $null -ne $currentClaimExpiry -and
            [DateTimeOffset]$observation.DatabaseUtcNow -ge $OriginalClaimExpiry -and
            [DateTimeOffset]$currentClaimExpiry -gt $OriginalClaimExpiry) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "The duplicate-identity worker did not reclaim the expired message within twenty seconds."
}

function Wait-ForStaleOwnerCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$OriginalWorker,
        [System.Diagnostics.Process]$CompetingWorker
    )

    $deadline = (Get-Date).AddSeconds(20)
    $originalProcessId = [string]$OriginalWorker.Id
    $competingProcessId = [string]$CompetingWorker.Id

    while ((Get-Date) -lt $deadline) {
        if ($OriginalWorker.HasExited -or $CompetingWorker.HasExited) {
            throw "A duplicate-identity worker exited before stale-owner completion was observed."
        }

        $observation = Get-Observation -Assembly $Assembly
        $originalEffect = $observation.ProcessEffects.PSObject.Properties[$originalProcessId]
        $competingEffect = $observation.ProcessEffects.PSObject.Properties[$competingProcessId]

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.Effects -eq 1 -and
            $null -ne $originalEffect -and
            $originalEffect.Value -eq 1 -and
            $null -eq $competingEffect) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "The stale owner did not complete the reassigned message within twenty seconds."
}

function Wait-ForLogText {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$LogPath,
        [string]$ExpectedText,
        [string]$ProcessDescription,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            throw "$ProcessDescription exited before logging '$ExpectedText'. Exit code: $($Process.ExitCode)."
        }

        if ((Test-Path -LiteralPath $LogPath) -and
            (Select-String -LiteralPath $LogPath -SimpleMatch $ExpectedText -Quiet)) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    throw "$ProcessDescription did not log '$ExpectedText' within $TimeoutSeconds seconds."
}

function Get-WorkerFailureLogCounts {
    param([string]$LogPath)

    $content = Get-Content -LiteralPath $LogPath -Raw
    $matches = [regex]::Matches(
        $content,
        "(?:Consecutive failures:|has failed)\s+(\d+)")

    return @($matches | ForEach-Object { [int]$_.Groups[1].Value })
}

function Wait-ForCompletedMessages {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId,
        [int]$ExpectedCount
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before completing $ExpectedCount messages. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.ProcessedMessages -eq $ExpectedCount -and
            $observation.Effects -eq $ExpectedCount -and
            $observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not complete $ExpectedCount messages within thirty seconds."
}
