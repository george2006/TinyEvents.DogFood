#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DogfoodRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$ConnectionString,
    [Parameter(Mandatory)][string]$CounterToolPath,
    [ValidateRange(1, 8)][int]$WorkerCount = 2
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Requires a disposable database; the runner explicitly resets it.
$runner = Join-Path $DogfoodRoot 'cloud/aws/host/Run-CloudSoak.ps1'
. (Join-Path $DogfoodRoot 'cloud/aws/host/EvidenceLayout.ps1')
$layout = New-ExperimentEvidenceLayout $ArtifactDirectory
$workloadDirectory = Join-Path $layout.workload 'soak'
$runtimeDirectory = Join-Path $layout.runtime 'soak'
$logDirectory = Join-Path $layout.logs 'soak'
$resultPath = & $runner -DogfoodRoot $DogfoodRoot -ArtifactDirectory $workloadDirectory `
    -RuntimeDirectory $runtimeDirectory -LogDirectory $logDirectory `
    -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath `
    -DurationSeconds 21 -WindowSeconds 10 -Rate 20 -WorkerCount $WorkerCount -SettlementSeconds 60 -ResetDatabase
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
$windows = @(Get-Content (Join-Path $workloadDirectory 'publisher-windows.jsonl') | ConvertFrom-Json)
if (!$result.AcceptancePassed -or $result.After.BusinessOperations -ne 420 -or
    $result.After.Effects -ne 399 -or $result.After.FailedMessages -ne 21 -or
    $result.PublisherWindows -ne 3 -or $windows[-1].ScheduledSeconds -ne 1) {
    throw 'Mixed-work counts or final partial-window accounting are incorrect.'
}
if (@($windows.ProcessId | Sort-Object -Unique).Count -ne 1) {
    throw 'The publisher did not preserve its PID across windows.'
}
foreach ($window in $windows) {
    $windowRequests = ($window.Results.Load | Measure-Object AttemptedRequests -Sum).Sum
    if ($windowRequests -ne 20 * $window.ScheduledSeconds -or $windowRequests -gt 200) {
        throw 'A publisher window exceeded its task/result bound.'
    }
}
function Assert-OwnedProcessesStopped($Result) {
    if ($Result.CleanupErrors.Count -ne 0) { throw 'Cleanup reported errors.' }
    foreach ($entry in $Result.Processes) {
        foreach ($processId in @($entry.ProcessId, $entry.CounterProcessId)) {
            if ($null -ne $processId -and (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
                throw "Owned process $processId survived cleanup."
            }
        }
    }
}
Assert-OwnedProcessesStopped $result
if ($result.MemoryVerdict -ne 'Inconclusive') { throw 'Short smoke test must not claim a memory verdict.' }
if ($result.Processes.Count -ne ($WorkerCount + 1)) { throw 'Not all processes were recorded.' }
foreach ($entry in $result.Processes) {
    $ready = Get-Content (Join-Path $runtimeDirectory "$($entry.Name).ready.json") -Raw | ConvertFrom-Json
    if ($ready.ProcessId -ne $entry.ProcessId -or $null -eq $entry.CounterProcessId) {
        throw 'Readiness or collector process identity is missing.'
    }
}
Write-Host "PASS: $WorkerCount workers, 420 mixed messages, 3 bounded windows, persistent PIDs, categorized metrics, all children stopped."

# Reusing an evidence directory must fail before a database reset.
$rejected = $false
try {
    & $runner -DogfoodRoot $DogfoodRoot -ArtifactDirectory $workloadDirectory `
        -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath `
        -DurationSeconds 1 -ResetDatabase
}
catch { $rejected = $_.Exception.Message -like '*new evidence directory*' }
if (!$rejected) { throw 'Existing evidence was not protected.' }

# A failed publication must flush its failure window and exit nonzero.
$assembly = Join-Path $DogfoodRoot 'operations/TinyEvents.Dogfood.Operations/bin/Release/net8.0/TinyEvents.Dogfood.Operations.dll'
$failureJournal = Join-Path $layout.workload 'publisher-failed.jsonl'
$previousStorage = $env:TINYEVENTS_DOGFOOD_STORAGE
$previousConnection = $env:TINYEVENTS_DOGFOOD_POSTGRESQL
try {
    $env:TINYEVENTS_DOGFOOD_STORAGE = 'postgresql'
    # Parse instead of replacing a specific database spelling: never publish
    # the negative case accidentally into the valid test database.
    $failureConnection = [System.Data.Common.DbConnectionStringBuilder]::new()
    # DbConnectionStringBuilder is IDictionary: PowerShell's property adapter
    # can turn '.ConnectionString =' into a dictionary entry. Use accessors.
    $failureConnection.set_ConnectionString($ConnectionString)
    $failureConnection['Database'] = 'TinyEventsDogfoodMissing_' + [Guid]::NewGuid().ToString('N')
    $env:TINYEVENTS_DOGFOOD_POSTGRESQL = $failureConnection.get_ConnectionString()
    & dotnet $assembly publish-soak 21 20 1 $failureJournal `
        > (Join-Path $layout.logs 'publisher-failed.stdout.log') `
        2> (Join-Path $layout.logs 'publisher-failed.stderr.log')
    if ($LASTEXITCODE -ne 2) { throw 'Failed publishing did not return exit code 2.' }
}
finally {
    $env:TINYEVENTS_DOGFOOD_STORAGE = $previousStorage
    $env:TINYEVENTS_DOGFOOD_POSTGRESQL = $previousConnection
}
$failureWindows = @(Get-Content $failureJournal | ConvertFrom-Json)
if ($failureWindows.Count -ne 1 -or ($failureWindows[0].Results.Load | Measure-Object FailedRequests -Sum).Sum -ne 20) {
    throw 'Failed publication was not recorded as one bounded window.'
}
Write-Host 'PASS: evidence overwrite protection and bounded failed-publication journal.'

if ($IsLinux) {
    # Simulate a collector that starts and immediately dies. The failed run must
    # still own/stop every started worker, publisher, and collector and save result.json.
    $failureDirectory = Join-Path $layout.workload 'collector-failure'
    $collectorRejected = $false
    try {
        & $runner -DogfoodRoot $DogfoodRoot -ArtifactDirectory $failureDirectory `
            -RuntimeDirectory (Join-Path $layout.runtime 'collector-failure') `
            -LogDirectory (Join-Path $layout.logs 'collector-failure') `
            -ConnectionString $ConnectionString -CounterToolPath '/bin/false' `
            -DurationSeconds 21 -WorkerCount 2 -SettlementSeconds 15 -ResetDatabase | Out-Null
    }
    catch { $collectorRejected = $_.Exception.Message -like '*Counters*exited*' }
    if (!$collectorRejected) { throw 'Premature collector exit was not rejected.' }
    $failedResult = Get-Content (Join-Path $failureDirectory 'result.json') -Raw | ConvertFrom-Json
    if ($failedResult.AcceptancePassed -or !$failedResult.Error) { throw 'Failed run lost its failure verdict.' }
    Assert-OwnedProcessesStopped $failedResult
    Write-Host 'PASS: premature collector exit fails the run, saves evidence, and stops every owned process.'
}
