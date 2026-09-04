[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$OutputPath = (Join-Path $EvidenceDirectory "runtime-summary.json"),
    [ValidateRange(1, 1440)][int]$MinimumSlopeDurationMinutes = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (!(Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
    throw "Evidence directory '$EvidenceDirectory' was not found."
}
$resolvedEvidenceDirectory = (Resolve-Path $EvidenceDirectory).Path

function ConvertTo-CounterDouble {
    param([string]$Value)

    $number = 0.0
    if ([double]::TryParse(
            $Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number)) {
        return $number
    }

    if ([double]::TryParse($Value, [ref]$number)) {
        return $number
    }

    throw "Counter value '$Value' is not numeric."
}

function ConvertTo-CounterTimestamp {
    param([string]$Value)

    $timestamp = [DateTime]::MinValue
    if ([DateTime]::TryParse($Value, [ref]$timestamp)) {
        return $timestamp
    }

    if ([DateTime]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$timestamp)) {
        return $timestamp
    }

    throw "Counter timestamp '$Value' is invalid."
}

function Get-LinearSlopePerHour {
    param([object[]]$Samples)

    if ($Samples.Count -lt 2) {
        return $null
    }

    $origin = $Samples[0].Timestamp
    $points = @(
        $Samples | ForEach-Object {
            [pscustomobject]@{
                X = ($_.Timestamp - $origin).TotalHours
                Y = $_.Value
            }
        })
    $xMean = ($points | Measure-Object X -Average).Average
    $yMean = ($points | Measure-Object Y -Average).Average
    $numerator = 0.0
    $denominator = 0.0

    foreach ($point in $points) {
        $xDelta = $point.X - $xMean
        $numerator += $xDelta * ($point.Y - $yMean)
        $denominator += $xDelta * $xDelta
    }

    if ($denominator -eq 0) {
        return $null
    }

    return $numerator / $denominator
}

function Get-NormalizedCounterName {
    param([string]$Name)

    return ($Name -replace "\s+\([^)]*\/\s*\d+\s+sec\)$", "").Trim()
}

$counterFiles = @(Get-ChildItem -LiteralPath $resolvedEvidenceDirectory -Recurse -Filter "*.runtime.csv")
$workerSummaries = @()
$warnings = [Collections.Generic.List[string]]::new()

foreach ($counterFile in $counterFiles) {
    $rows = @(Import-Csv -LiteralPath $counterFile.FullName)
    if ($rows.Count -eq 0) {
        $warnings.Add("Counter file '$($counterFile.FullName)' is empty.")
        continue
    }

    $samples = @(
        foreach ($row in $rows) {
            [pscustomobject]@{
                Timestamp = ConvertTo-CounterTimestamp $row.Timestamp
                CounterName = Get-NormalizedCounterName $row.'Counter Name'
                CounterType = $row.'Counter Type'
                Value = ConvertTo-CounterDouble $row.'Mean/Increment'
            }
        })
    $firstTimestamp = ($samples | Measure-Object Timestamp -Minimum).Minimum
    $lastTimestamp = ($samples | Measure-Object Timestamp -Maximum).Maximum
    $duration = $lastTimestamp - $firstTimestamp
    $metricSummaries = [ordered]@{}

    foreach ($group in ($samples | Group-Object CounterName)) {
        $orderedSamples = @($group.Group | Sort-Object Timestamp)
        $values = @($orderedSamples | Select-Object -ExpandProperty Value)
        $measurement = $values | Measure-Object -Minimum -Maximum -Average -Sum
        $slopeEligible =
            $group.Name -in @(
                "Working Set (MB)",
                "GC Heap Size (MB)",
                "GC Committed Bytes (MB)",
                "Gen 2 Size (B)",
                "LOH Size (B)",
                "POH (Pinned Object Heap) Size (B)",
                "ThreadPool Thread Count") -and
            $orderedSamples.Count -ge 6 -and
            $duration.TotalMinutes -ge $MinimumSlopeDurationMinutes
        $metricSummaries[$group.Name] = [ordered]@{
            CounterType = $orderedSamples[0].CounterType
            SampleCount = $orderedSamples.Count
            Minimum = $measurement.Minimum
            Maximum = $measurement.Maximum
            Mean = $measurement.Average
            Sum = $measurement.Sum
            Last = $orderedSamples[-1].Value
            SlopePerHour = if ($slopeEligible) {
                Get-LinearSlopePerHour $orderedSamples
            }
            else {
                $null
            }
            SlopeEligible = $slopeEligible
        }
    }

    if ($duration.TotalMinutes -lt $MinimumSlopeDurationMinutes) {
        $warnings.Add(
            "'$($counterFile.Name)' spans $([Math]::Round($duration.TotalMinutes, 2)) minutes; memory slope requires at least $MinimumSlopeDurationMinutes minutes.")
    }

    $variantMatch = [regex]::Match(
        $counterFile.DirectoryName,
        "(?<count>\d+)-workers(?:[\\/]|$)")
    $workerSummaries += [ordered]@{
        File = $counterFile.FullName.Substring($resolvedEvidenceDirectory.Length).TrimStart('\', '/')
        Worker = $counterFile.BaseName -replace "\.runtime$", ""
        WorkerCountVariant = if ($variantMatch.Success) {
            [int]($variantMatch.Groups["count"].Value)
        }
        else {
            $null
        }
        FirstTimestamp = $firstTimestamp.ToString("O")
        LastTimestamp = $lastTimestamp.ToString("O")
        DurationSeconds = $duration.TotalSeconds
        RowCount = $rows.Count
        Metrics = $metricSummaries
    }
}

$variantSummaries = @(
    $workerSummaries |
        Where-Object { $null -ne $_.WorkerCountVariant } |
        Group-Object WorkerCountVariant |
        Sort-Object { [int]$_.Name } |
        ForEach-Object {
            $variantGroup = $_
            $workers = @($variantGroup.Group)
            $variantWorkerCount = [int]($workers[0].WorkerCountVariant)
            $cpuMeans = @(
                $workers |
                    ForEach-Object {
                        $metric = $_.Metrics["CPU Usage (%)"]
                        if ($null -ne $metric) { $metric.Mean }
                    } |
                    Where-Object { $null -ne $_ })
            $workingSetMaxima = @(
                $workers |
                    ForEach-Object {
                        $metric = $_.Metrics["Working Set (MB)"]
                        if ($null -ne $metric) { $metric.Maximum }
                    } |
                    Where-Object { $null -ne $_ })
            $heapMaxima = @(
                $workers |
                    ForEach-Object {
                        $metric = $_.Metrics["GC Heap Size (MB)"]
                        if ($null -ne $metric) { $metric.Maximum }
                    } |
                    Where-Object { $null -ne $_ })

            [ordered]@{
                WorkerCount = $variantWorkerCount
                InstrumentedWorkers = $workers.Count
                InferredRepetitionCount = if (
                    $variantWorkerCount -gt 0 -and
                    $workers.Count % $variantWorkerCount -eq 0) {
                    $workers.Count / $variantWorkerCount
                }
                else {
                    $null
                }
                MeanCpuPercentageSum = ($cpuMeans | Measure-Object -Sum).Sum
                MaximumWorkerWorkingSetMB = ($workingSetMaxima | Measure-Object -Maximum).Maximum
                SumWorkerWorkingSetMaximaMB = ($workingSetMaxima | Measure-Object -Sum).Sum
                MaximumWorkerGcHeapMB = ($heapMaxima | Measure-Object -Maximum).Maximum
                SumWorkerGcHeapMaximaMB = ($heapMaxima | Measure-Object -Sum).Sum
                CompleteInstrumentation =
                    $variantWorkerCount -gt 0 -and
                    $workers.Count % $variantWorkerCount -eq 0
            }
        })

$summary = [ordered]@{
    SchemaVersion = 1
    GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    EvidenceDirectory = $resolvedEvidenceDirectory
    MinimumSlopeDurationMinutes = $MinimumSlopeDurationMinutes
    CounterFileCount = $counterFiles.Count
    ParsedWorkerCount = $workerSummaries.Count
    Warnings = $warnings
    Variants = $variantSummaries
    Workers = $workerSummaries
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath
Write-Output $OutputPath
