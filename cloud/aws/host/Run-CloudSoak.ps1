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
    [switch]$ResetDatabase
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ProcessDiagnostics.ps1')
. (Join-Path $DogfoodRoot 'operations/support/Observations.ps1')

if (!$ResetDatabase) { throw 'This disposable-database test requires -ResetDatabase.' }
if ($Rate % 20 -ne 0) { throw 'Rate must be a multiple of 20 for the exact 80/10/5/5 mix.' }
if (!(Test-Path -LiteralPath $CounterToolPath -PathType Leaf)) { throw 'Runtime counter tool is required.' }
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
    BatchSize = 10
    ClaimTimeoutSeconds = 300
    PollingIntervalMilliseconds = 50
    RetryDelaySeconds = 3
    ProcessedRetentionSeconds = 3600
    CleanupBatchSize = 1000
    CleanupIntervalSeconds = 1
    AcceptancePassed = $false
    MemoryVerdict = 'Inconclusive'
    Processes = @()
}

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
    $handle.Counters = Start-DotNetRuntimeCounters $process `
        (Join-Path $RuntimeDirectory "$Name.runtime.csv") `
        -RefreshIntervalSeconds 1 -ToolPath $CounterToolPath
    if ($null -eq $handle.Counters) { throw "Runtime collector for $Name could not be started." }
    $processEvidence.CounterProcessId = $handle.Counters.Process.Id
    return $handle
}

function Save-ProcessSamples {
    foreach ($handle in $handles) {
        if (!$handle.Process.HasExited) {
            Get-DotNetProcessResourceSample $handle.Process $handle.Name |
                ConvertTo-Json -Compress |
                Add-Content -LiteralPath (Join-Path $RuntimeDirectory 'process-samples.jsonl')
        }
    }
}

function Assert-WorkersAlive {
    foreach ($handle in $handles | Where-Object Name -Like 'worker-*') {
        if ($handle.Process.HasExited) { throw "Worker $($handle.Name) exited unexpectedly." }
        if ($handle.Counters.Process.HasExited) { throw "Counters for $($handle.Name) exited during the soak." }
    }
}

try {
    & dotnet $assembly reset > (Join-Path $LogDirectory 'reset.log')
    if ($LASTEXITCODE -ne 0) { throw 'Database reset failed.' }
    $before = Get-Observation $assembly
    if ($before.BusinessOperations -ne 0 -or $before.OutboxMessages -ne 0) { throw 'Database is not empty.' }

    for ($index = 1; $index -le $WorkerCount; $index++) {
        Start-SoakProcess "worker-$index" @('worker-soak', "soak-$([Guid]::NewGuid().ToString('N'))") | Out-Null
    }
    $publisherPath = Join-Path $ArtifactDirectory 'publisher-windows.jsonl'
    $publisher = Start-SoakProcess 'publisher' @(
        'publish-soak', [string]$DurationSeconds, [string]$Rate, [string]$WindowSeconds, $publisherPath)
    $publicationStarted = [DateTimeOffset]::UtcNow
    $deadline = $publicationStarted.AddSeconds($DurationSeconds + $SettlementSeconds)

    while (!$publisher.Process.HasExited) {
        Assert-WorkersAlive
        if ($publisher.Counters.Process.HasExited) { throw 'Publisher runtime counters exited prematurely.' }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Publisher exceeded its duration and settlement budget.' }
        Save-ProcessSamples
        Start-Sleep -Seconds 1
    }
    $publisher.Process.WaitForExit()
    if ($publisher.Process.ExitCode -ne 0) { throw "Publisher failed with code $($publisher.Process.ExitCode)." }
    $result.PublicationWallSeconds = ([DateTimeOffset]::UtcNow - $publicationStarted).TotalSeconds

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($SettlementSeconds)
    while (Test-OutstandingMessages $assembly) {
        Assert-WorkersAlive
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Backlog did not settle within budget.' }
        Save-ProcessSamples
        Start-Sleep -Seconds 1
    }
    Assert-WorkersAlive
    $after = Get-Observation $assembly
    $result.After = $after
    [long]$acknowledged = 0
    [long]$attempted = 0
    [long]$scheduledSeconds = 0
    $windows = 0
    # Stream the journal: do not load 24 hours of evidence into a list.
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
    [long]$expected = [long]$Rate * $DurationSeconds
    [long]$expectedFailed = $expected / 20
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
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-success') -eq ($expected * 80 / 100) -and
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-transient') -eq ($expected * 10 / 100) -and
        (Get-ScenarioCount $after.ScenarioEffects 'TE-SOAK-slow') -eq ($expected * 5 / 100) -and
        $after.ConsumerAttempts -eq ($expected * 45 / 100))
    $result.AchievedPublishRate = $acknowledged / $result.PublicationWallSeconds
    $result.RateTargetPassed = $result.AchievedPublishRate -ge (0.95 * $Rate)
    if (!$result.BehaviorPassed) { throw 'Durable soak reconciliation failed.' }
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
$result.RuntimeCountersPresent = $missingCounters.Count -eq 0
$result.AcceptancePassed = $result.BehaviorPassed -and $result.RuntimeCountersPresent -and $result.RateTargetPassed
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'result.json')
if (!$result.AcceptancePassed) { throw 'Soak failed rate or runtime-evidence acceptance; see result.json.' }
Write-Output (Join-Path $ArtifactDirectory 'result.json')
