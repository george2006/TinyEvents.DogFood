Set-StrictMode -Version Latest

function New-ExperimentEvidenceLayout {
    param([Parameter(Mandatory)][string]$RunDirectory)

    if (Test-Path -LiteralPath $RunDirectory) {
        throw "Evidence directory already exists: $RunDirectory"
    }
    $layout = [ordered]@{ Root = $RunDirectory }
    foreach ($name in @('metadata', 'workload', 'runtime', 'infrastructure', 'logs', 'reports')) {
        $path = Join-Path $RunDirectory $name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $layout[$name] = $path
    }
    [ordered]@{
        SchemaVersion = 2
        Status = 'metadata/status.json'
        Scenario = 'metadata/scenario.json'
        Workload = 'workload/'
        RuntimeCounters = 'runtime/'
        InfrastructureSamples = 'infrastructure/experiment-samples.jsonl'
        Logs = 'logs/'
        Reports = 'reports/'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDirectory 'layout.json')
    @'
# Experiment evidence

Start with [metadata/status.json](metadata/status.json). `Running`, `Uploading`,
or `Failed` is not a completed successful experiment. Missing files/reports in
a checkpoint are expected. A `Succeeded` experiment is not proof of no leak.

| Folder | Contents |
| --- | --- |
| `metadata/` | Exact scenario, status, source manifest when available |
| `workload/` | Publisher windows, durable reconciliation, per-repetition results |
| `runtime/` | Per-process .NET counters and process resource samples |
| `infrastructure/` | Timestamped host, PostgreSQL, and container samples |
| `logs/` | Publisher, worker, collector, and sampler diagnostics |
| `reports/` | Derived runtime, infrastructure, and worker-scaling summaries |

Legacy smoke/scaling runners may keep process logs/counters beside their workload
result inside `workload/`. Summarizers search recursively; nothing is discarded.
See `layout.json` for machine-readable entry points (layout version 2).

Periodic uploads update this same run directory; they are partial, not snapshots.
At bucket level, `host/expiry.json` records TTL shutdown, `checkpoints/latest.json`
records the last successful checkpoint, and `live/worker-scaling/` contains
recovery files from legacy repetitions not yet staged into a run.
'@ | Set-Content -LiteralPath (Join-Path $RunDirectory 'README.md')
    return [pscustomobject]$layout
}
