if ($null -eq (Get-Variable -Name WorkerDiagnosticHandles -Scope Script -ErrorAction SilentlyContinue)) {
    $script:WorkerDiagnosticHandles = @{}
}

function Start-WorkerRuntimeDiagnostics {
    param(
        [System.Diagnostics.Process]$Worker,
        [string]$EvidenceName,
        [string]$ArtifactDirectory
    )

    $toolPath = [Environment]::GetEnvironmentVariable(
        "TINYEVENTS_DOGFOOD_DOTNET_COUNTERS")
    if ([string]::IsNullOrWhiteSpace($toolPath)) {
        return
    }

    if (!(Test-Path -LiteralPath $toolPath)) {
        throw "TINYEVENTS_DOGFOOD_DOTNET_COUNTERS points to missing tool '$toolPath'."
    }

    $refreshInterval = [Environment]::GetEnvironmentVariable(
        "TINYEVENTS_DOGFOOD_COUNTER_INTERVAL_SECONDS")
    $refreshIntervalSeconds = 10
    if (![string]::IsNullOrWhiteSpace($refreshInterval) -and
        (![int]::TryParse($refreshInterval, [ref]$refreshIntervalSeconds) -or
            $refreshIntervalSeconds -lt 1 -or
            $refreshIntervalSeconds -gt 60)) {
        throw "TINYEVENTS_DOGFOOD_COUNTER_INTERVAL_SECONDS must be between 1 and 60."
    }

    $safeEvidenceName = $EvidenceName -replace "[^A-Za-z0-9_.-]", "_"
    $counterOutput = Join-Path $ArtifactDirectory "$safeEvidenceName.runtime.csv"
    $counterStandardOutput = Join-Path `
        $ArtifactDirectory `
        "$safeEvidenceName.dotnet-counters.stdout.log"
    $counterStandardError = Join-Path `
        $ArtifactDirectory `
        "$safeEvidenceName.dotnet-counters.stderr.log"
    $counterStartParameters = @{
        FilePath = $toolPath
        ArgumentList = @(
            "collect",
            "--process-id",
            [string]$Worker.Id,
            "--refresh-interval",
            [string]$refreshIntervalSeconds,
            "--format",
            "csv",
            "--output",
            $counterOutput,
            "--counters",
            "System.Runtime")
        RedirectStandardOutput = $counterStandardOutput
        RedirectStandardError = $counterStandardError
        PassThru = $true
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $counterStartParameters.WindowStyle = "Hidden"
    }

    $counter = Start-Process @counterStartParameters

    $script:WorkerDiagnosticHandles[[string]$Worker.Id] = $counter
}

