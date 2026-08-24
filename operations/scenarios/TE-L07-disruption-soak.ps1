function Get-TEL07Mix {
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
            ScenarioId = "TE-L07-success"
            RequestsPerSecond = $successRate
            ExpectedAttemptCount = $successRate * $DurationSeconds
        },
        [pscustomobject]@{
            Name = "transient"
            ScenarioId = "TE-L07-transient"
            RequestsPerSecond = $transientRate
            ExpectedAttemptCount = $transientRate * $DurationSeconds
        },
        [pscustomobject]@{
            Name = "permanent"
            ScenarioId = "TE-L07-permanent"
            RequestsPerSecond = $permanentRate
            ExpectedAttemptCount = $permanentRate * $DurationSeconds
        },
        [pscustomobject]@{
            Name = "slow"
            ScenarioId = "TE-L07-slow"
            RequestsPerSecond = $slowRate
            ExpectedAttemptCount = $slowRate * $DurationSeconds
        })
}

function Start-TEL07Publisher {
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

function Start-TEL07Worker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [string]$EvidenceName,
        [string]$SlowScenarioId,
        [int]$SlowDelayMilliseconds,
        [string[]]$FailureRules,
        [string]$ArtifactDirectory
    )

    $process = Start-PlannedCleanupWorker `
        $Assembly `
        $WorkerId `
        $SlowScenarioId `
        $SlowDelayMilliseconds `
        3600 `
        1000 `
        1000 `
        $FailureRules `
        $ArtifactDirectory `
        $EvidenceName

    return [pscustomobject]@{
        WorkerId = $WorkerId
        EvidenceName = $EvidenceName
        Process = $process
        CanBeTerminated = $WorkerId.StartsWith("TE-L07-worker-")
    }
}

function Test-TEL07ProcessesAreHealthy {
    param([pscustomobject]$Context)

    foreach ($worker in $Context.ActiveWorkers) {
        if ($worker.Process.HasExited) {
            throw "Soak worker '$($worker.WorkerId)' exited unexpectedly with code $($worker.Process.ExitCode)."
        }
    }

    if ($Context.Publisher.Process.HasExited -and
        $Context.Publisher.Process.ExitCode -ne 0) {
        throw "Soak publisher exited with code $($Context.Publisher.Process.ExitCode)."
    }
}

function Get-TEL07ProcessMeasurement {
    param(
        [string]$Name,
        [System.Diagnostics.Process]$Process
    )

    if ($Process.HasExited) {
        return [pscustomobject]@{
            Name = $Name
            ProcessId = $Process.Id
            HasExited = $true
            WorkingSetBytes = $null
            PrivateMemoryBytes = $null
            TotalProcessorMilliseconds = $null
        }
    }

    $Process.Refresh()
    return [pscustomobject]@{
        Name = $Name
        ProcessId = $Process.Id
        HasExited = $false
        WorkingSetBytes = $Process.WorkingSet64
        PrivateMemoryBytes = $Process.PrivateMemorySize64
        TotalProcessorMilliseconds = $Process.TotalProcessorTime.TotalMilliseconds
    }
}

function Add-TEL07ResourceSample {
    param([pscustomobject]$Context)

    Test-TEL07ProcessesAreHealthy $Context
    $processes = @(
        Get-TEL07ProcessMeasurement `
            "publisher" `
            $Context.Publisher.Process

        foreach ($worker in $Context.ActiveWorkers) {
            Get-TEL07ProcessMeasurement `
                $worker.WorkerId `
                $worker.Process
        }
    )
    $observation = $null
    $storage = $null
    $activeConnections = $null

    if ($Context.DatabaseAvailable) {
        $observation = Get-Observation $Context.Assembly
        $storage = Get-StorageObservation $Context.Assembly
        $activeConnections = Get-DogfoodDatabaseConnectionCount $Context.Database
    }

    $Context.ResourceSamples.Add([pscustomobject]@{
        ElapsedMilliseconds = $Context.Execution.Elapsed.TotalMilliseconds
        CapturedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        DatabaseAvailable = $Context.DatabaseAvailable
        ActiveDatabaseConnections = $activeConnections
        Processes = $processes
        DurableObservation = $observation
        StorageObservation = $storage
    })
    $Context.NextResourceSampleAtSeconds =
        $Context.Execution.Elapsed.TotalSeconds +
        $Context.ResourceSampleIntervalSeconds
}

