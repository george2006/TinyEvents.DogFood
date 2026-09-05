Set-StrictMode -Version Latest
function Get-BenchMonitoringServices {
    return @('prometheus','grafana','node-exporter','cadvisor','process-exporter','postgres-exporter')
}
function Assert-BenchMonitoringRunning {
    param([string]$ComposePath)
    $running = @(& docker compose -f $ComposePath ps --status running --services)
    if ($LASTEXITCODE -ne 0 -or @((Get-BenchMonitoringServices) | Where-Object { $running -notcontains $_ }).Count -gt 0) {
        throw 'All six monitoring services must be running; PostgreSQL is not controlled by monitoring profiles.'
    }
}
function Set-BenchMonitoringProfile {
    param([string]$ComposePath, [ValidateSet('full','minimal')][string]$Mode)
    $services = @(Get-BenchMonitoringServices)
    if ($Mode -eq 'minimal') { & docker compose -f $ComposePath stop -t 15 @services | Out-Null }
    else { & docker compose -f $ComposePath start @services | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "Could not switch monitoring to '$Mode'." }
    if ($Mode -eq 'full') { Assert-BenchMonitoringRunning $ComposePath }
}
