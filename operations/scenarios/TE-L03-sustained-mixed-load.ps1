function Get-TEL03Mix {
    param(
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds
    )

    $transientRate = [Math]::Max(1, [Math]::Floor($TargetRequestsPerSecond * 0.10))
    $permanentRate = [Math]::Max(1, [Math]::Floor($TargetRequestsPerSecond * 0.05))
    $slowRate = [Math]::Max(1, [Math]::Floor($TargetRequestsPerSecond * 0.05))
    $successRate =
        $TargetRequestsPerSecond -
        $transientRate -
        $permanentRate -
        $slowRate

    return @(
        [pscustomobject]@{
            Name = "success"
            ScenarioId = "TE-L03-success"
            RequestsPerSecond = $successRate
            ExpectedCount = $successRate * $DurationSeconds
        },
        [pscustomobject]@{
            Name = "transient"
            ScenarioId = "TE-L03-transient"
            RequestsPerSecond = $transientRate
            ExpectedCount = $transientRate * $DurationSeconds
        },
        [pscustomobject]@{
            Name = "permanent"
            ScenarioId = "TE-L03-permanent"
            RequestsPerSecond = $permanentRate
            ExpectedCount = $permanentRate * $DurationSeconds
        },
        [pscustomobject]@{
            Name = "slow"
            ScenarioId = "TE-L03-slow"
            RequestsPerSecond = $slowRate
            ExpectedCount = $slowRate * $DurationSeconds
        })
}

function Start-TEL03Publisher {
    param(
        [string]$Assembly,
        [pscustomobject[]]$Mix,
        [int]$DurationSeconds,
        [string]$ArtifactDirectory
    )

    $arguments = @("publish-mixed-load", [string]$DurationSeconds)

    foreach ($definition in $Mix) {
        $arguments += @(
            $definition.ScenarioId,
            [string]$definition.RequestsPerSecond)
    }

    return Start-LoggedDotNetProcess `
        $Assembly `
        $arguments `
        $ArtifactDirectory `
        "publisher"
}

function Wait-ForTEL03MixedProgress {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [pscustomobject]$Publisher,
        [string]$SuccessScenarioId
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Mixed-load worker $($exitedWorker.Id) exited before progress was observed."
        }

        if ($Publisher.Process.HasExited -and
            $Publisher.Process.ExitCode -ne 0) {
            throw "Mixed-load publisher exited with code $($Publisher.Process.ExitCode)."
        }

        $observation = Get-Observation $Assembly
        $successEffects = Get-ScenarioCount `
            $observation.ScenarioEffects `
            $SuccessScenarioId
        $retryPressureIsVisible = $observation.FailedAttempts -gt 0
        $unrelatedWorkIsProgressing = $successEffects -gt 0
        $workRemainsInFlight =
            $observation.PendingMessages -gt 0 -or
            $observation.ProcessingMessages -gt 0

        if ($retryPressureIsVisible -and
            $unrelatedWorkIsProgressing -and
            $workRemainsInFlight) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Mixed load did not demonstrate retry pressure and unrelated progress within thirty seconds."
}

function Wait-ForTEL03Completion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [int]$ExpectedProcessedCount,
        [int]$ExpectedFailedCount
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Mixed-load worker $($exitedWorker.Id) exited before completion."
        }

        $observation = Get-Observation $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq $ExpectedProcessedCount -and
            $observation.FailedMessages -eq $ExpectedFailedCount) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Mixed load did not settle within two minutes."
}

function Test-TEL03PublisherResults {
    param(
        [pscustomobject[]]$Mix,
        [System.Collections.IDictionary]$Results
    )

    foreach ($definition in $Mix) {
        $result = $Results[$definition.Name]

        if ($result.AttemptedRequests -ne $definition.ExpectedCount -or
            $result.CommittedRequests -ne $definition.ExpectedCount -or
            $result.FailedRequests -ne 0) {
            return $false
        }
    }

    return $true
}

