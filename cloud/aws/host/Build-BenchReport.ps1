#requires -Version 7.4
param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manifest = Get-Content (Join-Path $EvidenceDirectory 'metadata/bench-status.json') -Raw | ConvertFrom-Json
$rows = @()
foreach ($variant in $manifest.Variants) {
    $latency = Get-Content (Join-Path $EvidenceDirectory $variant.Latency) -Raw | ConvertFrom-Json
    $rows += [pscustomobject]@{
        Name = $variant.Name; WorkerCount = $variant.WorkerCount; BatchSize = $variant.BatchSize
        Monitoring = $variant.Monitoring; Backlog = $variant.Backlog; CleanupEnabled = $variant.CleanupEnabled
        AcceptancePassed = $variant.AcceptancePassed; Throughput = $variant.SettledMessagesPerSecond
        WorkerCpuMilliseconds = $variant.WorkerCpuMilliseconds
        WholeVariantHostBusyCpuSeconds = $variant.WholeVariantHostBusyCpuSeconds
        ProcessedLatencyCoverage = $variant.ProcessedLatencyCoverage
        DiagnosticCaptureAttempted = $variant.DiagnosticCaptureAttempted
        Latencies = @($latency.Metrics)
    }
}
$comparisons = @()
foreach ($group in $rows | Where-Object Backlog -GT 0 | Group-Object WorkerCount, BatchSize, Backlog, CleanupEnabled) {
    $full = @($group.Group | Where-Object Monitoring -EQ 'full')
    $minimal = @($group.Group | Where-Object Monitoring -EQ 'minimal')
    if ($full.Count -eq 0 -or $minimal.Count -eq 0) { continue }
    $valid = @($group.Group | Where-Object { !$_.AcceptancePassed -or $_.DiagnosticCaptureAttempted -or $_.ProcessedLatencyCoverage -lt 1 }).Count -eq 0
    $base = ($minimal | Measure-Object Throughput -Average).Average
    $measured = ($full | Measure-Object Throughput -Average).Average
    $comparisons += [pscustomobject]@{ Configuration = $group.Name; FullRuns = $full.Count; MinimalRuns = $minimal.Count
        EvidenceValid = $valid; MeanThroughputChangePercent = if ($valid -and $base -gt 0) { 100 * ($measured - $base) / $base } else { $null }
        SufficientRepetitions = $full.Count -ge 3 -and $minimal.Count -ge 3 }
}
$report = [ordered]@{ SchemaVersion = 1; State = $manifest.State; Variants = $rows; MonitoringComparisons = $comparisons
    MonitoringComparisonScope = if ($manifest.CloudMonitoringManaged) { 'Full stack versus minimal safety instrumentation' } else { 'Runtime collectors only; cloud exporters were not managed' }
    RecommendedWorkerLimit = $null; RecommendedBatchSize = $null
    Warnings = @(
        'Per-run/per-kind percentiles are not averaged or represented as pooled percentiles.',
        'Created-to-processed latency includes backlog age and retries, not commit ACK timing.',
        'Processed latency with coverage below 1 is censored by cleanup; do not use it as a complete distribution.',
        'Minimal monitoring retains workload, process safety sampling and TTL/S3 safeguards; it is not zero instrumentation.',
        'Whole-variant CPU includes reset/startup, drain, post-run queries and collector cleanup, not just the drain window.',
        'Diagnostic capture triggers GC and invalidates a clean performance comparison.',
        'Decide capacity from repeated throughput, per-kind latency, instrumentation coverage and timestamped database/host pressure. No automatic product defaults.') }
$path = Join-Path $EvidenceDirectory 'reports/bench-report.json'
$report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path
$lines = @('# Bench results', '', "State: $($manifest.State)", '',
    '| Variant | Workers | Batch | Monitoring | Settled/s | Accepted |', '| --- | ---: | ---: | --- | ---: | --- |')
foreach ($r in $rows) { $lines += "| $($r.Name) | $($r.WorkerCount) | $($r.BatchSize) | $($r.Monitoring) | $([Math]::Round($r.Throughput,2)) | $($r.AcceptancePassed) |" }
$lines += @('', 'See bench-report.json for per-kind p50/p95/p99, sample counts, comparison validity and caveats.', '', 'No worker or batch default is inferred automatically.')
$lines | Set-Content (Join-Path $EvidenceDirectory 'reports/bench-report.md')
Write-Output $path
