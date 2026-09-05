# TinyEvents AWS Cloud Laboratory

This directory contains the disposable one-instance AWS laboratory described in
[`docs/aws-cloud-lab-plan.md`](../../docs/aws-cloud-lab-plan.md).

## Current status

The repository includes infrastructure, host observability, experiment execution,
and bounded evidence uploads. Local offline tests cover the evidence lifecycle
and folder layout; AWS end-to-end validation has not been performed. The new
long-running soak runner is still under local validation (its initial Linux
smoke timed out during process startup). Do not deploy a 2h/24h soak or interpret
the presence of its scenario file as a validated memory test.

## Local prerequisites

- Terraform 1.6 or later;
- AWS CLI v2;
- an AWS profile allowed to create EC2, IAM, S3, and SSM-related resources;
- PowerShell 7 recommended (Windows PowerShell 5.1 is also supported by the
  wrappers).

Verify credentials before deploying:

```powershell
aws sts get-caller-identity --profile <profile>
```

## Deploy

```powershell
.\cloud\aws\Deploy-Lab.ps1 `
    -AwsProfile <profile> `
    -Region eu-west-1 `
    -Owner <name>
```

The default instance is `m7i.2xlarge` with an encrypted 150 GB gp3 root volume.
The instance receives an expiry 30 hours after deployment unless a shorter
duration is selected. The security group has no ingress rules.

## Inspect

```powershell
.\cloud\aws\Get-LabStatus.ps1 -AwsProfile <profile>
```

The command reports EC2 state, SSM connectivity, expiry, and bootstrap status.

When bootstrap reports `host-prerequisites-ready`, stage exact clean source
commits in the private results bucket:

```powershell
.\cloud\aws\Publish-LabSources.ps1 -AwsProfile <profile>
```

The staging command refuses dirty repositories, uses `git archive`, records the
commit and SHA-256 of each archive, and does not require the candidate commits
to have been pushed to a public remote.

Initialize the staged host asynchronously:

```powershell
.\cloud\aws\Initialize-LabHost.ps1 -AwsProfile <profile>
```

The SSM command verifies both archive hashes, builds the dogfood application,
starts PostgreSQL and the bounded monitoring stack, executes a 100-message smoke
test, and uploads its evidence. Use `Get-LabStatus.ps1` until bootstrap reports
`smoke-ready`.

## Run an experiment

Scenario documents live in `cloud/aws/scenarios/`. Start one asynchronously:

```powershell
.\cloud\aws\Start-Experiment.ps1 `
    -AwsProfile <profile> `
    -Scenario worker-scaling
```

Closing the local terminal or SSM command does not stop the experiment. Query
its durable host-side status independently:

```powershell
.\cloud\aws\Get-ExperimentStatus.ps1 -AwsProfile <profile>
```

Only one experiment can hold the host lock. Complete and partial evidence is
uploaded to `runs/<run-id>/` in the private results bucket.

### Evidence organization and recovery

Run IDs include the scenario, UTC timestamp, and a random suffix. Each run is
created once, and subsequent checkpoints update that same run, not a new folder
for every upload. Layout version 2 is:

```text
runs/memory-soak-2h-20260905-080000-a1b2c3d4/
  README.md                    # where to start and how to interpret partial data
  layout.json                  # machine-readable paths / layout version
  metadata/                    # scenario.json, status.json, source-manifest.json
  workload/soak/               # publisher-windows.jsonl, result.json
  runtime/soak/                # one CSV per PID role, process-samples.jsonl
  infrastructure/              # experiment-samples.jsonl (host + PostgreSQL)
  logs/                        # sampler, publisher, workers, counter collectors
  reports/                     # derived summaries and scaling recommendation
