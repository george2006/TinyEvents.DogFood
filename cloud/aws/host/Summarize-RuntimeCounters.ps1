[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$OutputPath = (Join-Path $EvidenceDirectory "runtime-summary.json"),
    [ValidateRange(1, 1440)][int]$MinimumSlopeDurationMinutes = 30,
    [ValidateRange(0, 120)][int]$WarmupMinutes = 15
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


function Get-NormalizedCounterName {
    param([string]$Name)

    return ($Name -replace "\s+\([^)]*\/\s*\d+\s+sec\)$", "").Trim()
}

$counterFiles = @(Get-ChildItem -LiteralPath $resolvedEvidenceDirectory -Recurse -Filter "*.runtime.csv")
$workerSummaries = @()
$warnings = [Collections.Generic.List[string]]::new()

foreach ($counterFile in $counterFiles) {
    $aggregates = @{}
    $rowCount = 0L
    $firstTimestamp = $null
    $lastTimestamp = $null
    # Streaming aggregates: memory is O(counter names), not O(hours * samples).
    Import-Csv -LiteralPath $counterFile.FullName | ForEach-Object {
        $timestamp = ConvertTo-CounterTimestamp $_.Timestamp
        $name = Get-NormalizedCounterName $_.'Counter Name'
        $value = ConvertTo-CounterDouble $_.'Mean/Increment'
        $rowCount++
        if ($null -eq $firstTimestamp -or $timestamp -lt $firstTimestamp) { $firstTimestamp = $timestamp }
        if ($null -eq $lastTimestamp -or $timestamp -gt $lastTimestamp) { $lastTimestamp = $timestamp }
        if (!$aggregates.ContainsKey($name)) {
            $aggregates[$name] = @{ Count = 0L; Min = $value; Max = $value; Sum = 0.0; Last = $value
                FirstTime = $timestamp; LastTime = $timestamp; Type = $_.'Counter Type'
                SlopeCount = 0L; SlopeFirst = $null; SlopeLast = $null; MeanX = 0.0; MeanY = 0.0; Sxx = 0.0; Sxy = 0.0 }
        }
        $a = $aggregates[$name]
        $a.Count++
        $a.Min = [Math]::Min($a.Min, $value)
        $a.Max = [Math]::Max($a.Max, $value)
        $a.Sum += $value
        if ($timestamp -ge $a.LastTime) { $a.LastTime = $timestamp; $a.Last = $value }
        $x = ($timestamp - $a.FirstTime).TotalHours
        if ($x -ge ($WarmupMinutes / 60.0)) {
            if ($null -eq $a.SlopeFirst) { $a.SlopeFirst = $timestamp }
            $a.SlopeLast = $timestamp
            $a.SlopeCount++
            $dx = $x - $a.MeanX
            $dy = $value - $a.MeanY
            $a.MeanX += $dx / $a.SlopeCount
            $a.MeanY += $dy / $a.SlopeCount
            $a.Sxx += $dx * ($x - $a.MeanX)
            $a.Sxy += $dx * ($value - $a.MeanY)
        }
    }
    if ($rowCount -eq 0) {
        $warnings.Add("Counter file '$($counterFile.FullName)' is empty.")
        continue
    }
    $duration = $lastTimestamp - $firstTimestamp
    $metricSummaries = [ordered]@{}
    foreach ($name in ($aggregates.Keys | Sort-Object)) {
        $a = $aggregates[$name]
        $slopeEligible = $name -in @('Working Set (MB)','GC Heap Size (MB)','GC Committed Bytes (MB)',
            'Gen 2 Size (B)','LOH Size (B)','POH (Pinned Object Heap) Size (B)','ThreadPool Thread Count') -and
            $a.SlopeCount -ge 6 -and $a.Sxx -gt 0 -and
            ($a.SlopeLast - $a.SlopeFirst).TotalMinutes -ge $MinimumSlopeDurationMinutes
        $metricSummaries[$name] = [ordered]@{
            CounterType = $a.Type; SampleCount = $a.Count; Minimum = $a.Min; Maximum = $a.Max
            Mean = $a.Sum / $a.Count; Sum = $a.Sum; Last = $a.Last
            SlopePerHour = if ($slopeEligible) { $a.Sxy / $a.Sxx } else { $null }
            SlopeEligible = $slopeEligible; PostWarmupSampleCount = $a.SlopeCount
        }
    }
    if ($duration.TotalMinutes -lt ($MinimumSlopeDurationMinutes + $WarmupMinutes)) {
        $warnings.Add("'$($counterFile.Name)' is too short for a post-warm-up memory slope.")
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
        RowCount = $rowCount
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
    WarmupMinutes = $WarmupMinutes
    CounterFileCount = $counterFiles.Count
    ParsedWorkerCount = $workerSummaries.Count
    Warnings = $warnings
    Variants = $variantSummaries
    Workers = $workerSummaries
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath
Write-Output $OutputPath
