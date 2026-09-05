#requires -Version 7.4
param([string]$BaseUri = 'http://tinyevents-bench-grafana:3000')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$dashboard = Invoke-RestMethod "$BaseUri/api/dashboards/uid/tinyevents-lab"
if ($dashboard.dashboard.panels.Count -ne 13 -or $dashboard.dashboard.uid -ne 'tinyevents-lab') { throw 'Dashboard provisioning failed.' }
$sources = Invoke-RestMethod "$BaseUri/api/datasources"
if (@($sources | Where-Object uid -EQ 'tinyevents-prometheus').Count -ne 1) { throw 'Stable datasource UID was not provisioned.' }
Write-Host 'PASS: Grafana provisioned the laboratory dashboard and its datasource.'
Write-Host 'This checks provisioning, not exporter data or Prometheus query coverage.'
