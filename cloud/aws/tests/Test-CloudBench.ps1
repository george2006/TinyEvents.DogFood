#requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$DogfoodRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$ConnectionString,
    [Parameter(Mandatory)][string]$CounterToolPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Test-Path $ArtifactDirectory) { throw 'Use a new integration evidence directory.' }
New-Item -ItemType Directory -Path $ArtifactDirectory | Out-Null
$variants = @()
foreach ($entry in @(@('minimal', 1), @('full', 10), @('full', 1), @('minimal', 10))) {
    $variants += [pscustomobject]@{
        name = "backlog-$($entry[0])-batch-$($entry[1])"; workerCount = 2; batchSize = $entry[1]
        backlog = 400; phases = @(); cleanupEnabled = $false; retentionSeconds = 3600
        slowMilliseconds = 100; monitoring = $entry[0]; automaticDiagnostics = $false
        requireRateTarget = $true; minimumBacklogGrowth = 0
    }
}
$variants += [pscustomobject]@{
    name = 'phase-recovery'; workerCount = 2; batchSize = 10; backlog = 0; cleanupEnabled = $true
    retentionSeconds = 1; slowMilliseconds = 100; monitoring = 'full'; automaticDiagnostics = $false
    requireRateTarget = $false; minimumBacklogGrowth = 20
    phases = @(
        @{ name = 'baseline'; durationSeconds = 3; rate = 20; contentBytes = 0 },
        @{ name = 'overload'; durationSeconds = 3; rate = 200; contentBytes = 1024 },
        @{ name = 'recovery'; durationSeconds = 10; rate = 0; contentBytes = 0 },
        @{ name = 'steady-again'; durationSeconds = 3; rate = 20; contentBytes = 16384 })
}
$plan = @{ schemaVersion = 1; name = 'local-bench'; description = 'Short integration only.'; runner = 'bench'
    storageProvider = 'PostgreSql'; estimatedMaximumMinutes = 200; variants = $variants }
$scenarioPath = Join-Path $ArtifactDirectory 'local-bench.json'
$plan | ConvertTo-Json -Depth 12 | Set-Content $scenarioPath
$statusPath = & (Join-Path $DogfoodRoot 'cloud/aws/host/Run-CloudBench.ps1') -ScenarioPath $scenarioPath `
    -DogfoodRoot $DogfoodRoot -EvidenceDirectory (Join-Path $ArtifactDirectory 'run') `
    -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath
$status = Get-Content $statusPath -Raw | ConvertFrom-Json
if ($status.State -ne 'Succeeded' -or $status.Variants.Count -ne 5) { throw 'Bench did not complete every variant.' }
foreach ($variant in $status.Variants) {
    $workload = Get-Content (Join-Path $ArtifactDirectory "run/$($variant.Workload)") -Raw | ConvertFrom-Json
    if (!$workload.AcceptancePassed -or $workload.CleanupErrors.Count -gt 0) { throw 'Workload acceptance failed.' }
    foreach ($process in $workload.Processes) {
        foreach ($processId in @($process.ProcessId, $process.CounterProcessId)) {
            if ($null -ne $processId -and (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { throw 'Owned process survived.' }
        }
    }
    if ($variant.Backlog -gt 0 -and $variant.ProcessedLatencyCoverage -ne 1) { throw 'Backlog latency lost samples.' }
    $latency = Get-Content (Join-Path $ArtifactDirectory "run/$($variant.Latency)") -Raw | ConvertFrom-Json
    foreach ($metric in $latency.Metrics) {
        if ($metric.P50Milliseconds -gt $metric.P95Milliseconds -or $metric.P95Milliseconds -gt $metric.P99Milliseconds -or $metric.MinMilliseconds -lt 0) {
            throw 'Invalid latency quantiles.'
        }
    }
    if ($variant.Monitoring -eq 'minimal' -and $workload.RuntimeCountersPresent) { throw 'Minimal mode pretends to collect counters.' }
}
$phase = $status.Variants[-1]
if ($phase.Phases.Count -ne 4 -or $phase.BacklogGrowth -lt 20) { throw 'Phase plan did not exercise growth and recovery.' }
$windows = @(Get-Content (Join-Path $ArtifactDirectory 'run/workload/phase-recovery/publisher-windows.jsonl') | ConvertFrom-Json)
if (@($windows.ProcessId | Sort-Object -Unique).Count -ne 1) { throw 'Publisher changed PID across phases.' }
$report = Get-Content (Join-Path $ArtifactDirectory 'run/reports/bench-report.json') -Raw | ConvertFrom-Json
if ($report.MonitoringComparisons.Count -ne 2 -or $report.MonitoringComparisons.SufficientRepetitions -contains $true) {
    throw 'Short local comparison pretends to have full repetitions.'
}
Write-Host 'PASS: batch variants, monitoring modes, persistent phase transitions, exact counts, cleanup, latency distributions and child cleanup.'
Write-Host 'Local integration does not validate cloud monitoring services or AWS.'
$smoke = & (Join-Path $DogfoodRoot 'cloud/aws/host/Run-CloudSmoke.ps1') -DogfoodRoot $DogfoodRoot `
    -ArtifactRoot (Join-Path $ArtifactDirectory 'smoke') -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath
$smokeResult = Get-Content $smoke -Raw | ConvertFrom-Json
if (!$smokeResult.AcceptancePassed -or $smokeResult.ExpectedMessages -ne 100) { throw 'The shared smoke path failed.' }
Write-Host 'PASS: cloud smoke uses the shared managed-readiness runner and reconciles 100 messages.'

# A completed workload is not enough if the requested pressure was not observed.
$failurePlan = $plan | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$failurePlan.variants = @($failurePlan.variants[-1])
$failurePlan.variants[0].minimumBacklogGrowth = 100000
$failurePath = Join-Path $ArtifactDirectory 'unmet-pressure.json'
$failurePlan | ConvertTo-Json -Depth 12 | Set-Content $failurePath
$rejected = $false
try {
    & (Join-Path $DogfoodRoot 'cloud/aws/host/Run-CloudBench.ps1') -ScenarioPath $failurePath `
        -DogfoodRoot $DogfoodRoot -EvidenceDirectory (Join-Path $ArtifactDirectory 'unmet-pressure') `
        -ConnectionString $ConnectionString -CounterToolPath $CounterToolPath | Out-Null
} catch { $rejected = $true }
$failure = Get-Content (Join-Path $ArtifactDirectory 'unmet-pressure/metadata/bench-status.json') -Raw | ConvertFrom-Json
if (!$rejected -or $failure.State -ne 'Failed' -or $failure.Variants[0].AcceptancePassed) {
    throw 'Unobserved overload was accepted or lost its failure manifest.'
}
Write-Host 'PASS: unmet pressure fails the campaign and preserves its report and workload evidence.'
