[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath = (Join-Path (Split-Path $InputPath -Parent) "infrastructure-summary.json"),
    [ValidateRange(1, 1440)][int]$MinimumSlopeDurationMinutes = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (!(Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Experiment sample file '$InputPath' was not found."
}

function Get-LinearSlopePerHour {
    param(
        [object[]]$Samples,
        [scriptblock]$ValueSelector
    )

    if ($Samples.Count -lt 2) {
        return $null
    }

    $origin = $Samples[0].Timestamp
    $points = @(
        $Samples | ForEach-Object {
            [pscustomobject]@{
                X = ($_.Timestamp - $origin).TotalHours
                Y = & $ValueSelector $_
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

function ConvertTo-ByteCount {
    param([string]$Value)

    if ($Value -notmatch "^\s*(?<number>[0-9.]+)\s*(?<unit>[KMGT]?i?B)\s*$") {
        return $null
    }

    $number = [double]::Parse(
        $Matches["number"],
        [Globalization.CultureInfo]::InvariantCulture)
    $multiplier = switch ($Matches["unit"]) {
        "B" { 1 }
        "kB" { 1000 }
        "KB" { 1000 }
        "KiB" { 1KB }
        "MB" { 1000 * 1000 }
        "MiB" { 1MB }
        "GB" { 1000 * 1000 * 1000 }
        "GiB" { 1GB }
        "TB" { 1000L * 1000 * 1000 * 1000 }
        "TiB" { 1TB }
        default { return $null }
    }

    return $number * $multiplier
}

function Get-MeasurementSummary {
    param([AllowEmptyCollection()][double[]]$Values)

    if ($Values.Count -eq 0) {
        return $null
    }

    $measurement = $Values | Measure-Object -Minimum -Maximum -Average
    return [ordered]@{
        Minimum = $measurement.Minimum
        Maximum = $measurement.Maximum
        Mean = $measurement.Average
        First = $Values[0]
        Last = $Values[-1]
        Delta = $Values[-1] - $Values[0]
    }
}

$parseErrors = [Collections.Generic.List[string]]::new()
$samples = [Collections.Generic.List[object]]::new()
$lineNumber = 0
foreach ($line in Get-Content -LiteralPath $InputPath) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    try {
        $value = $line | ConvertFrom-Json
        $samples.Add([pscustomobject]@{
            Timestamp = [DateTimeOffset]::Parse(
                $value.timestampUtc,
                [Globalization.CultureInfo]::InvariantCulture)
            Value = $value
        })
    }
    catch {
        $parseErrors.Add("Line $lineNumber`: $($_.Exception.Message)")
    }
}

if ($samples.Count -eq 0) {
    throw "Experiment sample file '$InputPath' contains no valid samples."
}

$ordered = @($samples | Sort-Object Timestamp)
$firstTimestamp = $ordered[0].Timestamp
$lastTimestamp = $ordered[-1].Timestamp
$duration = $lastTimestamp - $firstTimestamp
$databaseSamples = @($ordered | Where-Object { $null -ne $_.Value.postgresql })
$containerSamples = @($ordered | Where-Object { $null -ne $_.Value.postgresContainer })
$warnings = [Collections.Generic.List[string]]::new()
$signals = [Collections.Generic.List[string]]::new()

if ($parseErrors.Count -gt 0) {
    $warnings.Add("$($parseErrors.Count) malformed JSONL sample(s) were ignored.")
}
if ($databaseSamples.Count -lt $ordered.Count) {
    $warnings.Add("PostgreSQL was unavailable in $($ordered.Count - $databaseSamples.Count) of $($ordered.Count) samples.")
}
if ($containerSamples.Count -lt $ordered.Count) {
    $warnings.Add("PostgreSQL container metrics were unavailable in $($ordered.Count - $containerSamples.Count) of $($ordered.Count) samples.")
}

$hostUsedBytes = @($ordered | ForEach-Object { [double]$_.Value.host.memory.usedBytes })
$hostAvailableBytes = @($ordered | ForEach-Object { [double]$_.Value.host.memory.availableBytes })
$hostSwapUsedBytes = @($ordered | ForEach-Object { [double]$_.Value.host.memory.swapUsedBytes })
$loadOne = @($ordered | ForEach-Object { [double]$_.Value.host.load.oneMinute })
$slopeEligible =
    $ordered.Count -ge 6 -and
    $duration.TotalMinutes -ge $MinimumSlopeDurationMinutes
$hostUsedSlope = if ($slopeEligible) {
    Get-LinearSlopePerHour $ordered { param($sample) [double]$sample.Value.host.memory.usedBytes }
}
else {
    $null
}

if (!$slopeEligible) {
    $warnings.Add(
        "Host-memory slope unavailable: evidence spans $([Math]::Round($duration.TotalMinutes, 2)) minutes and $($ordered.Count) samples; at least $MinimumSlopeDurationMinutes minutes and six samples are required.")
}

$containerCpu = @(
    $containerSamples | ForEach-Object {
        $raw = [string]$_.Value.postgresContainer.CPUPerc
        if ($raw -match "^(?<number>[0-9.]+)%$") {
            [double]::Parse($Matches["number"], [Globalization.CultureInfo]::InvariantCulture)
        }
    })
$containerMemory = @(
    $containerSamples | ForEach-Object {
        $raw = [string]$_.Value.postgresContainer.MemUsage
        if ($raw -match "^(?<used>[^/]+)\s*/") {
            ConvertTo-ByteCount $Matches["used"].Trim()
        }
    } | Where-Object { $null -ne $_ })
$pending = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.outbox.pending })
$processing = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.outbox.processing })
$failed = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.outbox.failed })
$oldestPendingSeconds = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.outbox.oldest_pending_seconds })
$connections = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.activity.connections })
$activeConnections = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.activity.active_connections })
$waitingConnections = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.activity.waiting_connections })
$commits = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.database.xact_commit })
$rollbacks = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.database.xact_rollback })
$blocksRead = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.database.blks_read })
$blocksHit = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.database.blks_hit })
$tempBytes = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.database.temp_bytes })
$deadlocks = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.database.deadlocks })
$outboxBytes = @($databaseSamples | ForEach-Object { [double]$_.Value.postgresql.outboxTotalBytes })

