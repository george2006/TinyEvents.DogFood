Set-StrictMode -Version Latest

function New-MemoryDiagnosticState {
    return @{ Processes = @{}; Attempted = $false }
}

function Test-MemoryDiagnosticTrigger {
    param($State, $Sample, [int]$WarmupSeconds = 900, [long]$GrowthBytes = 268435456,
        [int]$RequiredSamples = 5, [int]$IntervalSeconds = 60)
    if ($State.Attempted -or $Sample.HasExited) { return $false }
    $key = [string]$Sample.ProcessId
    $now = [DateTimeOffset]$Sample.TimestampUtc
    if (!$State.Processes.ContainsKey($key)) {
        $State.Processes[$key] = @{ Started = $now; Last = $now; Baseline = $null; Count = 0 }
        return $false
    }
    $process = $State.Processes[$key]
    if (($now - $process.Started).TotalSeconds -lt $WarmupSeconds -or
        ($now - $process.Last).TotalSeconds -lt $IntervalSeconds) { return $false }
    $process.Last = $now
    if ($null -eq $process.Baseline) { $process.Baseline = [long]$Sample.WorkingSetBytes; return $false }
    if ($Sample.WorkingSetBytes -ge ($process.Baseline + $GrowthBytes) -and
        $Sample.WorkingSetBytes -ge (1.5 * $process.Baseline)) { $process.Count++ } else { $process.Count = 0 }
    if ($process.Count -lt $RequiredSamples) { return $false }
    $State.Attempted = $true # At most one attempt across all PIDs, including failed captures.
    return $true
}
