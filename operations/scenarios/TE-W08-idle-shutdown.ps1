function Invoke-TEW08IdleShutdown {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W08-idle"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"

    $workerId = "TE-W08-idle-worker"
    $workerHandle = Start-TimedWorker $Assembly $workerId 1000 0 0 $scenarioDirectory

    try {
        Wait-ForWorkerExit $workerHandle $workerId
        $observation = Get-Observation -Assembly $Assembly
        Save-Observation $observation $scenarioDirectory "after-shutdown"

        $workerLog = Get-Content (Join-Path $scenarioDirectory "$workerId.stdout.log") -Raw
        $reportedGracefulShutdown = $workerLog.Contains("Application is shutting down")
        $passed =
            $reportedGracefulShutdown -and
            $observation.BusinessOperations -eq 0 -and
            $observation.OutboxMessages -eq 0 -and
            $observation.Effects -eq 0 -and
            @($observation.WorkerClaims.PSObject.Properties).Count -eq 0 -and
            @($observation.WorkerEffects.PSObject.Properties).Count -eq 0
    }
    finally {
        Stop-Worker $workerHandle.Process
    }

    $result = [ordered]@{
        Scenario = "TE-W08-idle"
        ExitCode = $workerHandle.Process.ExitCode
        ReportedGracefulShutdown = $reportedGracefulShutdown
        Observation = $observation
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W08-idle"
}