function Wait-UntilTEL07Elapsed {
    param(
        [pscustomobject]$Context,
        [double]$TargetSeconds
    )

    while ($Context.Execution.Elapsed.TotalSeconds -lt $TargetSeconds) {
        Test-TEL07ProcessesAreHealthy $Context

        if ($Context.Execution.Elapsed.TotalSeconds -ge
            $Context.NextResourceSampleAtSeconds) {
            Add-TEL07ResourceSample $Context
        }

        Start-Sleep -Milliseconds 250
    }
}

function Wait-ForTEL07ClaimedWorker {
    param(
        [pscustomobject]$Context,
        [string]$EvidenceName
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        Test-TEL07ProcessesAreHealthy $Context
        $observation = Get-Observation $Context.Assembly

        foreach ($worker in $Context.ActiveWorkers) {
            if (!$worker.CanBeTerminated) {
                continue
            }

            $claim = $observation.WorkerClaims.PSObject.Properties[$worker.WorkerId]

            if ($null -ne $claim -and $claim.Value -gt 0) {
                Save-Observation `
                    $observation `
                    $Context.ArtifactDirectory `
                    $EvidenceName
                return [pscustomobject]@{
                    Worker = $worker
                    Observation = $observation
                    ClaimedMessages = $claim.Value
                }
            }
        }

        Start-Sleep -Milliseconds 500
    }

    throw "No terminable soak worker owned claimed work within thirty seconds."
}

function Stop-TEL07ClaimedWorkerAndStartReplacement {
    param(
        [pscustomobject]$Context,
        [int]$DisruptionNumber
    )

    $claimed = Wait-ForTEL07ClaimedWorker `
        $Context `
        "before-worker-death-$DisruptionNumber"
    $worker = $claimed.Worker
    $stoppedAt = $Context.Execution.Elapsed.TotalMilliseconds
    Stop-Worker $worker.Process
    $Context.ActiveWorkers.Remove($worker) | Out-Null

    $replacementId = "TE-L07-replacement-$DisruptionNumber"
    $replacement = Start-TEL07Worker `
        $Context.Assembly `
        $replacementId `
        $replacementId `
        $Context.SlowScenarioId `
        $Context.SlowDelayMilliseconds `
        $Context.FailureRules `
        $Context.ArtifactDirectory
    $Context.ActiveWorkers.Add($replacement)
    $Context.WorkerDeaths.Add([pscustomobject]@{
        Number = $DisruptionNumber
        StoppedWorkerId = $worker.WorkerId
        StoppedProcessId = $worker.Process.Id
        ClaimedMessages = $claimed.ClaimedMessages
        ReplacementWorkerId = $replacement.WorkerId
        ReplacementProcessId = $replacement.Process.Id
        ElapsedMilliseconds = $stoppedAt
        ClaimObservation = $claimed.Observation
    })
}

function Get-TEL07WorkerLogTextCount {
    param(
        [pscustomobject]$Context,
        [string]$Text
    )

    $count = 0

    foreach ($worker in $Context.ActiveWorkers) {
        $logPath = Join-Path `
            $Context.ArtifactDirectory `
            "$($worker.EvidenceName).stdout.log"

        if (Test-Path -LiteralPath $logPath) {
            $content = Get-Content -LiteralPath $logPath -Raw

            if ([string]::IsNullOrEmpty($content)) {
                continue
            }

            $count += [regex]::Matches(
                $content,
                [regex]::Escape($Text)).Count
        }
    }

    return $count
}

function Wait-ForTEL07LogIncrease {
    param(
        [pscustomobject]$Context,
        [string]$Text,
        [int]$PreviousCount,
        [string]$Description
    )

    $deadline = (Get-Date).AddSeconds(60)

    while ((Get-Date) -lt $deadline) {
        Test-TEL07ProcessesAreHealthy $Context
        $currentCount = Get-TEL07WorkerLogTextCount $Context $Text

        if ($currentCount -gt $PreviousCount) {
            return $currentCount
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Soak workers did not report $Description within sixty seconds."
}

function Invoke-TEL07DatabaseOutage {
    param(
        [pscustomobject]$Context,
        [int]$DisruptionNumber,
        [int]$OutageDurationSeconds
    )

    Add-TEL07ResourceSample $Context
    $failureText = "processing iteration failed"
    $recoveryText = "TinyEvents worker recovered after"
    $failureCountBefore = Get-TEL07WorkerLogTextCount $Context $failureText
    $recoveryCountBefore = Get-TEL07WorkerLogTextCount $Context $recoveryText
    $outageStartedAt = $Context.Execution.Elapsed.TotalMilliseconds
    Stop-DogfoodDatabase $Context.Database
    $Context.DatabaseAvailable = $false

    try {
        Start-Sleep -Seconds $OutageDurationSeconds
        Test-TEL07ProcessesAreHealthy $Context
        Add-TEL07ResourceSample $Context
    }
    finally {
        Start-DogfoodDatabase $Context.Database
        $Context.DatabaseAvailable = $true
    }

    $restoredAt = $Context.Execution.Elapsed.TotalMilliseconds
    $failureCountAfter = Wait-ForTEL07LogIncrease `
        $Context `
        $failureText `
        $failureCountBefore `
        "database failure $DisruptionNumber"
    $failureObservedAt = $Context.Execution.Elapsed.TotalMilliseconds
    $recoveryCountAfter = Wait-ForTEL07LogIncrease `
        $Context `
        $recoveryText `
        $recoveryCountBefore `
        "database recovery $DisruptionNumber"
    $recoveryObservedAt = $Context.Execution.Elapsed.TotalMilliseconds
    Add-TEL07ResourceSample $Context
    $Context.DatabaseOutages.Add([pscustomobject]@{
        Number = $DisruptionNumber
        StartedAtElapsedMilliseconds = $outageStartedAt
        RestoredAtElapsedMilliseconds = $restoredAt
        FailureObservedAtElapsedMilliseconds = $failureObservedAt
        RecoveryObservedAtElapsedMilliseconds = $recoveryObservedAt
        RecoveryAfterRestoreMilliseconds = $recoveryObservedAt - $restoredAt
        RequestedUnavailableSeconds = $OutageDurationSeconds
        FailureLogCountBefore = $failureCountBefore
        FailureLogCountAfter = $failureCountAfter
        RecoveryLogCountBefore = $recoveryCountBefore
        RecoveryLogCountAfter = $recoveryCountAfter
    })
}

function Wait-ForTEL07Settlement {
    param([pscustomobject]$Context)

    $deadline = (Get-Date).AddMinutes(5)

    while ((Get-Date) -lt $deadline) {
        Test-TEL07ProcessesAreHealthy $Context

        if (!(Test-OutstandingMessages $Context.Assembly)) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Disruption soak did not settle within five minutes."
}

function Get-TEL07PublisherResults {
    param(
        [pscustomobject[]]$Mix,
        [string]$OutputPath
    )

    $publishingResults = Get-PublishingLoadResult $OutputPath
    $results = [ordered]@{}

    foreach ($definition in $Mix) {
        $scenarioResult = $publishingResults |
            Where-Object { $_.ScenarioId -eq $definition.ScenarioId }
        $results[$definition.Name] = $scenarioResult.Load
    }

    return $results
}

function Test-TEL07PublisherAccounting {
    param(
        [pscustomobject[]]$Mix,
        [System.Collections.IDictionary]$PublisherResults
    )

    foreach ($definition in $Mix) {
        $result = $PublisherResults[$definition.Name]
        $requestsAreAccounted =
            $result.AttemptedRequests -eq $definition.ExpectedAttemptCount -and
            $result.CommittedRequests + $result.FailedRequests -eq
                $result.AttemptedRequests

        if (!$requestsAreAccounted) {
            return $false
        }
    }

    return $true
}

function Test-TEL07DurablePublishingBounds {
    param(
        [pscustomobject[]]$Mix,
        [System.Collections.IDictionary]$PublisherResults,
        [pscustomobject]$ScenarioOperations
    )

    foreach ($definition in $Mix) {
        $publisherResult = $PublisherResults[$definition.Name]
        $durableOperations = Get-ScenarioCount `
            $ScenarioOperations `
            $definition.ScenarioId
        $durableCountIsPossible =
            $durableOperations -ge $publisherResult.CommittedRequests -and
            $durableOperations -le $publisherResult.AttemptedRequests

        if (!$durableCountIsPossible) {
            return $false
        }
    }

    return $true
}

function Test-TEL07ReplacementParticipation {
    param(
        [pscustomobject]$Observation,
        [pscustomobject[]]$WorkerDeaths
    )

    foreach ($death in $WorkerDeaths) {
        $workerId = $death.ReplacementWorkerId
        $claims = $Observation.WorkerClaims.PSObject.Properties[$workerId]
        $effects = $Observation.WorkerEffects.PSObject.Properties[$workerId]

        if ($null -eq $claims -or
            $null -eq $effects -or
            $claims.Value -le 0 -or
            $effects.Value -le 0) {
            return $false
        }
    }

    return $true
}

function Invoke-TEL07DisruptionSoak {
    param(
        [string]$Assembly,
        [pscustomobject]$Database,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [int]$SlowDelayMilliseconds,
        [int]$EligibleHistoryCount,
        [int]$OutageDurationSeconds,
        [int]$ResourceSampleIntervalSeconds,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L07"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null
    $mix = Get-TEL07Mix $TargetRequestsPerSecond $DurationSeconds
    $success = $mix | Where-Object { $_.Name -eq "success" }
    $transient = $mix | Where-Object { $_.Name -eq "transient" }
    $permanent = $mix | Where-Object { $_.Name -eq "permanent" }
    $slow = $mix | Where-Object { $_.Name -eq "slow" }
    $rejectEveryPermanentInvocation = [int]::MaxValue
    $failureRules = @(
        $transient.ScenarioId,
        "2",
        $permanent.ScenarioId,
        [string]$rejectEveryPermanentInvocation)
    $cutoffUtc = [DateTimeOffset]::UtcNow.AddHours(-1)

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @(
            "prepare-cleanup-population",
            [string]$EligibleHistoryCount,
            $cutoffUtc.ToString("O")) `
        $scenarioDirectory `
        "prepare-eligible-history"
    $initial = Get-Observation $Assembly
    Save-Observation $initial $scenarioDirectory "initial"
    $eligibleHistoryIsReady =
        $initial.BusinessOperations -eq $EligibleHistoryCount -and
        $initial.OutboxMessages -eq $EligibleHistoryCount -and
        $initial.ProcessedMessages -eq $EligibleHistoryCount -and
        $initial.PendingMessages -eq 0 -and
        $initial.ProcessingMessages -eq 0 -and
        $initial.FailedMessages -eq 0

    if (!$eligibleHistoryIsReady) {
        throw "TE-L07 could not create the exact eligible history."
    }

    $activeWorkers = [System.Collections.Generic.List[object]]::new()
    $workerDeaths = [System.Collections.Generic.List[object]]::new()
    $databaseOutages = [System.Collections.Generic.List[object]]::new()
    $resourceSamples = [System.Collections.Generic.List[object]]::new()
    $publisher = $null
    $publisherCompleted = $false
    $context = $null
    $execution = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        for ($workerNumber = 1; $workerNumber -le 4; $workerNumber++) {
            $workerId = "TE-L07-worker-$workerNumber"
            $worker = Start-TEL07Worker `
                $Assembly `
                $workerId `
                $workerId `
                $slow.ScenarioId `
                $SlowDelayMilliseconds `
                $failureRules `
                $scenarioDirectory
            $activeWorkers.Add($worker)
        }

        $publisher = Start-TEL07Publisher `
            $Assembly `
            $mix `
            $DurationSeconds `
            $scenarioDirectory
        $context = [pscustomobject]@{
            Assembly = $Assembly
            Database = $Database
            DatabaseAvailable = $true
            ArtifactDirectory = $scenarioDirectory
            Execution = $execution
            Publisher = $publisher
            ActiveWorkers = $activeWorkers
            WorkerDeaths = $workerDeaths
            DatabaseOutages = $databaseOutages
            ResourceSamples = $resourceSamples
            ResourceSampleIntervalSeconds = $ResourceSampleIntervalSeconds
            NextResourceSampleAtSeconds = 0
            SlowScenarioId = $slow.ScenarioId
            SlowDelayMilliseconds = $SlowDelayMilliseconds
            FailureRules = $failureRules
        }
        Add-TEL07ResourceSample $context

        Wait-UntilTEL07Elapsed $context ([Math]::Max(3, $DurationSeconds * 0.05))
        Stop-TEL07ClaimedWorkerAndStartReplacement $context 1

        Wait-UntilTEL07Elapsed $context ([Math]::Max(5, $DurationSeconds * 0.08))
        Invoke-TEL07DatabaseOutage $context 1 $OutageDurationSeconds
        $afterFirstOutage = Get-Observation $Assembly
        Save-Observation $afterFirstOutage $scenarioDirectory "after-first-outage"

        Wait-UntilTEL07Elapsed $context ($DurationSeconds * 0.45)
        Stop-TEL07ClaimedWorkerAndStartReplacement $context 2

        Wait-UntilTEL07Elapsed $context ($DurationSeconds * 0.65)
        Invoke-TEL07DatabaseOutage $context 2 $OutageDurationSeconds

        Complete-LoggedProcess `
            $publisher `
            (($DurationSeconds + 180) * 1000)
        $publisherCompleted = $true
        $publisherResults = Get-TEL07PublisherResults `
            $mix `
            (Join-Path $scenarioDirectory "publisher.stdout.log")

        $settlement = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-ForTEL07Settlement $context
        $settlement.Stop()
        Add-TEL07ResourceSample $context
        $completed = Get-Observation $Assembly
        $completedStorage = Get-StorageObservation $Assembly
        Save-Observation $completed $scenarioDirectory "completed"
        Save-StorageObservation $completedStorage $scenarioDirectory "completed-storage"
    }
    finally {
        $execution.Stop()

        if ($null -ne $publisher -and !$publisherCompleted) {
            Stop-LoggedProcess $publisher | Out-Null
        }

        foreach ($worker in $activeWorkers) {
            Stop-Worker $worker.Process
        }

        if ($null -ne $context -and !$context.DatabaseAvailable) {
            Start-DogfoodDatabase $Database
        }
    }

    $allPublisherRequestsAreAccounted = Test-TEL07PublisherAccounting `
        $mix `
        $publisherResults
    $successPublisher = $publisherResults[$success.Name]
    $transientPublisher = $publisherResults[$transient.Name]
    $permanentPublisher = $publisherResults[$permanent.Name]
    $slowPublisher = $publisherResults[$slow.Name]
    $acknowledgedCommittedTotal =
        $successPublisher.CommittedRequests +
        $transientPublisher.CommittedRequests +
        $permanentPublisher.CommittedRequests +
        $slowPublisher.CommittedRequests
    $durableSuccess = Get-ScenarioCount `
        $completed.ScenarioOperations `
        $success.ScenarioId
    $durableTransient = Get-ScenarioCount `
        $completed.ScenarioOperations `
        $transient.ScenarioId
    $durablePermanent = Get-ScenarioCount `
        $completed.ScenarioOperations `
        $permanent.ScenarioId
    $durableSlow = Get-ScenarioCount `
        $completed.ScenarioOperations `
        $slow.ScenarioId
    $durableCommittedTotal =
        $durableSuccess +
        $durableTransient +
        $durablePermanent +
        $durableSlow
    $ambiguousCommitCount =
        $durableCommittedTotal - $acknowledgedCommittedTotal
    $durablePublishingBoundsHold = Test-TEL07DurablePublishingBounds `
        $mix `
        $publisherResults `
        $completed.ScenarioOperations
    $expectedProcessed =
        $durableSuccess +
        $durableTransient +
        $durableSlow
    $expectedFailed = $durablePermanent
    $expectedFailureRecordsWithoutInterruption =
        ($durableTransient * 2) +
        ($durablePermanent * 3)
    $interruptedFailureRecordingCount =
        $expectedFailureRecordsWithoutInterruption -
        $completed.FailedAttempts
    $interruptedFailureRecordingIsBounded =
        $interruptedFailureRecordingCount -ge 0 -and
        $interruptedFailureRecordingCount -le $workerDeaths.Count
    $minimumConsumerAttempts =
        ($durableTransient * 3) +
        ($durablePermanent * 3)
    $distinctEffects = $completed.Effects - $completed.DuplicateEffects
    $transientAttempts = Get-ScenarioCount `
        $completed.ScenarioAttempts `
        $transient.ScenarioId
    $permanentAttempts = Get-ScenarioCount `
        $completed.ScenarioAttempts `
        $permanent.ScenarioId
    $permanentFailureErrorPrefix =
        "$($permanent.ScenarioId) rejects consumer attempt "
    $terminalErrorShowsPermanentRejection =
        $completed.TerminalError -is [string] -and
        $completed.TerminalError.StartsWith($permanentFailureErrorPrefix)
    $replacementWorkersParticipated = Test-TEL07ReplacementParticipation `
        $completed `
        $workerDeaths.ToArray()
    $databaseRecoveredTwice =
        $databaseOutages.Count -eq 2 -and
        @($databaseOutages | Where-Object {
            $_.FailureLogCountAfter -gt $_.FailureLogCountBefore -and
            $_.RecoveryLogCountAfter -gt $_.RecoveryLogCountBefore
        }).Count -eq 2
    $deletedBeforeFirstOutage =
        $workerDeaths[0].ClaimObservation.BusinessOperations -
        $workerDeaths[0].ClaimObservation.OutboxMessages
    $deletedAfterFirstOutage =
        $afterFirstOutage.BusinessOperations -
        $afterFirstOutage.OutboxMessages
    $cleanupProgressedAcrossDisruption =
        $deletedBeforeFirstOutage -gt 0 -and
        $deletedAfterFirstOutage -gt $deletedBeforeFirstOutage
    $seededHistoryWasRemoved =
        $completed.BusinessOperations - $completed.OutboxMessages -eq
            $EligibleHistoryCount
    $durableResultsAreExact =
        $durablePublishingBoundsHold -and
        $completed.BusinessOperations -eq
            ($EligibleHistoryCount + $durableCommittedTotal) -and
        $completed.OutboxMessages -eq $durableCommittedTotal -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq $expectedProcessed -and
        $completed.FailedMessages -eq $expectedFailed -and
        $interruptedFailureRecordingIsBounded -and
        $completed.ConsumerAttempts -ge $minimumConsumerAttempts -and
        $distinctEffects -eq $expectedProcessed -and
        $transientAttempts -ge
            ($durableTransient * 3) -and
        $permanentAttempts -ge
            ($durablePermanent * 3) -and
        (Get-ScenarioCount `
            $completed.ScenarioEffects `
            $permanent.ScenarioId) -eq 0 -and
        $terminalErrorShowsPermanentRejection
    $passed =
        $eligibleHistoryIsReady -and
        $allPublisherRequestsAreAccounted -and
        $workerDeaths.Count -eq 2 -and
        $replacementWorkersParticipated -and
        $databaseRecoveredTwice -and
        $cleanupProgressedAcrossDisruption -and
        $seededHistoryWasRemoved -and
        $durableResultsAreExact
    $result = [ordered]@{
        Scenario = "TE-L07"
        TargetRequestsPerSecond = $TargetRequestsPerSecond
        DurationSeconds = $DurationSeconds
        WorkerCount = 4
        SlowDelayMilliseconds = $SlowDelayMilliseconds
        EligibleHistoryCount = $EligibleHistoryCount
        OutageDurationSeconds = $OutageDurationSeconds
        ResourceSampleIntervalSeconds = $ResourceSampleIntervalSeconds
        Mix = $mix
        PublisherResults = $publisherResults
        AllPublisherRequestsAreAccounted = $allPublisherRequestsAreAccounted
        AcknowledgedCommittedRequests = $acknowledgedCommittedTotal
        DurableCommittedRequests = $durableCommittedTotal
        AmbiguousCommitCount = $ambiguousCommitCount
        DurablePublishingBoundsHold = $durablePublishingBoundsHold
        ExpectedFailureRecordsWithoutInterruption =
            $expectedFailureRecordsWithoutInterruption
        InterruptedFailureRecordingCount =
            $interruptedFailureRecordingCount
        InterruptedFailureRecordingIsBounded =
            $interruptedFailureRecordingIsBounded
        WorkerDeaths = $workerDeaths
        ReplacementWorkersParticipated = $replacementWorkersParticipated
        DatabaseOutages = $databaseOutages
        DatabaseRecoveredTwice = $databaseRecoveredTwice
        CleanupProgressedAcrossDisruption = $cleanupProgressedAcrossDisruption
        SeededHistoryWasRemoved = $seededHistoryWasRemoved
        DistinctEffects = $distinctEffects
        DuplicateEffects = $completed.DuplicateEffects
        ResourceSamples = $resourceSamples
        SettlementTailMilliseconds = $settlement.Elapsed.TotalMilliseconds
        ObservationBeforeWork = $initial
        ObservationAfterFirstOutage = $afterFirstOutage
        ObservationAfterSettlement = $completed
        StorageAfterSettlement = $completedStorage
        DurableResultsAreExact = $durableResultsAreExact
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 16 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-DisruptionSoak.ps1"
    & $runner
}
