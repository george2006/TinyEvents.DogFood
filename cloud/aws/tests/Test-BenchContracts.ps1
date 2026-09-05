#requires -Version 7.4
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../ScenarioContract.ps1')
. (Join-Path $PSScriptRoot '../host/MemoryDiagnostics.ps1')
function Reject([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (!$failed) { throw 'Invalid contract was accepted.' }
}
$source = Get-Content (Join-Path $PSScriptRoot '../scenarios/mixed-pressure.json') -Raw
foreach ($change in @(
    { param($d) $d.variants[0].batchSize = 0 },
    { param($d) $d.variants[0].monitoring = 'maybe' },
    { param($d) $d.variants[0].phases[0].rate = 21 },
    { param($d) $d.variants[0].phases[0].contentBytes = 20000 },
    { param($d) $d.variants[0].phases[0].name = '../escape' },
    { param($d) $d.variants[0].phases[1].name = $d.variants[0].phases[0].name },
    { param($d) $d.variants[0].cleanupEnabled = 'false' },
    { param($d) $d.variants[0].automaticDiagnostics = $true; $d.variants[0].monitoring = 'minimal' },
    { param($d) $d.variants[0].backlog = 100 },
    { param($d) $d.estimatedMaximumMinutes = 1 }
)) {
    $d = $source | ConvertFrom-Json
    & $change $d
    Reject { Assert-BenchVariants $d }
}
Write-Host 'PASS: malformed variants, phase rates/payloads/names, modes and insufficient duration fail closed.'
$state = New-MemoryDiagnosticState
$now = [DateTimeOffset]::UtcNow
function Sample([int]$Seconds, [long]$Bytes, [int]$ProcessId = 17) {
    return [pscustomobject]@{ TimestampUtc = $now.AddSeconds($Seconds).ToString('O'); ProcessId = $ProcessId
        HasExited = $false; WorkingSetBytes = $Bytes }
}
foreach ($seconds in @(0,60,300,899,900)) {
    if (Test-MemoryDiagnosticTrigger $state (Sample $seconds 100MB)) { throw 'Premature diagnostic trigger.' }
}
foreach ($seconds in @(960,1020,1080,1140)) {
    if (Test-MemoryDiagnosticTrigger $state (Sample $seconds 500MB)) { throw 'Growth was not sustained long enough.' }
}
if (!(Test-MemoryDiagnosticTrigger $state (Sample 1200 500MB))) { throw 'Sustained growth did not trigger.' }
if (Test-MemoryDiagnosticTrigger $state (Sample 1260 900MB)) { throw 'Second capture attempt allowed.' }
if (Test-MemoryDiagnosticTrigger $state (Sample 1300 900MB 18)) { throw 'Second PID bypassed the run quota.' }
Write-Host 'PASS: warm-up, five spaced growth samples and one diagnostic attempt across all PIDs.'
