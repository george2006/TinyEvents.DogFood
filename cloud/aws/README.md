# TinyEvents AWS Cloud Laboratory

This directory contains the disposable one-instance AWS laboratory described in
[`docs/aws-cloud-lab-plan.md`](../../docs/aws-cloud-lab-plan.md).

New to AWS? Start with [AWS setup: two blocks](../../docs/aws-account-setup.md):
environment credentials create the operator; Terraform creates the laboratory.
Both setup scripts preview by default and require `-Apply` plus confirmation
before changing cloud resources. Cost estimates live in the
[cost envelope](../../docs/aws-cloud-lab-costs.md).

## Current status

The repository includes infrastructure, host observability, experiment execution,
and bounded evidence uploads. Local offline tests cover the evidence lifecycle
and folder layout. The sustained-work runner also passes a short Linux/PostgreSQL
integration test with 2 and 8 workers and real runtime collectors. AWS end-to-end
validation and the 2h/24h soaks have not been performed. A short passing run is not
a validated memory test or a worker-capacity recommendation.

## Local prerequisites

- Terraform 1.6 or later;
- AWS CLI 2.32 or later;
- PowerShell 7.4 or later for the two setup entry points;
- the bootstrap-created administrator operator in a dedicated lab account.

Verify credentials before deploying:

```powershell
aws sts get-caller-identity --profile <profile>
```

## Deploy

```powershell
.\cloud\aws\Deploy-Lab.ps1 `
    -AwsProfile <profile> `
    -Region eu-west-1 `
    -Owner <name> `
    -ExpectedAccountId <12-digit-account-id> `
    -AlertEmail <email>
```

This only plans. Add `-Apply` after reviewing the plan and cost to create a fresh
plan and confirm deployment. `-OperatorLogin` prepares the refreshable operator
profile automatically; it refuses conflicting local profile configuration.
The default profile is `tinyevents-lab`. All cloud wrappers also accept
`-AwsProfile ''` for temporary environment credentials. Clear bootstrap
credentials before switching to a named profile; the scripts reject mixed modes.

Only the expected `tinyevents-lab-operator` identity may deploy. Terraform also
guards the account ID. If the regional Standard On-Demand quota is below 8 vCPU,
the script targets only the quota resource as an explicit prerequisite stage;
it does not plan or apply a VM until a later run observes AWS approval. A larger
existing quota is preserved. Terraform owns the VM role/profile and an
account-wide monthly budget with 50/80/100% alerts, defaulting to 50 USD. Budget
alerts are not a cap; the operator remains an account-wide administrator.

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
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 pwsh -NoProfile -File /repo/cloud/aws/tests/Test-AccountBootstrap.ps1
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 bash /repo/cloud/aws/tests/Test-EvidenceLifecycle.sh
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 pwsh -NoProfile -File /repo/cloud/aws/tests/Test-EvidenceLayout.ps1
```

With provider plugins already installed by `terraform init`, Terraform 1.7+
also supports the provider-mocked foundation tests (validated with 1.9.8):

```powershell
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" hashicorp/terraform:1.9.8 -chdir=/repo/cloud/aws/terraform validate
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" hashicorp/terraform:1.9.8 -chdir=/repo/cloud/aws/terraform test
```

The container needs Linux provider binaries in `.terraform/`; Windows-native
provider installations are not interchangeable. The four tests use mock AWS and
random providers, including a mock apply/teardown to resolve computed values;
they do not create AWS resources. They cover the budget, runtime profile,
evidence protection, quota precondition, account validation, and expired input.

The bootstrap suite doubles AWS and Terraform processes with fake credentials
and disposable state. It checks IAM-only bootstrap, password redaction/private
temporary input cleanup, safe retry after partial failure, identity/profile
guards, explicit plan/apply, quota-only staging, and teardown. It does not prove
real IAM authorization, browser login/MFA compatibility, Windows ACL behavior,
or quota approval. Those remain live validation items. Do not remove the MFA
guard to work around a failed preflight.

