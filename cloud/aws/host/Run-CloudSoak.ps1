#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DogfoodRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [string]$RuntimeDirectory,
    [string]$LogDirectory,
    [Parameter(Mandatory)][string]$ConnectionString,
    [ValidateRange(1, 259200)][int]$DurationSeconds = 7200,
    [ValidateRange(20, 2000)][int]$Rate = 20,
    [ValidateRange(1, 24)][int]$WorkerCount = 4,
    [ValidateRange(1, 10)][int]$WindowSeconds = 10,
    [ValidateRange(15, 600)][int]$SettlementSeconds = 300,
    [ValidateRange(1, 120)][int]$StartupSeconds = 30,
    [Parameter(Mandatory)][string]$CounterToolPath,
    [ValidateRange(1, 100)][int]$BatchSize = 10,
    [bool]$CleanupEnabled = $true,
    [ValidateRange(1, 86400)][int]$RetentionSeconds = 3600,
    [ValidateRange(0, 1000)][int]$SlowMilliseconds = 100,
    [bool]$CountersEnabled = $true,
    [ValidateRange(1, 60)][int]$CounterIntervalSeconds = 1,
    [bool]$RequireRateTarget = $true,
    [ValidateRange(0, 100000)][int]$Backlog = 0,
    [object[]]$Phases = @(),
    [bool]$AutomaticDiagnostics = $false,
    [string]$GcDumpToolPath = '/opt/dotnet-tools/dotnet-gcdump',
    [switch]$ResetDatabase
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ProcessDiagnostics.ps1')
. (Join-Path $DogfoodRoot 'operations/support/Observations.ps1')
. (Join-Path $PSScriptRoot '../ScenarioContract.ps1')
. (Join-Path $PSScriptRoot 'MemoryDiagnostics.ps1')

if (!$ResetDatabase) { throw 'This disposable-database test requires -ResetDatabase.' }
if ($Rate % 20 -ne 0) { throw 'Rate must be a multiple of 20 for the exact 80/10/5/5 mix.' }
if ($CountersEnabled -and !(Test-Path -LiteralPath $CounterToolPath -PathType Leaf)) { throw 'Runtime counter tool is required.' }
if ($Backlog -gt 0 -and ($Phases.Count -gt 0 -or $CleanupEnabled)) { throw 'Backlog measurements require cleanup disabled and no phase plan.' }
if ($Phases.Count -gt 0) {
    Assert-BenchPhases $Phases
    $DurationSeconds = ($Phases | Measure-Object durationSeconds -Sum).Sum
}
$assembly = Join-Path $DogfoodRoot 'operations/TinyEvents.Dogfood.Operations/bin/Release/net8.0/TinyEvents.Dogfood.Operations.dll'
if (!(Test-Path -LiteralPath $assembly)) { throw "Build the dogfood assembly first: $assembly" }
if (Test-Path -LiteralPath $ArtifactDirectory) { throw 'Use a new evidence directory for each soak.' }
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$ArtifactDirectory = (Resolve-Path $ArtifactDirectory).Path
if (!$RuntimeDirectory) { $RuntimeDirectory = $ArtifactDirectory }
if (!$LogDirectory) { $LogDirectory = $ArtifactDirectory }
New-Item -ItemType Directory -Path $RuntimeDirectory, $LogDirectory -Force | Out-Null
$previousStorage = $env:TINYEVENTS_DOGFOOD_STORAGE
$previousConnection = $env:TINYEVENTS_DOGFOOD_POSTGRESQL
$env:TINYEVENTS_DOGFOOD_STORAGE = 'postgresql'
$env:TINYEVENTS_DOGFOOD_POSTGRESQL = $ConnectionString
$handles = [Collections.Generic.List[object]]::new()
$started = [DateTimeOffset]::UtcNow
$result = [ordered]@{
    Scenario = 'TE-CLOUD-SOAK'
    StartedAtUtc = $started.ToString('O')
    DurationSeconds = $DurationSeconds
    Rate = $Rate
    WorkerCount = $WorkerCount
    WindowSeconds = $WindowSeconds
    StartupSeconds = $StartupSeconds
    BatchSize = $BatchSize
    CleanupEnabled = $CleanupEnabled
    CountersEnabled = $CountersEnabled
    CounterIntervalSeconds = $CounterIntervalSeconds
    Backlog = $Backlog
    Phases = $Phases
    AutomaticDiagnostics = $AutomaticDiagnostics
    DiagnosticCaptureAttempted = $false
    ClaimTimeoutSeconds = 300
    PollingIntervalMilliseconds = 50
    RetryDelaySeconds = 3
    ProcessedRetentionSeconds = $RetentionSeconds
    CleanupBatchSize = 1000
    CleanupIntervalSeconds = 1
    AcceptancePassed = $false
    MemoryVerdict = 'Inconclusive'
    Processes = @()
}
$gatePath = Join-Path $RuntimeDirectory 'workers.release'
$workerConfigPath = Join-Path $ArtifactDirectory 'worker-config.json'
@{ BatchSize = $BatchSize; CleanupEnabled = $CleanupEnabled; RetentionSeconds = $RetentionSeconds
    SlowMilliseconds = $SlowMilliseconds; StartGate = $gatePath } |
    ConvertTo-Json | Set-Content -LiteralPath $workerConfigPath