function Start-Worker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$BeforeEffectDelayMilliseconds,
        [int]$AfterEffectDelayMilliseconds,
        [string]$ArtifactDirectory,
        [string]$EvidenceName = $WorkerId
    )

    $standardOutput = Join-Path $ArtifactDirectory "$EvidenceName.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$EvidenceName.stderr.log"

    $workerStartParameters = @{
        FilePath = "dotnet"
        ArgumentList = @(
            $Assembly,
            "worker",
            $WorkerId,
            [string]$BeforeEffectDelayMilliseconds,
            [string]$AfterEffectDelayMilliseconds)
        RedirectStandardOutput = $standardOutput
        RedirectStandardError = $standardError
        PassThru = $true
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $workerStartParameters.WindowStyle = "Hidden"
    }

    $worker = Start-Process @workerStartParameters

    try {
        Start-WorkerRuntimeDiagnostics `
            $worker `
            $EvidenceName `
            $ArtifactDirectory
    }
    catch {
        if (!$worker.HasExited) {
            Stop-Process -Id $worker.Id
            $worker.WaitForExit()
        }

        throw
    }

    return $worker
}

function Start-FailingWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [string]$TargetScenarioId,
        [int]$RejectedAttemptCount,
        [string]$ArtifactDirectory,
        [int]$BatchSize = 50
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @(
            $Assembly,
            "worker-with-failures",
            $WorkerId,
            $TargetScenarioId,
            [string]$RejectedAttemptCount,
            [string]$BatchSize) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-PlannedWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [string]$SlowScenarioId,
        [int]$AfterEffectDelayMilliseconds,
        [string[]]$FailureRules,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"
    $arguments = @(
        $Assembly,
        "worker-with-plan",
        $WorkerId,
        $SlowScenarioId,
        [string]$AfterEffectDelayMilliseconds) + $FailureRules

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList $arguments `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-PlannedCleanupWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [string]$SlowScenarioId,
        [int]$AfterEffectDelayMilliseconds,
        [int]$ProcessedRetentionSeconds,
        [int]$CleanupBatchSize,
        [int]$CleanupIntervalMilliseconds,
        [string[]]$FailureRules,
        [string]$ArtifactDirectory,
        [string]$EvidenceName = $WorkerId
    )

    $standardOutput = Join-Path $ArtifactDirectory "$EvidenceName.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$EvidenceName.stderr.log"
    $arguments = @(
        $Assembly,
        "worker-with-plan-and-cleanup",
        $WorkerId,
        $SlowScenarioId,
        [string]$AfterEffectDelayMilliseconds,
        [string]$ProcessedRetentionSeconds,
        [string]$CleanupBatchSize,
        [string]$CleanupIntervalMilliseconds) + $FailureRules

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList $arguments `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-BatchWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$BatchSize,
        [int]$BeforeEffectDelayMilliseconds,
        [int]$AfterEffectDelayMilliseconds,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @(
            $Assembly,
            "worker-with-batch",
            $WorkerId,
            [string]$BatchSize,
            [string]$BeforeEffectDelayMilliseconds,
            [string]$AfterEffectDelayMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-WorkerUnderPressure {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$HeldConnectionCount,
        [int]$PressureDurationMilliseconds,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @(
            $Assembly,
            "worker-under-pressure",
            $WorkerId,
            [string]$HeldConnectionCount,
            [string]$PressureDurationMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-TimedWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$RunDurationMilliseconds,
        [int]$BeforeEffectDelayMilliseconds,
        [int]$AfterEffectDelayMilliseconds,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "dotnet"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $startInfo.Arguments =
        "`"$Assembly`" worker-for `"$WorkerId`" " +
        "$RunDurationMilliseconds " +
        "$BeforeEffectDelayMilliseconds " +
        "$AfterEffectDelayMilliseconds"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Worker '$WorkerId' could not be started."
    }

    return [pscustomobject]@{
        Process = $process
        OutputPath = $standardOutput
        ErrorPath = $standardError
        OutputTask = $process.StandardOutput.ReadToEndAsync()
        ErrorTask = $process.StandardError.ReadToEndAsync()
    }
}

function Start-CleanupWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$ProcessedRetentionSeconds,
        [int]$BatchSize,
        [int]$IntervalMilliseconds,
        [string]$ArtifactDirectory,
        [string]$EvidenceName = $WorkerId
    )

    $standardOutput = Join-Path $ArtifactDirectory "$EvidenceName.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$EvidenceName.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @(
            $Assembly,
            "cleanup-worker",
            $WorkerId,
            [string]$ProcessedRetentionSeconds,
            [string]$BatchSize,
            [string]$IntervalMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Stop-Worker {
    param([System.Diagnostics.Process]$Worker)

    if ($null -ne $Worker -and -not $Worker.HasExited) {
        Stop-Process -Id $Worker.Id
        $Worker.WaitForExit()
    }

    if ($null -ne $Worker) {
        $diagnosticKey = [string]$Worker.Id
        $counter = $script:WorkerDiagnosticHandles[$diagnosticKey]
        if ($null -ne $counter) {
            if (!$counter.WaitForExit(15000)) {
                Stop-Process -Id $counter.Id
                $counter.WaitForExit()
            }

            $counter.Dispose()
            $script:WorkerDiagnosticHandles.Remove($diagnosticKey)
        }
    }
}

function Wait-ForWorkerExit {
    param(
        [pscustomobject]$WorkerHandle,
        [string]$WorkerId
    )

    $process = $WorkerHandle.Process

    if (-not $process.WaitForExit(15000)) {
        throw "Worker '$WorkerId' did not stop within fifteen seconds."
    }

    $process.WaitForExit()
    $process.Refresh()
    $standardOutput = $WorkerHandle.OutputTask.GetAwaiter().GetResult()
    $standardError = $WorkerHandle.ErrorTask.GetAwaiter().GetResult()
    $standardOutput | Set-Content $WorkerHandle.OutputPath
    $standardError | Set-Content $WorkerHandle.ErrorPath

    if ($process.ExitCode -ne 0) {
        throw "Worker '$WorkerId' stopped with exit code $($process.ExitCode)."
    }
}
