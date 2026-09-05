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
        [ValidateRange(1, 1024)][int]$MinimumFreeGiB = 10,
        [string]$ToolPath = "/opt/dotnet-tools/dotnet-gcdump",
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 65,
        [ValidateRange(1048576, 2147483648)][long]$MaximumBytes = 1073741824
    )
    if ($TargetProcess.HasExited) { throw 'Cannot capture from an exited process.' }
    if (!(Test-Path -LiteralPath $ToolPath -PathType Leaf)) { throw 'GC dump tool is missing.' }
    if (Test-Path -LiteralPath $OutputPath) { throw 'GC dump evidence already exists.' }
    $outputDirectory = [IO.Path]::GetFullPath((Split-Path $OutputPath -Parent))
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    if ($IsLinux) {
        $disk = @(& df -Pk -- $outputDirectory)
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the evidence filesystem.' }
        $availableBytes = [long](($disk[-1] -split '\s+')[3]) * 1024
    } else {
        $availableBytes = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($outputDirectory)).AvailableFreeSpace
    }
    if ($availableBytes -lt ($MinimumFreeGiB * 1GB + $MaximumBytes)) { throw 'Insufficient free space for bounded diagnostics.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $ToolPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('collect','--process-id',[string]$TargetProcess.Id,'--output',$OutputPath,'--timeout','60')) {
        $start.ArgumentList.Add($argument)
    }
    $collector = [Diagnostics.Process]::new()
    $collector.StartInfo = $start
    if (!$collector.Start()) { throw 'GC dump process could not start.' }
    $stdout = $collector.StandardOutput.ReadToEndAsync()
    $stderr = $collector.StandardError.ReadToEndAsync()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while (!$collector.WaitForExit(250)) {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'GC dump exceeded its wall-clock budget.' }
            if ((Test-Path -LiteralPath $OutputPath) -and (Get-Item -LiteralPath $OutputPath).Length -gt $MaximumBytes) {
                throw 'GC dump exceeded its monitored file-size budget.'
            }
        }
        if ($collector.ExitCode -ne 0) { throw "GC dump exited with code $($collector.ExitCode)." }
        if (!(Test-Path -LiteralPath $OutputPath) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) { throw 'GC dump produced no evidence.' }
        if ((Get-Item -LiteralPath $OutputPath).Length -gt $MaximumBytes) { throw 'GC dump exceeded its monitored file-size budget.' }
        return Get-Item -LiteralPath $OutputPath
    } finally {
        if (!$collector.HasExited) { $collector.Kill($true) }
        $collector.WaitForExit(5000) | Out-Null
        $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath "$OutputPath.stdout.log"
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$OutputPath.stderr.log"
        $collector.Dispose()
    }
}
