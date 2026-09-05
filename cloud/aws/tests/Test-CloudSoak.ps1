#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$DogfoodRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$ConnectionString,
    [Parameter(Mandatory)][string]$CounterToolPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Requires a disposable database; the runner explicitly resets it.
$runner = Join-Path $DogfoodRoot 'cloud/aws/host/Run-CloudSoak.ps1'
$resultPath = & $runner -DogfoodRoot $DogfoodRoot -ArtifactDirectory $ArtifactDirectory `
    -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath `
    -DurationSeconds 21 -WindowSeconds 10 -Rate 20 -WorkerCount 2 -SettlementSeconds 60 -ResetDatabase
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
$windows = @(Get-Content (Join-Path $ArtifactDirectory 'publisher-windows.jsonl') | ConvertFrom-Json)
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
foreach ($entry in $result.Processes) {
    if (Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue) {
        throw "Owned process $($entry.ProcessId) survived cleanup."
    }
}

# Reusing an evidence directory must fail before a database reset.
$rejected = $false
try {
    & $runner -DogfoodRoot $DogfoodRoot -ArtifactDirectory $ArtifactDirectory `
        -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath `
        -DurationSeconds 1 -ResetDatabase
}
catch { $rejected = $_.Exception.Message -like '*new evidence directory*' }
if (!$rejected) { throw 'Existing evidence was not protected.' }

# A failed publication must flush its failure window and exit nonzero.
$env:TINYEVENTS_DOGFOOD_STORAGE = 'postgresql'
$env:TINYEVENTS_DOGFOOD_POSTGRESQL = $ConnectionString.Replace('Database=TinyEventsDogfoodSoakValidation', 'Database=TinyEventsDogfoodMissingSoakValidation')
$assembly = Join-Path $DogfoodRoot 'operations/TinyEvents.Dogfood.Operations/bin/Release/net8.0/TinyEvents.Dogfood.Operations.dll'
$failureJournal = Join-Path $ArtifactDirectory 'publisher-failed.jsonl'
& dotnet $assembly publish-soak 21 20 1 $failureJournal
if ($LASTEXITCODE -ne 2) { throw 'Failed publishing did not return exit code 2.' }
$failureWindows = @(Get-Content $failureJournal | ConvertFrom-Json)
if ($failureWindows.Count -ne 1 -or ($failureWindows[0].Results.Load | Measure-Object FailedRequests -Sum).Sum -ne 20) {
    throw 'Failed publication was not recorded as one bounded window.'
}
Write-Host 'PASS: persistent PIDs, bounded windows, exact mixed outcomes, counter CSVs, child cleanup, evidence protection, failure journal.'
