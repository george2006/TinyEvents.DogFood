function Test-TEL06DWorkerProcessesAreRunning {
    param([System.Diagnostics.Process[]]$Workers)

    $exitedWorker = $Workers |
        Where-Object { $_.HasExited } |
        Select-Object -First 1

    if ($null -ne $exitedWorker) {
        throw "Cleanup-under-load worker $($exitedWorker.Id) exited before settlement."
    }
}

function Wait-ForTEL06DCleanupOverlap {
    param(
        [pscustomobject]$Publisher,
        [System.Diagnostics.Process[]]$Workers,
        [string[]]$WorkerLogPaths
    )

    while (!$Publisher.Process.HasExited) {
        Test-TEL06DWorkerProcessesAreRunning $Workers

        $cleanupWasObserved = @(
            $WorkerLogPaths |
                Where-Object {
                    (Test-Path -LiteralPath $_) -and
                    (Select-String `
                        -LiteralPath $_ `
                        -SimpleMatch "TinyEvents deleted " `
                        -Quiet)
                }).Count -gt 0

        if ($cleanupWasObserved) {
            return $true
        }

        Start-Sleep -Milliseconds 100
    }

    return $false
}

function Wait-ForTEL06DSettlement {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers
    )

    $deadline = (Get-Date).AddMinutes(5)

    while ((Get-Date) -lt $deadline) {
        Test-TEL06DWorkerProcessesAreRunning $Workers

        if (!(Test-OutstandingMessages $Assembly)) {
            return
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Cleanup-under-load work did not settle within five minutes."
}

function Start-TEL06DWorkers {
    param(
        [string]$Assembly,
        [string[]]$WorkerIds,
        [bool]$CleanupEnabled,
        [string]$ArtifactDirectory
    )

    return @(
        foreach ($workerId in $WorkerIds) {
            if ($CleanupEnabled) {
                Start-CleanupWorker `
                    $Assembly `
                    $workerId `
                    3600 `
                    1000 `
                    1000 `
                    $ArtifactDirectory
            }
            else {
                Start-Worker `
                    $Assembly `
                    $workerId `
                    0 `
                    0 `
                    $ArtifactDirectory
            }
        })
}

function Invoke-TEL06DVariant {
    param(
        [string]$Assembly,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [int]$WorkerCount,
        [int]$EligibleHistoryCount,
        [bool]$CleanupEnabled,
        [string]$ArtifactDirectory
    )

    $variantName = if ($CleanupEnabled) { "candidate" } else { "baseline" }
    $variantDirectory = Join-Path $ArtifactDirectory $variantName
    New-Item -ItemType Directory -Force -Path $variantDirectory | Out-Null

    $activeScenarioId = "TE-L06-D-$TargetRequestsPerSecond-$variantName"
    $expectedActiveMessageCount =
        $TargetRequestsPerSecond * $DurationSeconds
    $cutoffUtc = [DateTimeOffset]::UtcNow.AddHours(-1)
    $cutoffArgument = $cutoffUtc.ToString("O")

    Invoke-LoggedProcess $Assembly @("reset") $variantDirectory "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @(
            "prepare-cleanup-population",
            [string]$EligibleHistoryCount,
            $cutoffArgument) `
        $variantDirectory `
        "prepare-eligible-history"

    $before = Get-Observation $Assembly
    Save-Observation $before $variantDirectory "before-active-load"
    $eligibleHistoryIsReady =
        $before.BusinessOperations -eq $EligibleHistoryCount -and
        $before.OutboxMessages -eq $EligibleHistoryCount -and
        $before.PendingMessages -eq 0 -and
        $before.ProcessingMessages -eq 0 -and
        $before.ProcessedMessages -eq $EligibleHistoryCount -and
        $before.FailedMessages -eq 0 -and
        $before.FailedAttempts -eq 0 -and
        $before.Effects -eq 0

    if (!$eligibleHistoryIsReady) {
        throw "TE-L06-D could not create the exact eligible history."
    }

    $workerIds = @(
        for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
            "TE-L06-D-$TargetRequestsPerSecond-$variantName-worker-$workerNumber"
        })
    $workerLogPaths = @(
        $workerIds | ForEach-Object {
            Join-Path $variantDirectory "$_.stdout.log"
        })
    $workers = @()
    $publisher = $null
    $workload = [System.Diagnostics.Stopwatch]::new()
    $settlement = [System.Diagnostics.Stopwatch]::new()
    $cleanupOverlappedPublishing = $null

    try {
        $workload.Start()
        $publisher = Start-LoggedDotNetProcess `
            $Assembly `
            @(
                "publish-load",
                $activeScenarioId,
                [string]$TargetRequestsPerSecond,
                [string]$DurationSeconds) `
            $variantDirectory `
            "publisher"
        $workers = Start-TEL06DWorkers `
            $Assembly `
            $workerIds `
            $CleanupEnabled `
            $variantDirectory

        if ($CleanupEnabled) {
            $cleanupOverlappedPublishing = Wait-ForTEL06DCleanupOverlap `
                $publisher `
                $workers `
                $workerLogPaths
        }

        Complete-LoggedProcess $publisher 180000
        $publisherResult = Get-PublishingLoadResult `
            (Join-Path $variantDirectory "publisher.stdout.log")

        $settlement.Start()
        Wait-ForTEL06DSettlement $Assembly $workers

        foreach ($worker in $workers) {
            Stop-Worker $worker
        }

        $settlement.Stop()
        $workload.Stop()
        $after = Get-Observation $Assembly
        Save-Observation $after $variantDirectory "after-settlement"
    }
    finally {
        $settlement.Stop()
        $workload.Stop()

        if ($null -ne $publisher -and
            !$publisher.Process.HasExited) {
            Stop-LoggedProcess $publisher | Out-Null
        }

        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    $remainingEligibleHistory =
        $after.OutboxMessages - $expectedActiveMessageCount
    $eligibleHistoryDeleted =
        $EligibleHistoryCount - $remainingEligibleHistory
    $historyAccountingIsValid =
        $remainingEligibleHistory -ge 0 -and
        $remainingEligibleHistory -le $EligibleHistoryCount
    $allRequestsCommitted =
        $publisherResult.AttemptedRequests -eq $expectedActiveMessageCount -and
        $publisherResult.CommittedRequests -eq $expectedActiveMessageCount -and
        $publisherResult.FailedRequests -eq 0
    $activeScenarioEffects = Get-ScenarioCount `
        $after.ScenarioEffects `
        $activeScenarioId
    $activeResultsAreExact =
        $after.BusinessOperations -eq
            ($EligibleHistoryCount + $expectedActiveMessageCount) -and
        $after.OutboxMessages -eq
            ($remainingEligibleHistory + $expectedActiveMessageCount) -and
        $after.PendingMessages -eq 0 -and
        $after.ProcessingMessages -eq 0 -and
        $after.ProcessedMessages -eq $after.OutboxMessages -and
        $after.FailedMessages -eq 0 -and
        $after.FailedAttempts -eq 0 -and
        $after.Effects -eq $expectedActiveMessageCount -and
        $after.DuplicateEffects -eq 0 -and
        $activeScenarioEffects -eq $expectedActiveMessageCount
    $allWorkersParticipated = Test-AllWorkersParticipated $after $workerIds
    $cleanupBehaviorIsCorrect = if ($CleanupEnabled) {
        $cleanupOverlappedPublishing -and $eligibleHistoryDeleted -gt 0
    }
    else {
        $eligibleHistoryDeleted -eq 0
    }
    $workloadSeconds = [Math]::Max($workload.Elapsed.TotalSeconds, 0.001)
    $passed =
        $eligibleHistoryIsReady -and
        $historyAccountingIsValid -and
        $allRequestsCommitted -and
        $activeResultsAreExact -and
        $allWorkersParticipated -and
        $cleanupBehaviorIsCorrect

    $result = [ordered]@{
        Variant = $variantName
        CleanupEnabled = $CleanupEnabled
        TargetRequestsPerSecond = $TargetRequestsPerSecond
        DurationSeconds = $DurationSeconds
        WorkerCount = $WorkerCount
        EligibleHistoryCount = $EligibleHistoryCount
        ExpectedActiveMessageCount = $expectedActiveMessageCount
        PublisherLoad = $publisherResult
        WorkloadDurationMilliseconds = $workload.Elapsed.TotalMilliseconds
        SettlementTailMilliseconds = $settlement.Elapsed.TotalMilliseconds
        CleanupOverlappedPublishing = $cleanupOverlappedPublishing
        RemainingEligibleHistory = $remainingEligibleHistory
        EligibleHistoryDeleted = $eligibleHistoryDeleted
        CleanupMessagesPerSecond = [Math]::Round(
            $eligibleHistoryDeleted / $workloadSeconds,
            2)
        EligibleHistoryWasReady = $eligibleHistoryIsReady
        HistoryAccountingIsValid = $historyAccountingIsValid
        AllRequestsCommitted = $allRequestsCommitted
        ActiveResultsAreExact = $activeResultsAreExact
        AllWorkersParticipated = $allWorkersParticipated
        WorkerClaims = $after.WorkerClaims
        WorkerEffects = $after.WorkerEffects
        ObservationBeforeActiveLoad = $before
        ObservationAfterSettlement = $after
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $variantDirectory "result.json")
    return [pscustomobject]$result
}

function Get-TEL06DRelativePercentage {
    param(
        [double]$CandidateValue,
        [double]$BaselineValue
    )

    if ($BaselineValue -eq 0) {
        return $null
    }

    return [Math]::Round(100 * $CandidateValue / $BaselineValue, 2)
}

function Invoke-TEL06DRate {
    param(
        [string]$Assembly,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [int]$WorkerCount,
        [int]$EligibleHistoryCount,
        [string]$ArtifactDirectory
    )

    $rateDirectory = Join-Path `
        $ArtifactDirectory `
        "$TargetRequestsPerSecond-requests-per-second"
    New-Item -ItemType Directory -Force -Path $rateDirectory | Out-Null

    $baseline = Invoke-TEL06DVariant `
        $Assembly `
        $TargetRequestsPerSecond `
        $DurationSeconds `
        $WorkerCount `
        $EligibleHistoryCount `
        $false `
        $rateDirectory
    $candidate = Invoke-TEL06DVariant `
        $Assembly `
        $TargetRequestsPerSecond `
        $DurationSeconds `
        $WorkerCount `
        $EligibleHistoryCount `
        $true `
        $rateDirectory

    $comparison = [ordered]@{
        PublishingThroughputPercentageOfBaseline =
            Get-TEL06DRelativePercentage `
                $candidate.PublisherLoad.CommittedRequestsPerSecond `
                $baseline.PublisherLoad.CommittedRequestsPerSecond
        PublishingP95PercentageOfBaseline =
            Get-TEL06DRelativePercentage `
                $candidate.PublisherLoad.CommittedP95LatencyMilliseconds `
                $baseline.PublisherLoad.CommittedP95LatencyMilliseconds
        PublishingP99PercentageOfBaseline =
            Get-TEL06DRelativePercentage `
                $candidate.PublisherLoad.CommittedP99LatencyMilliseconds `
                $baseline.PublisherLoad.CommittedP99LatencyMilliseconds
        WorkloadDurationPercentageOfBaseline =
            Get-TEL06DRelativePercentage `
                $candidate.WorkloadDurationMilliseconds `
                $baseline.WorkloadDurationMilliseconds
        SettlementTailPercentageOfBaseline =
            Get-TEL06DRelativePercentage `
                $candidate.SettlementTailMilliseconds `
                $baseline.SettlementTailMilliseconds
    }
    $result = [ordered]@{
        TargetRequestsPerSecond = $TargetRequestsPerSecond
        Baseline = $baseline
        Candidate = $candidate
        Comparison = $comparison
        AcceptancePassed =
            $baseline.AcceptancePassed -and
            $candidate.AcceptancePassed
    }

    $result |
        ConvertTo-Json -Depth 12 |
        Set-Content (Join-Path $rateDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-TEL06CleanupUnderLoad {
    param(
        [string]$Assembly,
        [int[]]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [int]$WorkerCount,
        [int]$EligibleHistoryCount,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L06-D"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null
    $rates = @(
        foreach ($targetRate in $TargetRequestsPerSecond) {
            Invoke-TEL06DRate `
                $Assembly `
                $targetRate `
                $DurationSeconds `
                $WorkerCount `
                $EligibleHistoryCount `
                $scenarioDirectory
        })
    $result = [ordered]@{
        Scenario = "TE-L06-D"
        Measurement = "Active load with cleanup disabled and enabled"
        ProcessedRetentionSeconds = 3600
        CleanupBatchSize = 1000
        CleanupIntervalMilliseconds = 1000
        OutstandingWorkProbeIntervalMilliseconds = 250
        Rates = $rates
        AcceptancePassed = $rates.AcceptancePassed -notcontains $false
    }

    $result |
        ConvertTo-Json -Depth 14 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-CleanupUnderLoad.ps1"
    & $runner
}
