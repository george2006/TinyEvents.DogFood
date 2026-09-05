#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$hostScripts = Join-Path $PSScriptRoot '../host'
. (Join-Path $hostScripts 'EvidenceLayout.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-layout-$([Guid]::NewGuid().ToString('N'))"
$layout = New-ExperimentEvidenceLayout (Join-Path $testRoot 'run with spaces')
foreach ($name in @('metadata', 'workload', 'runtime', 'infrastructure', 'logs', 'reports')) {
    if (!(Test-Path -LiteralPath $layout.$name -PathType Container)) { throw "Missing $name folder" }
}
$index = Get-Content (Join-Path $layout.Root 'layout.json') -Raw | ConvertFrom-Json
if ($index.SchemaVersion -ne 2 -or $index.Status -ne 'metadata/status.json') { throw 'Invalid index' }
if (!(Test-Path (Join-Path $layout.Root 'README.md'))) { throw 'Missing human-readable index' }
$rejected = $false
try { New-ExperimentEvidenceLayout $layout.Root | Out-Null }
catch { $rejected = $_.Exception.Message -like 'Evidence directory already exists:*' }
if (!$rejected) { throw 'Existing run was not protected' }
Write-Host 'PASS: categorized layout, indexes, paths with spaces, and overwrite rejection'

# The new folders must not silently disable pressure or instrumentation checks.
$scenarioPath = Join-Path $layout.workload 'repetition-1/TE-L02'
New-Item -ItemType Directory -Path $scenarioPath -Force | Out-Null
@{
    Variants = @(@{
        WorkerCount = 1; DrainMessagesPerSecond = 100; ScalingEfficiencyPercentage = 100
        AcceptancePassed = $true
        StartedAtUtc = '2026-09-05T08:00:00Z'; CompletedAtUtc = '2026-09-05T08:01:00Z'
    })
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioPath 'result.json')
@{
    timestampUtc = '2026-09-05T08:00:30Z'
    host = @{ memory = @{ swapUsedBytes = 0 } }
    postgresql = @{ activity = @{ waiting_connections = 2 }; outbox = @{ oldest_pending_seconds = 5 } }
} | ConvertTo-Json -Compress -Depth 8 | Set-Content (Join-Path $layout.infrastructure 'experiment-samples.jsonl')
@{ Variants = @(@{ WorkerCount = 1; CompleteInstrumentation = $false }) } |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $layout.reports 'runtime-summary.json')
$reportPath = Join-Path $layout.reports 'worker-scaling-report.json'
& (Join-Path $hostScripts 'Build-WorkerScalingReport.ps1') -EvidenceDirectory $layout.Root -OutputPath $reportPath | Out-Null
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
if (!$report.Variants[0].PressureVeto -or $report.Variants[0].InstrumentationComplete -or
    $report.Variants[0].InfrastructureWindowSampleCount -ne 1) {
    throw 'Categorized evidence did not preserve pressure/instrumentation checks'
}
Write-Host 'PASS: worker-scaling report reads categorized evidence and preserves vetoes'

Move-Item (Join-Path $layout.infrastructure 'experiment-samples.jsonl') $layout.Root
Move-Item (Join-Path $layout.reports 'runtime-summary.json') $layout.Root
& (Join-Path $hostScripts 'Build-WorkerScalingReport.ps1') -EvidenceDirectory $layout.Root -OutputPath $reportPath | Out-Null
$legacyReport = Get-Content $reportPath -Raw | ConvertFrom-Json
if (!$legacyReport.Variants[0].PressureVeto -or $legacyReport.Variants[0].InstrumentationComplete) {
    throw 'Legacy flat evidence compatibility regressed'
}
Write-Host 'PASS: historical flat evidence remains readable'

$repository = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$scriptFiles = @(Get-ChildItem (Join-Path $repository 'cloud/aws') -Recurse -Filter '*.ps1')
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "$($file.Name): $($parseErrors.Message -join '; ')" }
}
Write-Host "PASS: parsed all $($scriptFiles.Count) cloud PowerShell scripts"