function Invoke-TEL03SustainedMixedLoad {
    param(
        [string]$Assembly,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [int]$WorkerCount,
        [int]$SlowDelayMilliseconds,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L03"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $mix = Get-TEL03Mix $TargetRequestsPerSecond $DurationSeconds
    $success = $mix | Where-Object { $_.Name -eq "success" }
    $transient = $mix | Where-Object { $_.Name -eq "transient" }
    $permanent = $mix | Where-Object { $_.Name -eq "permanent" }
    $slow = $mix | Where-Object { $_.Name -eq "slow" }
    $expectedTotalCount = ($mix.ExpectedCount | Measure-Object -Sum).Sum
    $expectedProcessedCount =
        $success.ExpectedCount +
        $transient.ExpectedCount +
        $slow.ExpectedCount
    $expectedFailedAttempts =
        ($transient.ExpectedCount * 2) +
        ($permanent.ExpectedCount * 3)
    $expectedConsumerAttempts =
        ($transient.ExpectedCount * 3) +
        ($permanent.ExpectedCount * 3)

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"

    $workerIds = @(
        for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
            "TE-L03-worker-$workerNumber"
        })
    $failureRules = @(
        $transient.ScenarioId,
        "2",
        $permanent.ScenarioId,
        "3")
    $workers = @()
    $publisher = $null
    $execution = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $workers = @(
            foreach ($workerId in $workerIds) {
                Start-PlannedWorker `
                    $Assembly `
                    $workerId `
                    $slow.ScenarioId `
                    $SlowDelayMilliseconds `
                    $failureRules `
                    $scenarioDirectory
            })
        $publisher = Start-TEL03Publisher `
            $Assembly `
            $mix `
            $DurationSeconds `
            $scenarioDirectory

        $progress = Wait-ForTEL03MixedProgress `
            $Assembly `
            $workers `
            $publisher `
            $success.ScenarioId
        Save-Observation $progress $scenarioDirectory "mixed-progress"

        Complete-LoggedProcess $publisher 120000

        $publishingCompletedAt = $execution.Elapsed
        $publisherResults = [ordered]@{}
        $publishingResults = Get-PublishingLoadResult `
            (Join-Path $scenarioDirectory "publisher.stdout.log")

        foreach ($definition in $mix) {
            $scenarioResult = $publishingResults |
                Where-Object { $_.ScenarioId -eq $definition.ScenarioId }
            $publisherResults[$definition.Name] = $scenarioResult.Load
        }

        $committedProcessedCount =
            $publisherResults[$success.Name].CommittedRequests +
            $publisherResults[$transient.Name].CommittedRequests +
            $publisherResults[$slow.Name].CommittedRequests
        $committedFailedCount =
            $publisherResults[$permanent.Name].CommittedRequests
        $completed = Wait-ForTEL03Completion `
            $Assembly `
            $workers `
            $committedProcessedCount `
            $committedFailedCount
        $execution.Stop()
        Save-Observation $completed $scenarioDirectory "completed"
    }
    finally {
        $execution.Stop()

        if ($null -ne $publisher -and
            -not $publisher.Process.HasExited) {
            Stop-LoggedProcess $publisher | Out-Null
        }

        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    $allPublishersCommitted = Test-TEL03PublisherResults $mix $publisherResults
    $allWorkersParticipated = Test-AllWorkersParticipated $completed $workerIds
    $successEffects = Get-ScenarioCount $completed.ScenarioEffects $success.ScenarioId
    $transientEffects = Get-ScenarioCount $completed.ScenarioEffects $transient.ScenarioId
    $permanentEffects = Get-ScenarioCount $completed.ScenarioEffects $permanent.ScenarioId
    $slowEffects = Get-ScenarioCount $completed.ScenarioEffects $slow.ScenarioId
    $transientAttempts = Get-ScenarioCount $completed.ScenarioAttempts $transient.ScenarioId
    $permanentAttempts = Get-ScenarioCount $completed.ScenarioAttempts $permanent.ScenarioId
    $retryPressureWasVisible = $progress.FailedAttempts -gt 0
    $successProgressedDuringRetries =
        (Get-ScenarioCount $progress.ScenarioEffects $success.ScenarioId) -gt 0
    $settlementTailMilliseconds =
        $execution.Elapsed.TotalMilliseconds -
        $publishingCompletedAt.TotalMilliseconds
    $passed =
        $allPublishersCommitted -and
        $allWorkersParticipated -and
        $retryPressureWasVisible -and
        $successProgressedDuringRetries -and
        $completed.BusinessOperations -eq $expectedTotalCount -and
        $completed.OutboxMessages -eq $expectedTotalCount -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq $expectedProcessedCount -and
        $completed.FailedMessages -eq $permanent.ExpectedCount -and
        $completed.FailedAttempts -eq $expectedFailedAttempts -and
        $completed.ConsumerAttempts -eq $expectedConsumerAttempts -and
        $completed.TerminalError -eq "TE-L03-permanent rejects consumer attempt 3." -and
        $completed.Effects -eq $expectedProcessedCount -and
        $completed.DuplicateEffects -eq 0 -and
        $successEffects -eq $success.ExpectedCount -and
        $transientEffects -eq $transient.ExpectedCount -and
        $permanentEffects -eq 0 -and
        $slowEffects -eq $slow.ExpectedCount -and
        $transientAttempts -eq ($transient.ExpectedCount * 3) -and
        $permanentAttempts -eq ($permanent.ExpectedCount * 3)

    $result = [ordered]@{
        Scenario = "TE-L03"
        TargetRequestsPerSecond = $TargetRequestsPerSecond
        DurationSeconds = $DurationSeconds
        WorkerCount = $WorkerCount
        SlowDelayMilliseconds = $SlowDelayMilliseconds
        Mix = $mix
        PublisherResults = $publisherResults
        RetryPressureWasVisible = $retryPressureWasVisible
        SuccessProgressedDuringRetries = $successProgressedDuringRetries
        AllPublishersCommitted = $allPublishersCommitted
        AllWorkersParticipated = $allWorkersParticipated
        PublishingDurationMilliseconds = $publishingCompletedAt.TotalMilliseconds
        SettlementTailMilliseconds = $settlementTailMilliseconds
        ObservationDuringMixedProgress = $progress
        ObservationAfterSettlement = $completed
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 12 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-MixedLoad.ps1"
    & $runner
}
