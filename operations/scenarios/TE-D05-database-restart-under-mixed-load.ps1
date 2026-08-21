function Get-TED05ScenarioCount {
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

function Wait-ForTED05OutagePoint {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId,
        [string]$SlowScenarioId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before the slow effect was persisted. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $slowEffects = Get-TED05ScenarioCount $observation.ScenarioEffects $SlowScenarioId

        if ($observation.ProcessingMessages -gt 0 -and
            $observation.ProcessedMessages -eq 0 -and
            $slowEffects -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not persist the slow effect within twenty seconds."
}

function Wait-ForTED05Completion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(60)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before draining the mixed load. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq 6 -and
            $observation.FailedMessages -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not drain the mixed load within sixty seconds."
}

function Invoke-TED05DatabaseRestartUnderMixedLoad {
    param(
        [string]$Assembly,
        [pscustomobject]$Database,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-D05"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $slowScenarioId = "TE-D05-slow"
    $successScenarioId = "TE-D05-success"
    $transientScenarioId = "TE-D05-transient"
    $permanentScenarioId = "TE-D05-permanent"

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", $slowScenarioId, "1") $scenarioDirectory "publish-slow"
    Invoke-LoggedProcess $Assembly @("publish", $successScenarioId, "4") $scenarioDirectory "publish-success"
    Invoke-LoggedProcess $Assembly @("publish", $transientScenarioId, "1") $scenarioDirectory "publish-transient"
    Invoke-LoggedProcess $Assembly @("publish", $permanentScenarioId, "1") $scenarioDirectory "publish-permanent"

    $workerId = "TE-D05-worker"
    $failureRules = @(
        $transientScenarioId,
        "2",
        $permanentScenarioId,
        "3")
    $worker = Start-PlannedWorker `
        $Assembly `
        $workerId `
        $slowScenarioId `
        10000 `
        $failureRules `
        $scenarioDirectory
    $workerLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
    $databaseRestored = $false

    try {
        $beforeOutage = Wait-ForTED05OutagePoint `
            $Assembly `
            $worker `
            $workerId `
            $slowScenarioId
        Save-Observation $beforeOutage $scenarioDirectory "before-outage"

        Stop-DogfoodDatabase $Database

        Wait-ForLogText `
            $worker `
            $workerLog `
            "processing iteration failed" `
            "Mixed-load worker"

        Start-DogfoodDatabase $Database
        $databaseRestored = $true

        $completed = Wait-ForTED05Completion $Assembly $worker $workerId
        Save-Observation $completed $scenarioDirectory "completed"

        Wait-ForLogText `
            $worker `
            $workerLog `
            "TinyEvents worker recovered after" `
            "Mixed-load worker"

        $workerSurvived = -not $worker.HasExited
    }
    finally {
        if (!$databaseRestored) {
            Start-DogfoodDatabase $Database
        }

        Stop-Worker $worker
    }

    $failureCounts = Get-WorkerFailureLogCounts $workerLog
    $slowEffects = Get-TED05ScenarioCount $completed.ScenarioEffects $slowScenarioId
    $successEffects = Get-TED05ScenarioCount $completed.ScenarioEffects $successScenarioId
    $transientEffects = Get-TED05ScenarioCount $completed.ScenarioEffects $transientScenarioId
    $permanentEffects = Get-TED05ScenarioCount $completed.ScenarioEffects $permanentScenarioId
    $transientAttempts = Get-TED05ScenarioCount $completed.ScenarioAttempts $transientScenarioId
    $permanentAttempts = Get-TED05ScenarioCount $completed.ScenarioAttempts $permanentScenarioId
    $processEffects = $completed.ProcessEffects.PSObject.Properties[[string]$worker.Id]
    $sameProcessRecordedEveryEffect =
        @($completed.ProcessEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $processEffects -and
        $processEffects.Value -eq 7
    $passed =
        $workerSurvived -and
        $failureCounts -contains 1 -and
        $sameProcessRecordedEveryEffect -and
        $completed.BusinessOperations -eq 7 -and
        $completed.OutboxMessages -eq 7 -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq 6 -and
        $completed.FailedMessages -eq 1 -and
        $completed.FailedAttempts -eq 5 -and
        $completed.ConsumerAttempts -eq 6 -and
        $completed.Effects -eq 7 -and
        $completed.DuplicateEffects -eq 1 -and
        $completed.TerminalError -eq "TE-D05-permanent rejects consumer attempt 3." -and
        $slowEffects -eq 2 -and
        $successEffects -eq 4 -and
        $transientEffects -eq 1 -and
        $permanentEffects -eq 0 -and
        $transientAttempts -eq 3 -and
        $permanentAttempts -eq 3

    $result = [ordered]@{
        Scenario = "TE-D05"
        Worker = $workerId
        LoggedFailureCounts = $failureCounts
        WorkerSurvived = $workerSurvived
        SameProcessRecordedEveryEffect = $sameProcessRecordedEveryEffect
        ScenarioEffects = $completed.ScenarioEffects
        ScenarioAttempts = $completed.ScenarioAttempts
        ObservationBeforeOutage = $beforeOutage
        ObservationAfterRecovery = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-DatabaseRecovery.ps1"
    & $runner -Scenario "TE-D05"
}
