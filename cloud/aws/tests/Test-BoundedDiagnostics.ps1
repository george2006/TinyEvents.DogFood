#requires -Version 7.4
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../host/ProcessDiagnostics.ps1')
if (!$IsLinux) { throw 'This fixture exercises Linux process-tree cleanup.' }
$temp = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-dump-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temp | Out-Null
$tool = Join-Path $temp 'gcdump-command.sh'
Copy-Item (Join-Path $PSScriptRoot 'fixtures/gcdump-command.sh') $tool
& chmod +x $tool
$target = [Diagnostics.Process]::GetCurrentProcess()
$previousMode = $env:LAB_GCDUMP_TEST_MODE
try {
    foreach ($mode in @('success','failure','large','hang')) {
        $env:LAB_GCDUMP_TEST_MODE = $mode
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $failed = $false
        try { Invoke-BoundedGcDump $target (Join-Path $temp "$mode.gcdump") -ToolPath $tool -MinimumFreeGiB 1 -MaximumBytes 1048576 -TimeoutSeconds 2 | Out-Null }
        catch { $failed = $true }
        if ($mode -eq 'success' -and $failed) { throw 'Valid fixture capture failed.' }
        if ($mode -ne 'success' -and !$failed) { throw "$mode capture was incorrectly accepted." }
        if ($timer.Elapsed.TotalSeconds -gt 10) { throw "$mode exceeded the outer time bound." }
    }
    $failed = $false
    try { Invoke-BoundedGcDump $target (Join-Path $temp 'success.gcdump') -ToolPath $tool | Out-Null } catch { $failed = $true }
    if (!$failed) { throw 'Existing dump evidence was overwritten.' }
    Write-Host 'PASS: successful, failed, oversized and hung collectors; bounded process cleanup and overwrite protection.'
} finally { $env:LAB_GCDUMP_TEST_MODE = $previousMode; $target.Dispose() }
