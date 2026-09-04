[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$OutputPath = (Join-Path $EvidenceDirectory "worker-scaling-report.json"),
    [ValidateRange(1, 100)][double]$MinimumIncrementalGainPercentage = 15
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (!(Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
    throw "Evidence directory '$EvidenceDirectory' was not found."
}

$resultFiles = @(
    Get-ChildItem -LiteralPath $EvidenceDirectory -Recurse -Filter "result.json" |
        Where-Object { $_.Directory.Name -eq "TE-L02" })
if ($resultFiles.Count -eq 0) {
    throw "No TE-L02 result files were found below '$EvidenceDirectory'."
}

$warnings = [Collections.Generic.List[string]]::new()
$allVariants = @(
    foreach ($resultFile in $resultFiles) {
        $result = Get-Content -LiteralPath $resultFile.FullName -Raw | ConvertFrom-Json
        foreach ($variant in $result.Variants) {
            $startedAtProperty = $variant.PSObject.Properties["StartedAtUtc"]
            $completedAtProperty = $variant.PSObject.Properties["CompletedAtUtc"]
            [pscustomobject]@{
                Source = $resultFile.FullName
                WorkerCount = [int]$variant.WorkerCount
                Throughput = [double]$variant.DrainMessagesPerSecond
                ScalingEfficiency = [double]$variant.ScalingEfficiencyPercentage
                AcceptancePassed = [bool]$variant.AcceptancePassed
                StartedAtUtc = if ($null -ne $startedAtProperty) {
                    [DateTimeOffset]::Parse([string]$startedAtProperty.Value)
                }
                else { $null }
                CompletedAtUtc = if ($null -ne $completedAtProperty) {
                    [DateTimeOffset]::Parse([string]$completedAtProperty.Value)
                }
                else { $null }
            }
        }
    })

if (@($allVariants | Where-Object { $null -eq $_.StartedAtUtc }).Count -gt 0) {
    $warnings.Add(
        "Some TE-L02 evidence predates variant timestamps; infrastructure pressure cannot be assigned to those variants.")
}

$samplePath = Join-Path $EvidenceDirectory "experiment-samples.jsonl"
$samples = @()
if (Test-Path -LiteralPath $samplePath) {
    $samples = @(
        Get-Content -LiteralPath $samplePath |
            Where-Object { ![string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                $value = $_ | ConvertFrom-Json
                [pscustomobject]@{
                    Timestamp = [DateTimeOffset]::Parse($value.timestampUtc)
                    Value = $value
                }
            })
}
else {
    $warnings.Add("No experiment-samples.jsonl was found; recommendations have no infrastructure-pressure veto.")
}

$runtimeSummaryPath = Join-Path $EvidenceDirectory "runtime-summary.json"
$runtimeSummary = if (Test-Path -LiteralPath $runtimeSummaryPath) {
    Get-Content -LiteralPath $runtimeSummaryPath -Raw | ConvertFrom-Json
}
else {
    $null
}
if ($null -eq $runtimeSummary) {
    $warnings.Add("No runtime-summary.json was found; recommendations have no runtime-instrumentation completeness check.")
}

$variants = @()
$previousThroughput = $null
foreach ($group in ($allVariants | Group-Object WorkerCount | Sort-Object { [int]$_.Name })) {
    $workerCount = [int]($group.Name)
    $runs = @($group.Group)
    $throughput = @($runs | Select-Object -ExpandProperty Throughput)
    $throughputMeasurement = $throughput | Measure-Object -Minimum -Maximum -Average
    $efficiencyMeasurement =
        @($runs | Select-Object -ExpandProperty ScalingEfficiency) |
        Measure-Object -Minimum -Maximum -Average
    $incrementalGain = if ($null -ne $previousThroughput) {
        100 * ($throughputMeasurement.Average - $previousThroughput) / $previousThroughput
    }
    else {
        $null
    }

    $windowSamples = @(
        foreach ($run in $runs) {
            if ($null -ne $run.StartedAtUtc -and $null -ne $run.CompletedAtUtc) {
                $samples | Where-Object {
                    $_.Timestamp -ge $run.StartedAtUtc -and
                    $_.Timestamp -le $run.CompletedAtUtc
                }
            }
        })
    $databaseWindow = @($windowSamples | Where-Object { $null -ne $_.Value.postgresql })
    $maximumWaitingConnections = if ($databaseWindow.Count -gt 0) {
        ($databaseWindow |
            ForEach-Object { [double]$_.Value.postgresql.activity.waiting_connections } |
            Measure-Object -Maximum).Maximum
    }
    else { $null }
    $maximumOldestPendingSeconds = if ($databaseWindow.Count -gt 0) {
        ($databaseWindow |
            ForEach-Object { [double]$_.Value.postgresql.outbox.oldest_pending_seconds } |
            Measure-Object -Maximum).Maximum
    }
    else { $null }
    $maximumHostSwapBytes = if ($windowSamples.Count -gt 0) {
        ($windowSamples |
            ForEach-Object { [double]$_.Value.host.memory.swapUsedBytes } |
            Measure-Object -Maximum).Maximum
    }
    else { $null }

    $runtimeVariant = if ($null -ne $runtimeSummary) {
        $runtimeSummary.Variants |
            Where-Object { $_.WorkerCount -eq $workerCount } |
            Select-Object -First 1
    }
    else { $null }
    $runtimeComplete =
        $null -eq $runtimeSummary -or
        ($null -ne $runtimeVariant -and $runtimeVariant.CompleteInstrumentation)
    $pressureVeto =
        ($null -ne $maximumWaitingConnections -and $maximumWaitingConnections -gt 0) -or
        ($null -ne $maximumHostSwapBytes -and $maximumHostSwapBytes -gt 0)
    $gainPasses =
        $null -eq $incrementalGain -or
        $incrementalGain -ge $MinimumIncrementalGainPercentage
    $useful =
        ($runs.AcceptancePassed -notcontains $false) -and
        $gainPasses -and
        !$pressureVeto -and
        $runtimeComplete

    $variants += [pscustomobject][ordered]@{
        WorkerCount = $workerCount
        Repetitions = $runs.Count
        AllAcceptancePassed = $runs.AcceptancePassed -notcontains $false
        ThroughputMessagesPerSecond = [ordered]@{
            Minimum = $throughputMeasurement.Minimum
            Maximum = $throughputMeasurement.Maximum
            Mean = $throughputMeasurement.Average
        }
        ScalingEfficiencyPercentage = [ordered]@{
            Minimum = $efficiencyMeasurement.Minimum
            Maximum = $efficiencyMeasurement.Maximum
            Mean = $efficiencyMeasurement.Average
        }
        IncrementalThroughputGainPercentage = $incrementalGain
        InstrumentationComplete = $runtimeComplete
        InfrastructureWindowSampleCount = $windowSamples.Count
        MaximumWaitingConnections = $maximumWaitingConnections
        MaximumOldestPendingSeconds = $maximumOldestPendingSeconds
        MaximumHostSwapBytes = $maximumHostSwapBytes
        PressureVeto = $pressureVeto
        MeetsUsefulStepRule = $useful
    }
    $previousThroughput = $throughputMeasurement.Average
}

$lastUsefulWorkerCount = $null
$boundaryReason = $null
foreach ($variant in $variants) {
    if ($variant.MeetsUsefulStepRule) {
        $lastUsefulWorkerCount = $variant.WorkerCount
        continue
    }

    $boundaryReason = if (!$variant.AllAcceptancePassed) {
        "Durable acceptance failed."
    }
    elseif (!$variant.InstrumentationComplete) {
        "Runtime instrumentation was incomplete."
    }
    elseif ($variant.PressureVeto) {
        "Infrastructure pressure vetoed the step."
    }
    else {
        "Incremental throughput gain was below $MinimumIncrementalGainPercentage percent."
    }
    break
}

$largestWorkerCount = ($variants | Measure-Object WorkerCount -Maximum).Maximum
$upperBoundNotFound =
    $null -ne $lastUsefulWorkerCount -and
    $lastUsefulWorkerCount -eq $largestWorkerCount
if ($upperBoundNotFound) {
    $warnings.Add(
        "The largest tested worker count still met the useful-step rule; this run did not locate the upper boundary.")
}
$warnings.Add(
    "TE-L02 measures backlog-drain throughput, not end-to-end p95/p99 event latency; latency remains a separate decision input.")

$report = [ordered]@{
    SchemaVersion = 1
    GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    EvidenceDirectory = (Resolve-Path $EvidenceDirectory).Path
    DecisionRule = [ordered]@{
        MinimumIncrementalThroughputGainPercentage = $MinimumIncrementalGainPercentage
        RequiresDurableAcceptance = $true
        VetoesWaitingConnections = $true
        VetoesHostSwap = $true
        RequiresCompleteRuntimeInstrumentationWhenAvailable = $true
        IncludesEndToEndLatency = $false
    }
    LastUsefulWorkerCount = $lastUsefulWorkerCount
    CapacityBoundaryObserved = !$upperBoundNotFound -and $null -ne $boundaryReason
    BoundaryReason = $boundaryReason
    UpperBoundNotFound = $upperBoundNotFound
    Warnings = $warnings
    Variants = $variants
}

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath
Write-Output $OutputPath