```

Start at `README.md`, then `metadata/status.json`, then `reports/`. For failures,
inspect `logs/` and the durable workload result. Empty folders do not appear in
S3 until files are written. Legacy smoke/scaling runners keep some process
diagnostics beside their workload results; scaling repetitions are grouped under
`workload/repetition-N/`. Report readers still accept historical flat run folders.

The independent systemd checkpoint timer attempts an upload every five minutes.
It copies files already written to disk, including an active soak's runtime and
publisher journals. The legacy scaling runner's not-yet-staged evidence is saved
separately under `live/worker-scaling/` for recovery. Host status and source
provenance are under `host/`; `checkpoints/latest.json` is uploaded **last**, only
after all checkpoint transfers succeed. It is a partial-copy receipt, not a
consistent snapshot or a successful experiment verdict. Files still buffered in
a process and raw PostgreSQL/Prometheus volumes are not included.

All experiment and checkpoint uploads share a lock and have a 180-second total
budget (plus up to five seconds to force termination). AWS retries and connection
timeouts are also bounded. Sync never deletes remote evidence and does not follow
symlinks. Growing files may be retransferred, so upload CPU/network/disk overhead
is part of the same-host experiment; large logs can exhaust the upload budget.
Five minutes is the attempt interval, **not a guaranteed maximum data-loss window**.

At TTL expiry, new experiments are rejected, the checkpoint timer is stopped,
the workload is stopped with a bounded grace period, and one final checkpoint is
attempted. `host/expiry.json` identifies an expired laboratory; a remaining
`Running` status is not success. Shutdown proceeds even if S3 hangs, uploads
fail, or local evidence cannot be written. The expiry check runs every five
minutes, and stopping/uploading can add several more minutes before shutdown.
Forced stop can lose buffered diagnostics. This mechanism covers the configured
TTL, not a sudden host failure or an arbitrary external EC2 stop/termination.

Download the bucket while Terraform state still identifies it:

```powershell
.\cloud\aws\Get-Results.ps1 -AwsProfile <profile>
```

The same hierarchy is preserved under `artifacts/cloud/`. S3 objects expire after
30 days, independently of VM shutdown. Archive the release evidence locally
before then; a non-empty bucket's delete protection does not disable retention.

### Offline validation (no AWS resources)

From the repository root, with Docker available:

```powershell
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 bash /repo/cloud/aws/tests/Test-EvidenceLifecycle.sh
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 pwsh -NoProfile -File /repo/cloud/aws/tests/Test-EvidenceLayout.ps1
```

The lifecycle test doubles AWS, systemd, logging, and shutdown commands. It checks
success, failed/hung uploads, lock contention, unexpired/expired hosts, and local
write failures. These are not AWS IAM, S3, cloud-init, or real-systemd integration
tests.

Workers are sampled directly by PID. The diagnostic helper records cumulative
CPU time, working set, private and virtual memory, threads, and handles, and
attaches .NET 8 `System.Runtime` counters without modifying TinyEvents. GC dumps
are explicit and refuse capture when less than 10 GiB remains; collecting one
forces a full generation-2 GC and is therefore reserved for a suspected leak,
not routine capacity measurement.

The existing worker-scaling runner enables this collection through
`TINYEVENTS_DOGFOOD_DOTNET_COUNTERS`. Every worker writes an independent runtime
CSV and collector log beside its normal stdout/stderr evidence. Local dogfood
runs remain unchanged when the variable is absent.

`Summarize-RuntimeCounters.ps1` converts all runtime CSV files below one run
into `runtime-summary.json`. It reports per-worker min/max/mean/sum/last values,
variant memory totals, instrumentation completeness, and linear slopes for the
main memory gauges. A slope is deliberately unavailable when fewer than six
samples or less than 30 minutes of evidence exists; short runs cannot be called
memory-leak tests.

Every cloud experiment also writes `experiment-samples.jsonl` at a ten-second
interval. Each line correlates host load and memory, PostgreSQL container CPU
and memory, outbox counts and oldest-pending age, database connections and
waiters, commits/rollbacks, cache/physical reads, temporary bytes, deadlocks,
and outbox table/index allocation. Database or container observation failures
are retained as errors in the time series instead of terminating the workload
or being recorded as zero.

`Summarize-ExperimentSamples.ps1` produces `infrastructure-summary.json` with
host/container ranges, database counter deltas, cache-hit ratio, backlog and
oldest-message ranges, storage growth, observation coverage, and guarded memory
slope. It highlights pressure signals such as increasing backlog, waiting
connections, deadlocks, temporary-byte growth, or swap use. A signal identifies
correlation to investigate; it does not assign the cause to TinyEvents.

Worker-scaling runs also produce `worker-scaling-report.json`. The provisional
rule keeps the last accepted step that adds at least 15% throughput, has complete
runtime instrumentation when available, and shows neither PostgreSQL waiters
nor host swap in its timestamped window. If the largest tested count still
passes, the report says the upper boundary was not found instead of pretending
that count is optimal. TE-L02 has no end-to-end p95/p99 latency, so the report
records latency as a missing decision input rather than inventing it.

## Destroy

Download evidence before destruction. A populated results bucket is protected
by default:

```powershell
.\cloud\aws\Destroy-Lab.ps1 -AwsProfile <profile>
```

To deliberately allow Terraform to remove objects in the results bucket:

```powershell
.\cloud\aws\Destroy-Lab.ps1 `
    -AwsProfile <profile> `
    -DeleteResults
```

## Terraform directly

The wrappers keep state in `cloud/aws/terraform/.terraform/` and
`terraform.tfstate`, both ignored by Git. A remote state backend is outside the
initial single-operator laboratory scope.
