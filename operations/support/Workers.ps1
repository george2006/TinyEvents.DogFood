function Start-Worker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
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
            "worker",
            $WorkerId,
            [string]$BeforeEffectDelayMilliseconds,
            [string]$AfterEffectDelayMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-FailingWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [string]$TargetScenarioId,
        [int]$RejectedAttemptCount,
        [string]$ArtifactDirectory
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
            [string]$RejectedAttemptCount) `
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

function Stop-Worker {
    param([System.Diagnostics.Process]$Worker)

    if ($null -ne $Worker -and -not $Worker.HasExited) {
        Stop-Process -Id $Worker.Id
        $Worker.WaitForExit()
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
