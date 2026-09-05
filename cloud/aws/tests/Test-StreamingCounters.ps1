#requires -Version 7.4
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$temp = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-counters-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temp | Out-Null
$csv = Join-Path $temp 'worker-1.runtime.csv'
$now = [DateTimeOffset]::Parse('2026-09-05T00:00:00Z')
0..60 | ForEach-Object {
    [pscustomobject]@{ Timestamp = $now.AddMinutes($_).ToString('O'); 'Counter Name' = 'Working Set (MB)'
        'Counter Type' = 'Metric'; 'Mean/Increment' = 100 + $_ }
} | Export-Csv -LiteralPath $csv -NoTypeInformation
$output = Join-Path $temp 'summary.json'
& (Join-Path $PSScriptRoot '../host/Summarize-RuntimeCounters.ps1') -EvidenceDirectory $temp -OutputPath $output | Out-Null
$summary = Get-Content $output -Raw | ConvertFrom-Json
$metric = $summary.Workers[0].Metrics.'Working Set (MB)'
if (!$metric.SlopeEligible -or [Math]::Abs($metric.SlopePerHour - 60) -gt 0.00001 -or
    $metric.SampleCount -ne 61 -or $metric.PostWarmupSampleCount -ne 46 -or
    $metric.Mean -ne 130 -or $metric.Last -ne 160 -or $summary.Workers[0].RowCount -ne 61) {
    throw 'Streaming aggregates or warm-up exclusion differ from known analytic values.'
}
& (Join-Path $PSScriptRoot '../host/Summarize-RuntimeCounters.ps1') -EvidenceDirectory $temp -OutputPath $output -MinimumSlopeDurationMinutes 60 | Out-Null
$summary = Get-Content $output -Raw | ConvertFrom-Json
if ($null -ne $summary.Workers[0].Metrics.'Working Set (MB)'.SlopePerHour) { throw 'Insufficient post-warm-up history produced a slope.' }
Write-Host 'PASS: streaming min/max/mean/last/count and known slope; warm-up and duration gates.'
