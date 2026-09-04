[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScenarioPath,
    [string]$DogfoodRoot = "/opt/tinyevents-lab/sources/TinyEvents.Dogfood",
    [string]$TinyEventsRoot = "/opt/tinyevents-lab/sources/TinyEvents",
    [string]$ArtifactRoot = "/opt/tinyevents-lab/artifacts"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

$runId = "{0}-{1}" -f $scenario.name, (Get-Date -Format "yyyyMMdd-HHmmss")
$runDirectory = Join-Path $ArtifactRoot $runId
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
$statusPath = "/opt/tinyevents-lab/experiment-status.json"
$startedAtUtc = [DateTimeOffset]::UtcNow
$sampler = $null
$samplerStopPath = Join-Path $runDirectory "stop-sampler"

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
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statusPath
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
        Set-Content -LiteralPath (Join-Path $runDirectory "sampler.stdout.log")
    $ErrorTask.GetAwaiter().GetResult() |
        Set-Content -LiteralPath (Join-Path $runDirectory "sampler.stderr.log")
    $Process.Dispose()
}

try {
    Save-ExperimentStatus "Running" "Preparing scenario."
    Copy-Item -LiteralPath $ScenarioPath -Destination (Join-Path $runDirectory "scenario.json")
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
        "`"$(Join-Path $runDirectory 'experiment-samples.jsonl')`" " +
        "`"$samplerStopPath`" 10"
    $sampler = [Diagnostics.Process]::new()
    $sampler.StartInfo = $samplerStart
    if (!$sampler.Start()) {
        throw "Experiment resource sampler could not be started."
    }
    $samplerOutputTask = $sampler.StandardOutput.ReadToEndAsync()
    $samplerErrorTask = $sampler.StandardError.ReadToEndAsync()

    switch ($scenario.runner) {
        "cloud-smoke" {
            Save-ExperimentStatus "Running" "Executing cloud smoke."
            $smokeScript = Join-Path $DogfoodRoot "cloud/aws/host/Run-CloudSmoke.ps1"
            & $smokeScript `
                -DogfoodRoot $DogfoodRoot `
                -ArtifactRoot $runDirectory `
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
                    -Destination (Join-Path $runDirectory "repetition-$repetition") `
                    -Recurse
            }
        }

        default {
            throw "Unknown cloud scenario runner '$($scenario.runner)'."
        }
    }

    Stop-ExperimentSampler $sampler $samplerOutputTask $samplerErrorTask
    $sampler = $null

    $summaryScript = Join-Path `
        $DogfoodRoot `
        "cloud/aws/host/Summarize-RuntimeCounters.ps1"
    & $summaryScript `
        -EvidenceDirectory $runDirectory `
        -OutputPath (Join-Path $runDirectory "runtime-summary.json") | Out-Null

    $environmentValues = @{}
    foreach ($line in Get-Content -LiteralPath "/etc/tinyevents-lab/environment") {
        if ($line -match "^([^=]+)=(.*)$") {
            $environmentValues[$Matches[1]] = $Matches[2]
        }
    }

    $bucket = $environmentValues["LAB_RESULTS_BUCKET"]
    if ([string]::IsNullOrWhiteSpace($bucket)) {
        throw "LAB_RESULTS_BUCKET is unavailable."
    }

    Save-ExperimentStatus "Uploading" "Uploading complete experiment evidence."
    Copy-Item -LiteralPath $statusPath -Destination (Join-Path $runDirectory "status.json")
    & aws s3 cp $runDirectory "s3://$bucket/runs/$runId/" --recursive --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Experiment evidence upload failed."
    }

    Save-ExperimentStatus "Succeeded" "Experiment and evidence upload completed." 0
    Copy-Item -LiteralPath $statusPath -Destination (Join-Path $runDirectory "status.json") -Force
    & aws s3 cp `
        (Join-Path $runDirectory "status.json") `
        "s3://$bucket/runs/$runId/status.json" `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Final experiment status upload failed."
    }
}
catch {
    if ($null -ne $sampler) {
        Stop-ExperimentSampler $sampler $samplerOutputTask $samplerErrorTask
        $sampler = $null
    }

    Save-ExperimentStatus "Failed" $_.Exception.Message 1
    Copy-Item -LiteralPath $statusPath -Destination (Join-Path $runDirectory "status.json") -Force

    try {
        $environmentLine = Get-Content -LiteralPath "/etc/tinyevents-lab/environment" |
            Where-Object { $_ -like "LAB_RESULTS_BUCKET=*" } |
            Select-Object -First 1
        if ($environmentLine) {
            $failureBucket = $environmentLine.Substring("LAB_RESULTS_BUCKET=".Length)
            & aws s3 cp $runDirectory "s3://$failureBucket/runs/$runId/" --recursive --only-show-errors
        }
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
