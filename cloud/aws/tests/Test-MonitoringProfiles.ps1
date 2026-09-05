#requires -Version 7.4
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../host/MonitoringProfile.ps1')
$global:benchProfileCalls = [Collections.Generic.List[object]]::new()
$global:benchProfileFailure = $false
function docker {
    $global:benchProfileCalls.Add(@($args))
    $global:LASTEXITCODE = if ($global:benchProfileFailure) { 2 } else { 0 }
    if ($args -contains 'ps') { Get-BenchMonitoringServices }
}
Assert-BenchMonitoringRunning 'offline-compose.yml'
try {
    Set-BenchMonitoringProfile 'offline-compose.yml' 'minimal'
    throw 'injected workload failure'
} catch {
    if ($_.Exception.Message -ne 'injected workload failure') { throw }
} finally { Set-BenchMonitoringProfile 'offline-compose.yml' 'full' }
foreach ($call in $global:benchProfileCalls) {
    if ($call -contains 'postgresql' -or $call -contains 'down' -or $call -contains 'up') { throw 'Profile changed database/resources.' }
    if ($call -contains 'stop' -or $call -contains 'start') {
        foreach ($service in Get-BenchMonitoringServices) { if ($call -notcontains $service) { throw 'Profile omitted a monitoring service.' } }
    }
}
$global:benchProfileFailure = $true
$failed = $false
try { Set-BenchMonitoringProfile 'offline-compose.yml' 'full' } catch { $failed = $true }
if (!$failed) { throw 'Failed monitor restart was hidden.' }
Write-Host 'PASS: explicit six-service stop/start, failure propagation and restoration pattern; database never controlled.'
