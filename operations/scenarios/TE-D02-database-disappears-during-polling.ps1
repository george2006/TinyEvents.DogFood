function Invoke-TED02DatabaseDisappearsDuringPolling {
    param(
        [string]$Assembly,
        [string]$ComposeFile,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-D02"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-D02-before", "1") $scenarioDirectory "publish-before"

    $workerId = "TE-D02-worker"
    $worker = Start-Worker $Assembly $workerId 0 0 $scenarioDirectory
    $workerLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
    $sqlServerRestored = $false

    try {
        $beforeOutage = Wait-ForCompletedMessages $Assembly $worker $workerId 1
        Save-Observation $beforeOutage $scenarioDirectory "before-outage"

        Stop-SqlServer $ComposeFile

        Wait-ForLogText `
            $worker `
            $workerLog `
            "has failed 5 consecutive processing iterations" `
            "Polling worker"

        Start-SqlServer $ComposeFile
        $sqlServerRestored = $true

        Wait-ForLogText `
            $worker `
            $workerLog `
            "TinyEvents worker recovered after" `
            "Polling worker"

        Invoke-LoggedProcess `
            $Assembly `
            @("publish", "TE-D02-after", "1") `
            $scenarioDirectory `
            "publish-after"

        $completed = Wait-ForCompletedMessages $Assembly $worker $workerId 2
        Save-Observation $completed $scenarioDirectory "after-recovery"
        $workerSurvived = -not $worker.HasExited
    }
    finally {
        if (!$sqlServerRestored) {
            Start-SqlServer $ComposeFile
        }

        Stop-Worker $worker
    }

    $failureCounts = Get-WorkerFailureLogCounts $workerLog
    $processEffects = $completed.ProcessEffects.PSObject.Properties[[string]$worker.Id]
    $sameProcessCompletedBothMessages =
        @($completed.ProcessEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $processEffects -and
        $processEffects.Value -eq 2
    $passed =
        $workerSurvived -and
        $sameProcessCompletedBothMessages -and
        $failureCounts -contains 5 -and
        (Test-WorkerCompletedMessagesResult $completed $workerId 2)

    $result = [ordered]@{
        Scenario = "TE-D02"
        Worker = $workerId
        LoggedFailureCounts = $failureCounts
        WorkerSurvived = $workerSurvived
        SameProcessCompletedBothMessages = $sameProcessCompletedBothMessages
        ObservationBeforeOutage = $beforeOutage
        ObservationAfterRecovery = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-DatabaseRecovery.ps1"
    & $runner -Scenario "TE-D02"
}
