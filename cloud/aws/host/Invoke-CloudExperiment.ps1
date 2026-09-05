[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScenarioPath,
    [string]$DogfoodRoot = "/opt/tinyevents-lab/sources/TinyEvents.Dogfood",
    [string]$TinyEventsRoot = "/opt/tinyevents-lab/sources/TinyEvents",
    [string]$ArtifactRoot = "/opt/tinyevents-lab/artifacts"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'EvidenceLayout.ps1')

if (!(Test-Path -LiteralPath $ScenarioPath)) {
    throw "Scenario '$ScenarioPath' was not found."
}

$scenarioBytes = [IO.File]::ReadAllBytes($ScenarioPath)
$scenarioHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($scenarioBytes))
$scenario = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json

if ($scenario.schemaVersion -ne 1) {
    throw "Unsupported scenario schema version '$($scenario.schemaVersion)'."
}

if ($scenario.name -notmatch "^[a-z0-9][a-z0-9-]{1,62}$") {
    throw "Scenario name '$($scenario.name)' is invalid."
}

$lockPath = "/opt/tinyevents-lab/experiment.lock"
$lock = [IO.File]::Open(
    $lockPath,
    [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None)

$runId = "{0}-{1}-{2}" -f $scenario.name, ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$runDirectory = Join-Path $ArtifactRoot $runId
$layout = New-ExperimentEvidenceLayout $runDirectory
$statusPath = "/opt/tinyevents-lab/experiment-status.json"
$startedAtUtc = [DateTimeOffset]::UtcNow
$sampler = $null
$samplerStopPath = Join-Path $layout.logs "stop-sampler"
$evidenceUploader = '/usr/local/sbin/tinyevents-lab-sync-evidence'

function Save-ExperimentStatus {
    param(
        [string]$State,
        [string]$Detail,
        [Nullable[int]]$ExitCode = $null
    )

    [ordered]@{
        Scenario = $scenario.name
        RunId = $runId
        State = $State
        Detail = $Detail
        StartedAtUtc = $startedAtUtc.ToString("O")
        UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        ExitCode = $ExitCode
        ScenarioSha256 = $scenarioHash
        ArtifactDirectory = $runDirectory
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$statusPath.tmp"
    Move-Item -LiteralPath "$statusPath.tmp" -Destination $statusPath -Force
    $runStatusPath = Join-Path $layout.metadata 'status.json'
    Copy-Item -LiteralPath $statusPath -Destination "$runStatusPath.tmp" -Force
    Move-Item -LiteralPath "$runStatusPath.tmp" -Destination $runStatusPath -Force
}

function Sync-ExperimentEvidence {
    $previousArtifactRoot = $env:LAB_ARTIFACT_ROOT
    try {
        $env:LAB_ARTIFACT_ROOT = $ArtifactRoot
        & bash $evidenceUploader run $runId
        if ($LASTEXITCODE -ne 0) {
            throw "Experiment evidence upload failed (exit $LASTEXITCODE)."
        }
    }
    finally {
        $env:LAB_ARTIFACT_ROOT = $previousArtifactRoot
    }
}

function Stop-ExperimentSampler {
    param(
        [Diagnostics.Process]$Process,
        [Threading.Tasks.Task[string]]$OutputTask,
        [Threading.Tasks.Task[string]]$ErrorTask
    )

    New-Item -ItemType File -Force -Path $samplerStopPath | Out-Null
    if (!$Process.WaitForExit(15000)) {
        $Process.Kill()
        $Process.WaitForExit()
    }

    $OutputTask.GetAwaiter().GetResult() |
        Set-Content -LiteralPath (Join-Path $layout.logs "sampler.stdout.log")
    $ErrorTask.GetAwaiter().GetResult() |
        Set-Content -LiteralPath (Join-Path $layout.logs "sampler.stderr.log")
    $Process.Dispose()
}

try {
    if (Test-Path -LiteralPath '/opt/tinyevents-lab/expiry-started') {
        throw 'The laboratory has expired; no new experiment may start.'
    }
    if (!(Test-Path -LiteralPath $evidenceUploader)) {
        throw 'The evidence uploader is missing; bootstrap the current laboratory configuration first.'
    }
    Save-ExperimentStatus "Running" "Preparing scenario."
    Copy-Item -LiteralPath $ScenarioPath -Destination (Join-Path $layout.metadata "scenario.json")
    if (Test-Path -LiteralPath '/opt/tinyevents-lab/source-manifest.json') {
        Copy-Item -LiteralPath '/opt/tinyevents-lab/source-manifest.json' `
            -Destination (Join-Path $layout.metadata 'source-manifest.json')
    }
    $samplerScript = Join-Path $DogfoodRoot "cloud/aws/host/sample-experiment.sh"
    & chmod +x $samplerScript
    $samplerStart = [Diagnostics.ProcessStartInfo]::new()
    $samplerStart.FileName = "/usr/bin/bash"
    $samplerStart.UseShellExecute = $false
    $samplerStart.CreateNoWindow = $true
    $samplerStart.RedirectStandardOutput = $true
    $samplerStart.RedirectStandardError = $true
    $samplerStart.Arguments =
        "`"$samplerScript`" " +
        "`"$(Join-Path $layout.infrastructure 'experiment-samples.jsonl')`" " +
        "`"$samplerStopPath`" 10"
    $sampler = [Diagnostics.Process]::new()
    $sampler.StartInfo = $samplerStart
    if (!$sampler.Start()) {
        throw "Experiment resource sampler could not be started."
    }
    $samplerOutputTask = $sampler.StandardOutput.ReadToEndAsync()
    $samplerErrorTask = $sampler.StandardError.ReadToEndAsync()

    switch ($scenario.runner) {
        "memory-soak" {
            Save-ExperimentStatus "Running" "Sustained mixed work with persistent worker and publisher processes."
            $soakScript = Join-Path $DogfoodRoot "cloud/aws/host/Run-CloudSoak.ps1"
            & $soakScript -DogfoodRoot $DogfoodRoot `
                -ArtifactDirectory (Join-Path $layout.workload 'soak') `
                -RuntimeDirectory (Join-Path $layout.runtime 'soak') `
                -LogDirectory (Join-Path $layout.logs 'soak') `
                -ConnectionString 'Host=localhost;Port=54323;Database=TinyEventsDogfoodOperations;Username=postgres;Password=postgres;Maximum Pool Size=16;Timeout=2;' `
                -DurationSeconds $scenario.durationSeconds -Rate $scenario.rate `
                -WorkerCount $scenario.workerCount -WindowSeconds $scenario.windowSeconds `
                -SettlementSeconds $scenario.settlementSeconds `
                -CounterToolPath '/opt/dotnet-tools/dotnet-counters' -ResetDatabase | Out-Null
        }

        "cloud-smoke" {
            Save-ExperimentStatus "Running" "Executing cloud smoke."
            $smokeScript = Join-Path $DogfoodRoot "cloud/aws/host/Run-CloudSmoke.ps1"
            & $smokeScript `
                -DogfoodRoot $DogfoodRoot `
                -ArtifactRoot $layout.workload `
                -MessageCount $scenario.messageCount | Out-Null
        }

        "worker-scaling" {
            if ($scenario.repetitions -lt 1 -or $scenario.repetitions -gt 10) {
                throw "Worker-scaling repetitions must be between 1 and 10."
            }

            $runner = Join-Path $DogfoodRoot "operations/Run-WorkerDrainLoad.ps1"
            $env:TINYEVENTS_DOGFOOD_DOTNET_COUNTERS =
                "/opt/dotnet-tools/dotnet-counters"
            $env:TINYEVENTS_DOGFOOD_COUNTER_INTERVAL_SECONDS = "10"
            for ($repetition = 1; $repetition -le $scenario.repetitions; $repetition++) {
                Save-ExperimentStatus `
                    "Running" `
                    "Worker scaling repetition $repetition of $($scenario.repetitions)."

                $beforeDirectories = @(
                    Get-ChildItem (Join-Path $DogfoodRoot "artifacts/load") `
                        -Directory `
                        -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName)

                & $runner `
                    -StorageProvider $scenario.storageProvider `
                    -Backlog $scenario.backlog `
                    -WorkerCounts $scenario.workerCounts

                if ($LASTEXITCODE -ne 0) {
                    throw "Worker scaling repetition $repetition failed."
                }

                $afterDirectory = Get-ChildItem (Join-Path $DogfoodRoot "artifacts/load") `
                    -Directory |
                    Where-Object { $beforeDirectories -notcontains $_.FullName } |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1

                if ($null -eq $afterDirectory) {
                    throw "Worker scaling did not create an evidence directory."
                }

                Copy-Item `
                    -LiteralPath $afterDirectory.FullName `
                    -Destination (Join-Path $layout.workload "repetition-$repetition") `
                    -Recurse
            }
        }

        default {
            throw "Unknown cloud scenario runner '$($scenario.runner)'."
        }
    }

    Stop-ExperimentSampler $sampler $samplerOutputTask $samplerErrorTask
    $sampler = $null

    $infrastructureSummaryScript = Join-Path `
        $DogfoodRoot `
        "cloud/aws/host/Summarize-ExperimentSamples.ps1"
    & $infrastructureSummaryScript `
        -InputPath (Join-Path $layout.infrastructure "experiment-samples.jsonl") `
        -OutputPath (Join-Path $layout.reports "infrastructure-summary.json") | Out-Null

    $summaryScript = Join-Path `
        $DogfoodRoot `
        "cloud/aws/host/Summarize-RuntimeCounters.ps1"
    & $summaryScript `
        -EvidenceDirectory $runDirectory `
        -OutputPath (Join-Path $layout.reports "runtime-summary.json") | Out-Null

    if ($scenario.runner -eq "worker-scaling") {
        $scalingReportScript = Join-Path `
            $DogfoodRoot `
            "cloud/aws/host/Build-WorkerScalingReport.ps1"
        & $scalingReportScript `
            -EvidenceDirectory $runDirectory `
            -OutputPath (Join-Path $layout.reports "worker-scaling-report.json") | Out-Null
    }

    Save-ExperimentStatus "Uploading" "Uploading complete experiment evidence."
    Sync-ExperimentEvidence

    Save-ExperimentStatus "Succeeded" "Experiment and evidence upload completed." 0
    Sync-ExperimentEvidence
}
catch {
    if ($null -ne $sampler) {
        Stop-ExperimentSampler $sampler $samplerOutputTask $samplerErrorTask
        $sampler = $null
    }

    Save-ExperimentStatus "Failed" $_.Exception.Message 1

    try {
        Sync-ExperimentEvidence
    }
    catch {
        Write-Warning "Partial failure evidence could not be uploaded: $($_.Exception.Message)"
    }

    throw
}
finally {
    if ($null -ne $sampler) {
        Stop-ExperimentSampler $sampler $samplerOutputTask $samplerErrorTask
    }

    $lock.Dispose()
}
