function Wait-ForTEL05ProcessedCount {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [int]$ExpectedProcessedCount
    )

    $deadline = (Get-Date).AddMinutes(15)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Retained-history worker $($exitedWorker.Id) exited before processing completed."
        }

        if (!(Test-OutstandingMessages $Assembly)) {
            $observation = Get-Observation $Assembly
            $expectedTerminalStateWasReached =
                $observation.PendingMessages -eq 0 -and
                $observation.ProcessingMessages -eq 0 -and
                $observation.ProcessedMessages -eq $ExpectedProcessedCount -and
                $observation.FailedMessages -eq 0

            if ($expectedTerminalStateWasReached) {
                return $observation
            }

            throw "Outbox work stopped without reaching $ExpectedProcessedCount processed messages."
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Workers did not reach $ExpectedProcessedCount processed messages within fifteen minutes."
}

function Test-TEL05WorkerResults {
    param(
        [pscustomobject]$Observation,
        [string[]]$WorkerIds,
        [int]$ExpectedMessageCount
    )

    $claimedMessages = 0
    $completedEffects = 0

    foreach ($workerId in $WorkerIds) {
        $claims = $Observation.WorkerClaims.PSObject.Properties[$workerId]
        $effects = $Observation.WorkerEffects.PSObject.Properties[$workerId]

        if ($null -eq $claims -or
            $null -eq $effects -or
            $claims.Value -le 0 -or
            $claims.Value -ne $effects.Value) {
            return $false
        }

        $claimedMessages += $claims.Value
        $completedEffects += $effects.Value
    }

    return (
        $claimedMessages -eq $ExpectedMessageCount -and
        $completedEffects -eq $ExpectedMessageCount)
}

function Invoke-TEL05Drain {
    param(
        [string]$Assembly,
        [string]$ScenarioId,
        [int]$MessageCount,
        [int]$ExpectedProcessedCount,
        [int]$WorkerCount,
        [int]$WorkerBatchSize,
        [string]$ArtifactDirectory,
        [string]$EvidenceName
    )

    $workerIds = @(
        for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
            "$EvidenceName-worker-$workerNumber"
        })
    $workers = @()
    $drain = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $workers = @(
            foreach ($workerId in $workerIds) {
                Start-BatchWorker `
                    $Assembly `
                    $workerId `
                    $WorkerBatchSize `
                    0 `
                    0 `
                    $ArtifactDirectory
            })
        $after = Wait-ForTEL05ProcessedCount `
            $Assembly `
            $workers `
            $ExpectedProcessedCount
        $drain.Stop()
        Save-Observation $after $ArtifactDirectory "$EvidenceName-after-drain"
    }
    finally {
        $drain.Stop()

        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    $workerResultsAreExact = Test-TEL05WorkerResults `
        $after `
        $workerIds `
        $MessageCount
    $scenarioEffects = Get-ScenarioCount `
        $after.ScenarioEffects `
        $ScenarioId
    $durationSeconds = [Math]::Max($drain.Elapsed.TotalSeconds, 0.001)

    return [pscustomobject][ordered]@{
        ScenarioId = $ScenarioId
        MessageCount = $MessageCount
        DurationMilliseconds = $drain.Elapsed.TotalMilliseconds
        MessagesPerSecond = [Math]::Round(
            $MessageCount / $durationSeconds,
            2)
        WorkerIds = $workerIds
        WorkerResultsAreExact = $workerResultsAreExact
        ScenarioEffects = $scenarioEffects
        Observation = $after
        AcceptancePassed =
            $workerResultsAreExact -and
            $scenarioEffects -eq $MessageCount -and
            $after.PendingMessages -eq 0 -and
            $after.ProcessingMessages -eq 0 -and
            $after.ProcessedMessages -eq $ExpectedProcessedCount -and
            $after.FailedMessages -eq 0 -and
            $after.FailedAttempts -eq 0 -and
            $after.DuplicateEffects -eq 0
    }
}

