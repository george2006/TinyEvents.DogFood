function Invoke-TED01DatabaseUnavailableAtStartup {
    param(
        [string]$Assembly,
        [string]$ComposeFile,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-D01"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-D01", "1") $scenarioDirectory "publish"

    Stop-SqlServer $ComposeFile

    $workerId = "TE-D01-worker"
    $worker = Start-Worker $Assembly $workerId 0 0 $scenarioDirectory
    $workerLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
    $sqlServerRestored = $false

    try {
        Wait-ForLogText `
            $worker `
            $workerLog `
            "has failed 5 consecutive processing iterations" `
            "Database recovery worker"

        Start-SqlServer $ComposeFile
        $sqlServerRestored = $true

        $completed = Wait-ForCompletion $Assembly $worker $workerId
        Save-Observation $completed $scenarioDirectory "completed"

        Wait-ForLogText `
            $worker `
            $workerLog `
            "TinyEvents worker recovered after" `
            "Database recovery worker"

        $workerSurvived = -not $worker.HasExited
    }
    finally {
        if (!$sqlServerRestored) {
            Start-SqlServer $ComposeFile
        }

        Stop-Worker $worker
    }

    $failureCounts = Get-WorkerFailureLogCounts $workerLog
    $maximumFailureCount = ($failureCounts | Measure-Object -Maximum).Maximum
    $loggedInitialFailures =
        $failureCounts -contains 1 -and
        $failureCounts -contains 2 -and
        $failureCounts -contains 3 -and
        $failureCounts -contains 4 -and
        $failureCounts -contains 5
    $failureLoggingWasBounded = $failureCounts.Count -lt $maximumFailureCount
    $passed =
        $loggedInitialFailures -and
        $failureLoggingWasBounded -and
        $workerSurvived -and
        (Test-WorkerOwnsResult $completed $workerId)

    $result = [ordered]@{
        Scenario = "TE-D01"
        Worker = $workerId
        LoggedFailureCounts = $failureCounts
        MaximumConsecutiveFailureCount = $maximumFailureCount
        FailureLoggingWasBounded = $failureLoggingWasBounded
        WorkerSurvived = $workerSurvived
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-DatabaseRecovery.ps1"
    & $runner -Scenario "TE-D01"
}
