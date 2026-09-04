Set-StrictMode -Version Latest

function Start-DotNetRuntimeCounters {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$TargetProcess,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$RefreshIntervalSeconds = 10,
        [string]$ToolPath = "/opt/dotnet-tools/dotnet-counters"
    )

    if (!(Test-Path -LiteralPath $ToolPath)) {
        return $null
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ToolPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments =
        "collect --process-id $($TargetProcess.Id) " +
        "--refresh-interval $RefreshIntervalSeconds " +
        "--format csv --output `"$OutputPath`" " +
        "--counters System.Runtime"

    $counterProcess = [Diagnostics.Process]::new()
    $counterProcess.StartInfo = $startInfo
    if (!$counterProcess.Start()) {
        throw "dotnet-counters could not attach to PID $($TargetProcess.Id)."
    }

    return [pscustomobject]@{
        Process = $counterProcess
        OutputTask = $counterProcess.StandardOutput.ReadToEndAsync()
        ErrorTask = $counterProcess.StandardError.ReadToEndAsync()
        OutputPath = $OutputPath
    }
}

function Get-DotNetProcessResourceSample {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ProcessName
    )

    if ($Process.HasExited) {
        return [pscustomobject]@{
            TimestampUtc = [DateTimeOffset]::UtcNow.ToString("O")
            ProcessName = $ProcessName
            ProcessId = $Process.Id
            HasExited = $true
        }
    }

    $Process.Refresh()
    return [pscustomobject]@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString("O")
        ProcessName = $ProcessName
        ProcessId = $Process.Id
        HasExited = $false
        TotalProcessorTimeMilliseconds = $Process.TotalProcessorTime.TotalMilliseconds
        WorkingSetBytes = $Process.WorkingSet64
        PrivateMemoryBytes = $Process.PrivateMemorySize64
        VirtualMemoryBytes = $Process.VirtualMemorySize64
        ThreadCount = $Process.Threads.Count
        HandleCount = $Process.HandleCount
    }
}

function Stop-DotNetRuntimeCounters {
    param(
        [AllowNull()][pscustomobject]$CounterHandle,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath
    )

    if ($null -eq $CounterHandle) {
        return
    }

    if (!$CounterHandle.Process.WaitForExit(15000)) {
        $CounterHandle.Process.Kill()
        $CounterHandle.Process.WaitForExit()
    }

    $CounterHandle.OutputTask.GetAwaiter().GetResult() |
        Set-Content -LiteralPath $StandardOutputPath
    $CounterHandle.ErrorTask.GetAwaiter().GetResult() |
        Set-Content -LiteralPath $StandardErrorPath
    $CounterHandle.Process.Dispose()
}

function Invoke-BoundedGcDump {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$TargetProcess,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$MinimumFreeGiB = 10,
        [string]$ToolPath = "/opt/dotnet-tools/dotnet-gcdump"
    )

    if ($TargetProcess.HasExited) {
        throw "Cannot capture a GC dump from exited PID $($TargetProcess.Id)."
    }

    if (!(Test-Path -LiteralPath $ToolPath)) {
        throw "dotnet-gcdump was not found at '$ToolPath'."
    }

    $outputDirectory = Split-Path $OutputPath -Parent
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($outputDirectory))
    $minimumFreeBytes = $MinimumFreeGiB * 1GB
    if ($drive.AvailableFreeSpace -lt $minimumFreeBytes) {
        throw "GC dump refused: less than $MinimumFreeGiB GiB remains on the evidence volume."
    }

    & $ToolPath collect `
        --process-id $TargetProcess.Id `
        --output $OutputPath `
        --timeout 60
    if ($LASTEXITCODE -ne 0) {
        throw "GC dump collection failed for PID $($TargetProcess.Id)."
    }

    return Get-Item -LiteralPath $OutputPath
}
