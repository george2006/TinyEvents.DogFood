#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$DogfoodRoot = "/opt/tinyevents-lab/sources/TinyEvents.Dogfood",
    [string]$ArtifactRoot = "/opt/tinyevents-lab/artifacts",
    [string]$CounterToolPath = "/opt/dotnet-tools/dotnet-counters",
    [string]$ConnectionString = 'Host=localhost;Port=54323;Database=TinyEventsDogfoodOperations;Username=postgres;Password=postgres;Maximum Pool Size=16;Timeout=2;',
    [ValidateRange(1, 10000)][int]$MessageCount = 100
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'EvidenceLayout.ps1')
$runId = "smoke-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
$layout = New-ExperimentEvidenceLayout (Join-Path $ArtifactRoot $runId)
$resultPath = & (Join-Path $PSScriptRoot 'Run-CloudSoak.ps1') -DogfoodRoot $DogfoodRoot `
    -ArtifactDirectory (Join-Path $layout.workload 'smoke') -RuntimeDirectory $layout.runtime -LogDirectory $layout.logs `
    -ConnectionString $ConnectionString `
    -CounterToolPath $CounterToolPath -Backlog $MessageCount -WorkerCount 1 -BatchSize 10 -CleanupEnabled $false -ResetDatabase
Copy-Item -LiteralPath $resultPath -Destination (Join-Path $layout.Root 'result.json')
Write-Output (Join-Path $layout.Root 'result.json')