$diagnosticState = New-MemoryDiagnosticState
$publisher = $null

function Start-SoakProcess([string]$Name, [string[]]$CommandArguments) {
    $readyPath = Join-Path $RuntimeDirectory "$Name.ready.json"
    $parameters = @{
        FilePath = 'dotnet'
        ArgumentList = ((@($assembly) + $CommandArguments + @($readyPath)) | ForEach-Object { '"' + $_ + '"' })
        RedirectStandardOutput = Join-Path $LogDirectory "$Name.stdout.log"
        RedirectStandardError = Join-Path $LogDirectory "$Name.stderr.log"
        PassThru = $true
    }
    if ($IsWindows) { $parameters.WindowStyle = 'Hidden' }
    $process = Start-Process @parameters
    $handle = [pscustomobject]@{ Name = $Name; Process = $process; Counters = $null }
    # Own the process before attempting attachment, including attachment failures.
    $handles.Add($handle)
    $processEvidence = [ordered]@{ Name = $Name; ProcessId = $process.Id; CounterProcessId = $null }
    $result.Processes += $processEvidence
    $startupDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupSeconds)
    while (!(Test-Path -LiteralPath $readyPath)) {
        if ($process.HasExited) { throw "$Name exited before readiness; see its stderr log." }
        if ([DateTimeOffset]::UtcNow -ge $startupDeadline) { throw "$Name did not become ready within $StartupSeconds seconds." }
        Start-Sleep -Milliseconds 100
    }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    if ($ready.ProcessId -ne $process.Id) { throw "$Name readiness PID does not match its process." }
    # Attaching during native runtime initialization can stall .NET 8 startup.
    # An explicit managed readiness signal avoids an arbitrary fixed sleep.
    if ($CountersEnabled) {
    $handle.Counters = Start-DotNetRuntimeCounters $process `
        (Join-Path $RuntimeDirectory "$Name.runtime.csv") `
        -RefreshIntervalSeconds $CounterIntervalSeconds -ToolPath $CounterToolPath
    if ($null -eq $handle.Counters) { throw "Runtime collector for $Name could not be started." }
    $processEvidence.CounterProcessId = $handle.Counters.Process.Id
    if ($Backlog -gt 0) {
        $counterPath = Join-Path $RuntimeDirectory "$Name.runtime.csv"
        $counterDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupSeconds)
        while (!(Test-Path -LiteralPath $counterPath) -or !(Select-String -LiteralPath $counterPath -SimpleMatch 'System.Runtime' -Quiet)) {
            if ($handle.Counters.Process.HasExited -or [DateTimeOffset]::UtcNow -ge $counterDeadline) {
                throw "Runtime collector for $Name did not emit a pre-drain sample."
            }
            Start-Sleep -Milliseconds 100
        }
    }
    }
    return $handle
}

function Save-ProcessSamples {
    foreach ($handle in $handles) {
        if (!$handle.Process.HasExited) {
            $sample = Get-DotNetProcessResourceSample $handle.Process $handle.Name
            $sample |
                ConvertTo-Json -Compress |
                Add-Content -LiteralPath (Join-Path $RuntimeDirectory 'process-samples.jsonl')
            if ($AutomaticDiagnostics -and (Test-MemoryDiagnosticTrigger $diagnosticState $sample)) {
                $result.DiagnosticCaptureAttempted = $true
                $capture = [ordered]@{ ProcessId = $handle.Process.Id; AtUtc = $sample.TimestampUtc
                    Reason = 'Sustained resident-memory growth after warm-up; not a leak verdict.'; Succeeded = $false }
                try {
                    Invoke-BoundedGcDump $handle.Process (Join-Path $RuntimeDirectory 'suspected-growth.gcdump') -ToolPath $GcDumpToolPath | Out-Null
                    $capture.Succeeded = $true
                } catch { $capture.Error = $_.Exception.Message }
                $capture | ConvertTo-Json | Set-Content (Join-Path $RuntimeDirectory 'diagnostic-capture.json')
            }
        }
    }
}

function Assert-WorkersAlive {
    foreach ($handle in $handles | Where-Object Name -Like 'worker-*') {
        if ($handle.Process.HasExited) { throw "Worker $($handle.Name) exited unexpectedly." }
        if ($CountersEnabled -and $handle.Counters.Process.HasExited) { throw "Counters for $($handle.Name) exited during the soak." }
    }
}

