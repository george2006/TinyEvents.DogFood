#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScenarioPath,
    [Parameter(Mandatory)][string]$DogfoodRoot,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][string]$ConnectionString,
    [Parameter(Mandatory)][string]$CounterToolPath,
    [switch]$ManageMonitoringStack
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../ScenarioContract.ps1')
. (Join-Path $PSScriptRoot 'EvidenceLayout.ps1')
. (Join-Path $PSScriptRoot 'MonitoringProfile.ps1')
$scenario = Read-LabScenario $ScenarioPath
if ($scenario.runner -ne 'bench') { throw 'Run-CloudBench requires a bench scenario.' }
$layout = New-ExperimentEvidenceLayout $EvidenceDirectory
Copy-Item -LiteralPath $ScenarioPath -Destination (Join-Path $layout.metadata 'scenario.json')
$compose = Join-Path $PSScriptRoot 'docker-compose.cloud.yml'
$sampler = $null
$samplerStop = $null
$results = [Collections.Generic.List[object]]::new()
$monitoringTouched = $false
$manifest = [ordered]@{ SchemaVersion = 1; Scenario = $scenario.name; State = 'Running'
    CloudMonitoringManaged = [bool]$ManageMonitoringStack; StartedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    MinimalMode = 'No runtime collectors, exporters or infrastructure sampler. Process safety samples, workload journals and TTL/S3 safeguards remain enabled.'
    Variants = @() }

function Save-BenchManifest {
    $manifest.Variants = @($results)
    $path = Join-Path $layout.metadata 'bench-status.json'
    $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath "$path.tmp"
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}
function Stop-BenchSampler {
    if ($null -eq $script:sampler) { return }
    New-Item -ItemType File -Path $script:samplerStop -Force | Out-Null
    if (!$script:sampler.WaitForExit(15000)) { $script:sampler.Kill($true); $script:sampler.WaitForExit(5000) | Out-Null }
    $script:sampler.Dispose()
    $script:sampler = $null
}
function Get-HostCpuSnapshot {
    if (!(Test-Path '/proc/stat')) { return $null }
    $values = ((Get-Content '/proc/stat' -TotalCount 1).Trim() -split '\s+') | Select-Object -Skip 1
    # USER_HZ is platform-dependent. guest fields already belong to user/nice.
    $ticksPerSecond = [double](& getconf CLK_TCK)
    if ($LASTEXITCODE -ne 0 -or $ticksPerSecond -le 0) { throw 'Could not determine host CPU clock ticks.' }
    $busy = [double]$values[0] + [double]$values[1] + [double]$values[2] + [double]$values[5] + [double]$values[6]
    return $busy / $ticksPerSecond
}