The lifecycle test doubles AWS, systemd, logging, and shutdown commands. It checks
success, failed/hung uploads, lock contention, unexpired/expired hosts, and local
write failures. These are not AWS IAM, S3, cloud-init, or real-systemd integration
tests.

### Short soak integration validation (local PostgreSQL, no AWS)

`tests/Test-CloudSoak.ps1` exercises the real publisher, worker processes, database,
and `dotnet-counters`. It requires a built Release application, PowerShell 7,
.NET 8, the counter tool, and a **disposable** PostgreSQL database whose name
starts with `TinyEventsDogfood`. The script resets that database, including a
second reset for the injected collector-failure case; never use production data.

For example, inside a local Linux SDK container with the repository mounted at
`/repo`, a writable evidence mount at `/out`, and a dedicated PostgreSQL container
reachable through `SOAK_TEST_CONNECTION`:

```powershell
dotnet tool install dotnet-counters --version 8.0.547301 --tool-path /tools
& /repo/cloud/aws/tests/Test-CloudSoak.ps1 `
    -DogfoodRoot /repo `
    -ArtifactDirectory /out/soak-validation-unique-run `
    -ConnectionString $env:SOAK_TEST_CONNECTION `
    -CounterToolPath /tools/dotnet-counters `
    -WorkerCount 8
```

Use a new artifact directory each time. The short test uses 21 seconds at 20
events/second: 420 committed business operations, 399 effects, 21 intentional
permanent failures, and three publication windows (10 + 10 + 1 seconds). It
checks persistent publisher identity, bounded windows, per-process counter CSVs,
categorized evidence, and cleanup of workers, publisher, and collectors. Negative
cases cover evidence reuse, publishing to a missing database, and an immediately
exiting collector. Expected failure logs remain under `logs/`; they are not lost
or dumped into the operator terminal. `MemoryVerdict` remains `Inconclusive`.

Local validation used SDK 8.0.424, PowerShell 7.4.18, PostgreSQL 16, and
dotnet-counters 8.0.547301. In that environment, attaching counters immediately
after creating a process could stall startup. Soak commands now emit an atomic
`*.ready.json` from managed code before the supervisor attaches collectors.
Readiness has a 30-second default deadline **per process** (`-StartupSeconds`),
and process ownership is recorded before waiting, so failed startup is cleaned up.
This readiness handshake is lab code; the TinyEvents library is unchanged. It
does not assert database health or imply that eight workers are optimal.

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
.\cloud\aws\Destroy-Lab.ps1 -AwsProfile <profile> -ExpectedAccountId <12-digit-account-id>
```

To deliberately allow Terraform to remove objects in the results bucket:

```powershell
.\cloud\aws\Destroy-Lab.ps1 `
    -AwsProfile <profile> `
    -ExpectedAccountId <12-digit-account-id> `
    -DeleteResults
```

Destruction requires confirmation and verifies credentials against the account
stored in Terraform outputs. `-WhatIf` does not destroy anything. `-DeleteResults`
first persists the bucket's `force_destroy` setting through a targeted Terraform
apply, then destroys the lab. Without it, a non-empty bucket can leave a partial
teardown; retain state and retry after handling the evidence. Expired labs remain
eligible for teardown. The bootstrap operator is outside Terraform and survives;
the lab budget and runtime IAM role/profile do not. Approved quota increases are
not revoked by destruction.

If using state from an earlier revision without account/budget outputs, review
and apply a migration plan with `Deploy-Lab.ps1` before using the new teardown
wrapper, or use the original revision's teardown. Do not delete state to bypass
the account guard. Bootstrap passwords and keys are never Terraform inputs.

## Terraform directly

The wrappers keep state in `cloud/aws/terraform/.terraform/` and
`terraform.tfstate`, both ignored by Git. A remote state backend is outside the
initial single-operator laboratory scope.