$pendingSummary = Get-MeasurementSummary $pending
$waitingSummary = Get-MeasurementSummary $waitingConnections
$deadlockSummary = Get-MeasurementSummary $deadlocks
$tempSummary = Get-MeasurementSummary $tempBytes
if ($null -ne $pendingSummary -and $pendingSummary.Last -gt $pendingSummary.First) {
    $signals.Add("Pending backlog ended above its first observed value.")
}
if ($null -ne $waitingSummary -and $waitingSummary.Maximum -gt 0) {
    $signals.Add("PostgreSQL reported waiting connections.")
}
if ($null -ne $deadlockSummary -and $deadlockSummary.Delta -gt 0) {
    $signals.Add("PostgreSQL deadlock count increased.")
}
if ($null -ne $tempSummary -and $tempSummary.Delta -gt 0) {
    $signals.Add("PostgreSQL temporary-byte usage increased.")
}
if (($hostSwapUsedBytes | Measure-Object -Maximum).Maximum -gt 0) {
    $signals.Add("Host swap was used during the experiment.")
}

$readDelta = if ($blocksRead.Count -gt 0) { $blocksRead[-1] - $blocksRead[0] } else { $null }
$hitDelta = if ($blocksHit.Count -gt 0) { $blocksHit[-1] - $blocksHit[0] } else { $null }
$cacheHitRatio = if ($null -ne $readDelta -and ($readDelta + $hitDelta) -gt 0) {
    $hitDelta / ($readDelta + $hitDelta)
}
else {
    $null
}

$summary = [ordered]@{
    SchemaVersion = 1
    GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    InputPath = (Resolve-Path $InputPath).Path
    FirstTimestamp = $firstTimestamp.ToString("O")
    LastTimestamp = $lastTimestamp.ToString("O")
    DurationSeconds = $duration.TotalSeconds
    SampleCount = $ordered.Count
    DatabaseSampleCount = $databaseSamples.Count
    ContainerSampleCount = $containerSamples.Count
    ParseErrors = $parseErrors
    Warnings = $warnings
    PressureSignals = $signals
    Host = [ordered]@{
        UsedMemoryBytes = Get-MeasurementSummary $hostUsedBytes
        AvailableMemoryBytes = Get-MeasurementSummary $hostAvailableBytes
        SwapUsedBytes = Get-MeasurementSummary $hostSwapUsedBytes
        OneMinuteLoad = Get-MeasurementSummary $loadOne
        UsedMemorySlopeBytesPerHour = $hostUsedSlope
        MemorySlopeEligible = $slopeEligible
    }
    PostgreSqlContainer = [ordered]@{
        CpuPercentage = Get-MeasurementSummary $containerCpu
        UsedMemoryBytes = Get-MeasurementSummary $containerMemory
    }
    Outbox = [ordered]@{
        Pending = $pendingSummary
        Processing = Get-MeasurementSummary $processing
        Failed = Get-MeasurementSummary $failed
        OldestPendingSeconds = Get-MeasurementSummary $oldestPendingSeconds
        TotalAllocatedBytes = Get-MeasurementSummary $outboxBytes
    }
    PostgreSql = [ordered]@{
        Connections = Get-MeasurementSummary $connections
        ActiveConnections = Get-MeasurementSummary $activeConnections
        WaitingConnections = $waitingSummary
        CommitDelta = if ($commits.Count -gt 0) { $commits[-1] - $commits[0] } else { $null }
        RollbackDelta = if ($rollbacks.Count -gt 0) { $rollbacks[-1] - $rollbacks[0] } else { $null }
        BlocksReadDelta = $readDelta
        BlocksHitDelta = $hitDelta
        CacheHitRatio = $cacheHitRatio
        TemporaryBytesDelta = if ($tempBytes.Count -gt 0) { $tempBytes[-1] - $tempBytes[0] } else { $null }
        DeadlockDelta = if ($deadlocks.Count -gt 0) { $deadlocks[-1] - $deadlocks[0] } else { $null }
    }
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath
Write-Output $OutputPath