try {
    & dotnet --info > (Join-Path $layout.metadata 'dotnet-info.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Could not record the .NET environment.' }
    & $CounterToolPath --version > (Join-Path $layout.metadata 'dotnet-counters-version.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Could not record the counter tool version.' }
    if ($ManageMonitoringStack) {
        if (!$IsLinux -or !(Test-Path '/etc/tinyevents-lab/environment')) { throw 'Monitoring control requires the Linux lab host.' }
        Assert-BenchMonitoringRunning $compose
    }
    foreach ($variant in $scenario.variants) {
        Save-BenchManifest
        $work = Join-Path $layout.workload $variant.name
        $runtime = Join-Path $layout.runtime $variant.name
        $logs = Join-Path $layout.logs $variant.name
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        if ($ManageMonitoringStack) {
            $monitoringTouched = $true
            Set-BenchMonitoringProfile $compose $variant.monitoring
            Start-Sleep -Seconds 30 # Same pause in both profiles; no benchmark work yet.
            if ($variant.monitoring -eq 'full') {
                $script:samplerStop = Join-Path $logs 'stop-sampler'
                $samplePath = Join-Path $layout.infrastructure "$($variant.name).jsonl"
                $script:sampler = Start-Process /usr/bin/bash -ArgumentList @(
                    (Join-Path $PSScriptRoot 'sample-experiment.sh'), $samplePath, $script:samplerStop, '10') `
                    -RedirectStandardOutput (Join-Path $logs 'sampler.stdout.log') `
                    -RedirectStandardError (Join-Path $logs 'sampler.stderr.log') -PassThru
            }
        }
        $beforeCpu = Get-HostCpuSnapshot
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $parameters = @{
            DogfoodRoot = $DogfoodRoot; ArtifactDirectory = $work; RuntimeDirectory = $runtime; LogDirectory = $logs
            ConnectionString = $ConnectionString; CounterToolPath = $CounterToolPath
            WorkerCount = $variant.workerCount; BatchSize = $variant.batchSize; Backlog = $variant.backlog
            CleanupEnabled = $variant.cleanupEnabled; RetentionSeconds = $variant.retentionSeconds
            SlowMilliseconds = $variant.slowMilliseconds; CountersEnabled = ($variant.monitoring -eq 'full')
            RequireRateTarget = $variant.requireRateTarget; Phases = @($variant.phases)
            AutomaticDiagnostics = $variant.automaticDiagnostics; SettlementSeconds = 600; ResetDatabase = $true
            CounterIntervalSeconds = if (($variant.phases | Measure-Object durationSeconds -Sum).Sum -ge 7200) { 10 } else { 1 }
        }
        try { $resultPath = & (Join-Path $PSScriptRoot 'Run-CloudSoak.ps1') @parameters }
        finally { Stop-BenchSampler }
        $timer.Stop()
        $afterCpu = Get-HostCpuSnapshot
        if ($ManageMonitoringStack -and $variant.monitoring -eq 'full') {
            & (Join-Path $PSScriptRoot 'Summarize-ExperimentSamples.ps1') `
                -InputPath (Join-Path $layout.infrastructure "$($variant.name).jsonl") `
                -OutputPath (Join-Path $layout.reports "$($variant.name).infrastructure.json") | Out-Null
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $phaseSummary = @()
        $journalPath = Join-Path $work 'publisher-windows.jsonl'
        if (Test-Path $journalPath) {
            # Bench plans are bounded to 24h / one row per second. Aggregate streaming.
            $phaseMap = [ordered]@{}
            foreach ($line in [IO.File]::ReadLines($journalPath)) {
                $window = $line | ConvertFrom-Json
                if (!$phaseMap.Contains($window.Phase)) {
                    $phaseMap[$window.Phase] = [ordered]@{ Name = $window.Phase; MinOutstanding = [long]$window.Outstanding
                        MaxOutstanding = [long]$window.Outstanding; LastOutstanding = [long]$window.Outstanding
                        Windows = 0; Committed = 0L; StartedAtUtc = $window.StartedAtUtc; CompletedAtUtc = $window.CompletedAtUtc }
                }
                $p = $phaseMap[$window.Phase]
                $p.MinOutstanding = [Math]::Min($p.MinOutstanding, $window.Outstanding)
                $p.MaxOutstanding = [Math]::Max($p.MaxOutstanding, $window.Outstanding)
                $p.LastOutstanding = $window.Outstanding
                $p.Windows++
                $p.CompletedAtUtc = $window.CompletedAtUtc
                foreach ($entry in $window.Results) { $p.Committed += $entry.Load.CommittedRequests }
            }
            $phaseSummary = @($phaseMap.Values | ForEach-Object { [pscustomobject]$_ })
        }
        $growth = 0
        $recoveryPassed = $true
        if ($phaseSummary.Count -gt 0) {
            $growth = ($phaseSummary | Measure-Object MaxOutstanding -Maximum).Maximum - $phaseSummary[0].MinOutstanding
        }
        if ($variant.minimumBacklogGrowth -gt 0) {
            $growth = ($phaseSummary | Where-Object Name -CEQ 'overload').MaxOutstanding - ($phaseSummary | Where-Object Name -CEQ 'baseline').LastOutstanding
            $recoveryPassed = ($phaseSummary | Where-Object Name -CEQ 'recovery').LastOutstanding -eq 0
        }
        $row = [ordered]@{
            Name = $variant.name; WorkerCount = $variant.workerCount; BatchSize = $variant.batchSize
            Monitoring = $variant.monitoring; Backlog = $variant.backlog; CleanupEnabled = $variant.cleanupEnabled
            AcceptancePassed = $result.AcceptancePassed -and $growth -ge $variant.minimumBacklogGrowth -and $recoveryPassed
            RecoveryPhaseDrained = $recoveryPassed
            BacklogGrowth = $growth; MinimumRequiredBacklogGrowth = $variant.minimumBacklogGrowth
            SettledMessagesPerSecond = $result.SettledMessagesPerSecond
            WorkerCpuMilliseconds = $result.WorkerCpuMilliseconds
            WholeVariantHostBusyCpuSeconds = if ($null -ne $beforeCpu -and $null -ne $afterCpu) { $afterCpu - $beforeCpu } else { $null }
            WholeVariantWallSeconds = $timer.Elapsed.TotalSeconds
            DiagnosticCaptureAttempted = $result.DiagnosticCaptureAttempted
            RuntimeCountersPresent = $result.RuntimeCountersPresent
            ProcessedLatencyCoverage = $result.ProcessedLatencyCoverage
            Phases = $phaseSummary
            Workload = "workload/$($variant.name)/result.json"; Latency = "workload/$($variant.name)/latency.json"
        }
        $results.Add([pscustomobject]$row)
        Save-BenchManifest
        if (!$row.AcceptancePassed) { throw "Variant '$($variant.name)' failed its contract (including required backlog growth)." }
    }
    $manifest.State = 'Succeeded'
}
catch { $manifest.State = 'Failed'; $manifest.Error = $_.Exception.Message; throw }
finally {
    Stop-BenchSampler
    if ($monitoringTouched) {
        try { Set-BenchMonitoringProfile $compose 'full' }
        catch { $manifest.State = 'Failed'; $manifest.MonitoringRestoreFailed = $true; $manifest.MonitoringRestoreError = $_.Exception.Message }
    }
    $manifest.CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    Save-BenchManifest
    & (Join-Path $PSScriptRoot 'Build-BenchReport.ps1') -EvidenceDirectory $layout.Root | Out-Null
}
if ($manifest.State -ne 'Succeeded') { throw 'The bench did not finish successfully; inspect its manifest.' }
Write-Output (Join-Path $layout.metadata 'bench-status.json')