function Invoke-TEL05RetainedHistoryVariant {
    param(
        [string]$Assembly,
        [int]$RetainedHistoryCount,
        [int]$ActiveBacklog,
        [int]$WorkerCount,
        [int]$WorkerBatchSize,
        [string]$ArtifactDirectory
    )

    $variantName = "$RetainedHistoryCount-retained"
    $variantDirectory = Join-Path $ArtifactDirectory $variantName
    New-Item -ItemType Directory -Force -Path $variantDirectory | Out-Null
    Invoke-LoggedProcess $Assembly @("reset") $variantDirectory "reset"
    $historyResult = $null

    if ($RetainedHistoryCount -gt 0) {
        $historyScenarioId = "TE-L05-C-history-$RetainedHistoryCount"
        Invoke-LoggedProcess `
            $Assembly `
            @("publish", $historyScenarioId, [string]$RetainedHistoryCount) `
            $variantDirectory `
            "publish-history"
        $historyResult = Invoke-TEL05Drain `
            $Assembly `
            $historyScenarioId `
            $RetainedHistoryCount `
            $RetainedHistoryCount `
            $WorkerCount `
            $WorkerBatchSize `
            $variantDirectory `
            "$variantName-history"

        if (!$historyResult.AcceptancePassed) {
            throw "TE-L05-C could not create $RetainedHistoryCount exact retained rows."
        }
    }

    $beforeActiveBacklog = Get-Observation $Assembly
    $historyStorage = Get-StorageObservation $Assembly
    Save-Observation $beforeActiveBacklog $variantDirectory "before-active-backlog"
    Save-StorageObservation $historyStorage $variantDirectory "history-storage"
    $historyIsReady =
        $beforeActiveBacklog.OutboxMessages -eq $RetainedHistoryCount -and
        $beforeActiveBacklog.PendingMessages -eq 0 -and
        $beforeActiveBacklog.ProcessingMessages -eq 0 -and
        $beforeActiveBacklog.ProcessedMessages -eq $RetainedHistoryCount -and
        $beforeActiveBacklog.FailedMessages -eq 0 -and
        $beforeActiveBacklog.Effects -eq $RetainedHistoryCount -and
        $beforeActiveBacklog.DuplicateEffects -eq 0

    if (!$historyIsReady) {
        throw "TE-L05-C did not reach the expected $RetainedHistoryCount-row history boundary."
    }

    $activeScenarioId = "TE-L05-C-active-$RetainedHistoryCount"
    Invoke-LoggedProcess `
        $Assembly `
        @("publish", $activeScenarioId, [string]$ActiveBacklog) `
        $variantDirectory `
        "publish-active-backlog"
    $beforeDrain = Get-Observation $Assembly
    Save-Observation $beforeDrain $variantDirectory "before-active-drain"
    $activeBacklogIsReady =
        $beforeDrain.OutboxMessages -eq ($RetainedHistoryCount + $ActiveBacklog) -and
        $beforeDrain.PendingMessages -eq $ActiveBacklog -and
        $beforeDrain.ProcessingMessages -eq 0 -and
        $beforeDrain.ProcessedMessages -eq $RetainedHistoryCount -and
        $beforeDrain.FailedMessages -eq 0 -and
        $beforeDrain.Effects -eq $RetainedHistoryCount -and
        $beforeDrain.DuplicateEffects -eq 0

    if (!$activeBacklogIsReady) {
        throw "TE-L05-C could not build the exact active backlog after $RetainedHistoryCount retained rows."
    }

    $activeResult = Invoke-TEL05Drain `
        $Assembly `
        $activeScenarioId `
        $ActiveBacklog `
        ($RetainedHistoryCount + $ActiveBacklog) `
        $WorkerCount `
        $WorkerBatchSize `
        $variantDirectory `
        "$variantName-active"

    $result = [ordered]@{
        RetainedHistoryCount = $RetainedHistoryCount
        ActiveBacklog = $ActiveBacklog
        HistoryStorage = $historyStorage
        HistoryBuild = $historyResult
        ActiveDrainDurationMilliseconds = $activeResult.DurationMilliseconds
        ActiveDrainMessagesPerSecond = $activeResult.MessagesPerSecond
        ActiveDrain = $activeResult
        AcceptancePassed = $historyIsReady -and $activeResult.AcceptancePassed
    }

    $result |
        ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $variantDirectory "result.json")
    return [pscustomobject]$result
}

function Add-TEL05HistoryComparison {
    param([pscustomobject[]]$Variants)

    $emptyHistory = $Variants |
        Where-Object { $_.RetainedHistoryCount -eq 0 } |
        Select-Object -First 1

    foreach ($variant in $Variants) {
        $relativeThroughput =
            100 *
            $variant.ActiveDrainMessagesPerSecond /
            $emptyHistory.ActiveDrainMessagesPerSecond
        $variant | Add-Member `
            -NotePropertyName "ThroughputComparedToEmptyHistoryPercentage" `
            -NotePropertyValue ([Math]::Round($relativeThroughput, 2))
    }
}

function Invoke-TEL05RetainedHistoryLoad {
    param(
        [string]$Assembly,
        [int[]]$RetainedHistoryCounts,
        [int]$ActiveBacklog,
        [int]$WorkerCount,
        [int]$WorkerBatchSize,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L05-retained-history"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null
    $variants = @(
        foreach ($historyCount in $RetainedHistoryCounts) {
            Invoke-TEL05RetainedHistoryVariant `
                $Assembly `
                $historyCount `
                $ActiveBacklog `
                $WorkerCount `
                $WorkerBatchSize `
                $scenarioDirectory
        })
    Add-TEL05HistoryComparison $variants
    $result = [ordered]@{
        Scenario = "TE-L05-C"
        Measurement = "Active drain with retained processed history"
        CompletionProbeIntervalMilliseconds = 250
        WorkerCount = $WorkerCount
        WorkerBatchSize = $WorkerBatchSize
        Variants = $variants
        AcceptancePassed = $variants.AcceptancePassed -notcontains $false
    }

    $result |
        ConvertTo-Json -Depth 12 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-RetainedHistoryLoad.ps1"
    & $runner
}