try {
    & dotnet $assembly reset > (Join-Path $LogDirectory 'reset.log')
    if ($LASTEXITCODE -ne 0) { throw 'Database reset failed.' }
    $before = Get-Observation $assembly
    if ($before.BusinessOperations -ne 0 -or $before.OutboxMessages -ne 0) { throw 'Database is not empty.' }

    if ($Backlog -gt 0) {
        & dotnet $assembly publish TE-SOAK-success $Backlog > (Join-Path $LogDirectory 'build-backlog.log')
        if ($LASTEXITCODE -ne 0) { throw 'Backlog publication failed.' }
        $beforeWorkers = Get-Observation $assembly
        if ($beforeWorkers.PendingMessages -ne $Backlog -or $beforeWorkers.Effects -ne 0) { throw 'Backlog not ready.' }
    }
    for ($index = 1; $index -le $WorkerCount; $index++) {
        Start-SoakProcess "worker-$index" @('worker-bench', "soak-$([Guid]::NewGuid().ToString('N'))", $workerConfigPath) | Out-Null
    }
    $measurementStarted = [DateTimeOffset]::UtcNow
    New-Item -ItemType File -Path $gatePath | Out-Null
    $result.MeasurementStartedAtUtc = $measurementStarted.ToString('O')
    $publisherPath = Join-Path $ArtifactDirectory 'publisher-windows.jsonl'
    if ($Backlog -eq 0) {
    if ($Phases.Count -gt 0) {
        $phasePath = Join-Path $ArtifactDirectory 'phases.json'
        ConvertTo-Json -InputObject @($Phases) -Depth 8 | Set-Content -LiteralPath $phasePath
        $publisher = Start-SoakProcess 'publisher' @('publish-phases', $phasePath, $publisherPath)
    } else {
    $publisher = Start-SoakProcess 'publisher' @(
        'publish-soak', [string]$DurationSeconds, [string]$Rate, [string]$WindowSeconds, $publisherPath)
    }
    $publicationStarted = [DateTimeOffset]::UtcNow
    $deadline = $publicationStarted.AddSeconds($DurationSeconds + $SettlementSeconds)

    while (!$publisher.Process.HasExited) {
        Assert-WorkersAlive
        if ($CountersEnabled -and $publisher.Counters.Process.HasExited) { throw 'Publisher runtime counters exited prematurely.' }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Publisher exceeded its duration and settlement budget.' }
        Save-ProcessSamples
        Start-Sleep -Seconds 1
    }
    $publisher.Process.WaitForExit()
    if ($publisher.Process.ExitCode -ne 0) { throw "Publisher failed with code $($publisher.Process.ExitCode)." }
    $result.PublicationWallSeconds = ([DateTimeOffset]::UtcNow - $publicationStarted).TotalSeconds
    } else { $result.PublicationWallSeconds = 0 }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($SettlementSeconds)
    while (Test-OutstandingMessages $assembly) {
        Assert-WorkersAlive
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Backlog did not settle within budget.' }
        Save-ProcessSamples
        Start-Sleep -Seconds 1
    }
    Assert-WorkersAlive
    $result.MeasurementCompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $result.SettlementWallSeconds = ([DateTimeOffset]::UtcNow - $measurementStarted).TotalSeconds
    Save-ProcessSamples
    $result.WorkerCpuMilliseconds = 0.0
    foreach ($handle in $handles | Where-Object Name -Like 'worker-*') {
        $handle.Process.Refresh()
        $result.WorkerCpuMilliseconds += $handle.Process.TotalProcessorTime.TotalMilliseconds
    }
    $after = Get-Observation $assembly
    $result.After = $after
    [long]$acknowledged = 0
    [long]$attempted = 0
    [long]$scheduledSeconds = 0
    $windows = 0
    # Stream the journal: do not load 24 hours of evidence into a list.
    if ($Backlog -eq 0) {
    foreach ($line in [IO.File]::ReadLines($publisherPath)) {
        $window = $line | ConvertFrom-Json
        $windows++
        if ($window.Sequence -ne $windows -or $window.ProcessId -ne $publisher.Process.Id) {
            throw 'Publisher journal sequence or process identity is inconsistent.'
        }
        $scheduledSeconds += $window.ScheduledSeconds
        foreach ($entry in $window.Results) {
            $acknowledged += $entry.Load.CommittedRequests
            $attempted += $entry.Load.AttemptedRequests
        }
    }
    }
    [long]$expected = [long]$Rate * $DurationSeconds
    if ($Phases.Count -gt 0) { $expected = ($Phases | ForEach-Object { [long]$_.rate * $_.durationSeconds } | Measure-Object -Sum).Sum }
    if ($Backlog -gt 0) { $expected = $Backlog; $acknowledged = $Backlog; $attempted = $Backlog; $scheduledSeconds = $DurationSeconds }
    [long]$expectedFailed = $expected / 20
    if ($Backlog -gt 0) { $expectedFailed = 0 }
    [long]$expectedEffects = $expected - $expectedFailed
    $result.ExpectedMessages = $expected
    $result.PublisherWindows = $windows
    $result.AcknowledgedCommits = $acknowledged
    $result.ProcessedRowsCleaned = $expectedEffects - $after.ProcessedMessages
    $result.BehaviorPassed = (
        $scheduledSeconds -eq $DurationSeconds -and $attempted -eq $expected -and
        $acknowledged -eq $expected -and $after.BusinessOperations -eq $expected -and
        $after.PendingMessages -eq 0 -and $after.ProcessingMessages -eq 0 -and
        $after.FailedMessages -eq $expectedFailed -and $after.Effects -eq $expectedEffects -and
        $after.DuplicateEffects -eq 0 -and $after.ProcessedMessages -le $expectedEffects -and
        $after.OutboxMessages -eq ($after.ProcessedMessages + $after.FailedMessages) -and
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-permanent') -eq 0 -and
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-success') -eq $(if ($Backlog) { $expected } else { $expected * 80 / 100 }) -and
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-transient') -eq $(if ($Backlog) { 0 } else { $expected * 10 / 100 }) -and
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-slow') -eq $(if ($Backlog) { 0 } else { $expected * 5 / 100 }) -and
        $after.ConsumerAttempts -eq $(if ($Backlog) { 0 } else { $expected * 45 / 100 }))
    $result.SettledMessagesPerSecond = $expected / [Math]::Max(0.001, $result.SettlementWallSeconds)
    $result.AchievedPublishRate = if ($Backlog) { $null } else { $acknowledged / $result.PublicationWallSeconds }
    $targetRate = $expected / $DurationSeconds
    $result.RateTargetPassed = $Backlog -gt 0 -or $result.AchievedPublishRate -ge (0.95 * $targetRate)
    if (!$result.BehaviorPassed) { throw 'Durable soak reconciliation failed.' }
    & dotnet $assembly inspect-latency (Join-Path $ArtifactDirectory 'latency.json') > (Join-Path $LogDirectory 'latency.log')
    if ($LASTEXITCODE -ne 0) { throw 'Latency aggregation failed.' }
    $latency = Get-Content (Join-Path $ArtifactDirectory 'latency.json') -Raw | ConvertFrom-Json
    $processedSamples = ($latency.Metrics | Where-Object Metric -EQ 'outbox-created-to-processed' | Measure-Object Count -Sum).Sum
    $result.ProcessedLatencyCoverage = $processedSamples / [Math]::Max(1, $expectedEffects)
    if (!$CleanupEnabled -and $processedSamples -ne $expectedEffects) { throw 'Uncensored processing-latency samples are incomplete.' }
}
catch {
    $result.Error = $_.Exception.Message
    throw
}
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($handle in $handles) {
        try {
            if (!$handle.Process.HasExited) { $handle.Process.Kill($true) }
            if (!$handle.Process.WaitForExit(10000)) { throw 'Process did not exit after termination.' }
        }
        catch { $cleanupErrors.Add("$($handle.Name): $($_.Exception.Message)") }
        try {
            Stop-DotNetRuntimeCounters $handle.Counters `
                (Join-Path $LogDirectory "$($handle.Name).counters.stdout.log") `
                (Join-Path $LogDirectory "$($handle.Name).counters.stderr.log")
        }
        catch { $cleanupErrors.Add("$($handle.Name) counters: $($_.Exception.Message)") }
        finally { $handle.Process.Dispose() }
    }
    $env:TINYEVENTS_DOGFOOD_STORAGE = $previousStorage
    $env:TINYEVENTS_DOGFOOD_POSTGRESQL = $previousConnection
    $result.CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $result.CleanupErrors = @($cleanupErrors)
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'result.json')
}

if ($result.CleanupErrors.Count -gt 0) { throw 'Soak cleanup failed; see result.json.' }
$missingCounters = @($handles | Where-Object {
    $path = Join-Path $RuntimeDirectory "$($_.Name).runtime.csv"
    !(Test-Path $path) -or !(Select-String -LiteralPath $path -SimpleMatch 'System.Runtime' -Quiet)
})
$result.RuntimeCountersPresent = $CountersEnabled -and $missingCounters.Count -eq 0
$result.AcceptancePassed = $result.BehaviorPassed -and (!$CountersEnabled -or $result.RuntimeCountersPresent) -and (!$RequireRateTarget -or $result.RateTargetPassed)
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'result.json')
if (!$result.AcceptancePassed) { throw 'Soak failed rate or runtime-evidence acceptance; see result.json.' }
Write-Output (Join-Path $ArtifactDirectory 'result.json')
