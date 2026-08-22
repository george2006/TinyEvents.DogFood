function Start-TEL04Publisher {
    param(
        [string]$Assembly,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [string]$ArtifactDirectory
    )

    return Start-LoggedDotNetProcess `
        $Assembly `
        @(
            "publish-load",
            "TE-L04",
            [string]$TargetRequestsPerSecond,
            [string]$DurationSeconds) `
        $ArtifactDirectory `
        "publisher"
}

function Wait-ForTEL04Backlog {
    param(
        [string]$Assembly,
        [pscustomobject]$Publisher,
        [int]$BacklogTarget
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        if ($Publisher.Process.HasExited) {
            throw "Publisher exited before building the $BacklogTarget-message backlog."
        }

        $observation = Get-Observation $Assembly

        if ($observation.PendingMessages -ge $BacklogTarget -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 0 -and
            $observation.Effects -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Publisher did not build the $BacklogTarget-message backlog within two minutes."
}

function Wait-ForTEL04CatchUp {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [pscustomobject]$Publisher,
        [int]$InitialBacklog,
        [int]$RecoveryThreshold
    )

    while (!$Publisher.Process.HasExited) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Recovery worker $($exitedWorker.Id) exited before catching up."
        }

        $observation = Get-Observation $Assembly

        $outstandingMessages =
            $observation.PendingMessages +
            $observation.ProcessingMessages
        $historicalBacklogWasProcessed =
            $observation.ProcessedMessages -ge $InitialBacklog
        $publisherContinuedAfterWorkersStarted =
            $observation.BusinessOperations -gt $InitialBacklog

        if ($outstandingMessages -le $RecoveryThreshold -and
            $historicalBacklogWasProcessed -and
            $publisherContinuedAfterWorkersStarted -and
            !$Publisher.Process.HasExited) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    return $null
}

function Wait-ForTEL04Completion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [int]$ExpectedMessageCount
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Recovery worker $($exitedWorker.Id) exited before final settlement."
        }

        $observation = Get-Observation $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq $ExpectedMessageCount) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Live backlog recovery did not settle within two minutes."
}

function Invoke-TEL04LiveBacklogRecovery {
    param(
        [string]$Assembly,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [int]$BacklogTarget,
        [int]$WorkerCount,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L04"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"

    $workerIds = @(
        for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
            "TE-L04-worker-$workerNumber"
        })
    $workers = @()
    $publisher = $null
    $recovery = [System.Diagnostics.Stopwatch]::new()
    $recoveryThreshold = $TargetRequestsPerSecond

    try {
        $publisher = Start-TEL04Publisher `
            $Assembly `
            $TargetRequestsPerSecond `
            $DurationSeconds `
            $scenarioDirectory
        $backlog = Wait-ForTEL04Backlog `
            $Assembly `
            $publisher `
            $BacklogTarget
        Save-Observation $backlog $scenarioDirectory "before-workers"

        $recovery.Start()
        $workers = @(
            foreach ($workerId in $workerIds) {
                Start-Worker $Assembly $workerId 0 0 $scenarioDirectory
            })
        $recovered = Wait-ForTEL04CatchUp `
            $Assembly `
            $workers `
            $publisher `
            $backlog.PendingMessages `
            $recoveryThreshold
        $recovery.Stop()

        if ($null -ne $recovered) {
            Save-Observation $recovered $scenarioDirectory "backlog-recovered"
        }

        Complete-LoggedProcess $publisher 120000
        $publisherResult = Get-PublishingLoadResult `
            (Join-Path $scenarioDirectory "publisher.stdout.log")
        $completed = Wait-ForTEL04Completion `
            $Assembly `
            $workers `
            $publisherResult.CommittedRequests
        Save-Observation $completed $scenarioDirectory "completed"
    }
    finally {
        $recovery.Stop()

        if ($null -ne $publisher -and
            !$publisher.Process.HasExited) {
            Stop-LoggedProcess $publisher | Out-Null
        }

        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    $expectedMessageCount = $TargetRequestsPerSecond * $DurationSeconds
    $recoveredWhilePublishing = $null -ne $recovered
    $allWorkersParticipated = Test-AllWorkersParticipated $completed $workerIds
    $publisherCommittedEverything =
        $publisherResult.AttemptedRequests -eq $expectedMessageCount -and
        $publisherResult.CommittedRequests -eq $expectedMessageCount -and
        $publisherResult.FailedRequests -eq 0
    $passed =
        $publisherCommittedEverything -and
        $recoveredWhilePublishing -and
        $allWorkersParticipated -and
        $backlog.PendingMessages -ge $BacklogTarget -and
        $backlog.ProcessingMessages -eq 0 -and
        $backlog.ProcessedMessages -eq 0 -and
        $backlog.Effects -eq 0 -and
        $completed.BusinessOperations -eq $expectedMessageCount -and
        $completed.OutboxMessages -eq $expectedMessageCount -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq $expectedMessageCount -and
        $completed.FailedMessages -eq 0 -and
        $completed.FailedAttempts -eq 0 -and
        $completed.Effects -eq $expectedMessageCount -and
        $completed.DuplicateEffects -eq 0

    $result = [ordered]@{
        Scenario = "TE-L04"
        TargetRequestsPerSecond = $TargetRequestsPerSecond
        DurationSeconds = $DurationSeconds
        BacklogTarget = $BacklogTarget
        BacklogAtWorkerStart = $backlog.PendingMessages
        BacklogRecoveryThreshold = $recoveryThreshold
        WorkerCount = $WorkerCount
        PublisherResult = $publisherResult
        RecoveredWhilePublishing = $recoveredWhilePublishing
        RecoveryDurationMilliseconds = $recovery.Elapsed.TotalMilliseconds
        ObservationPollingIntervalMilliseconds = 100
        AllWorkersParticipated = $allWorkersParticipated
        WorkerClaims = $completed.WorkerClaims
        WorkerEffects = $completed.WorkerEffects
        ObservationBeforeWorkers = $backlog
        ObservationAtBacklogRecovery = $recovered
        ObservationAfterSettlement = $completed
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-BacklogRecoveryLoad.ps1"
    & $runner
}
