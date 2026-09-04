# TinyEvents AWS Cloud Laboratory

This directory contains the disposable one-instance AWS laboratory described in
[`docs/aws-cloud-lab-plan.md`](../../docs/aws-cloud-lab-plan.md).

## Current status

The Terraform foundation and local lifecycle wrappers are the first delivery
slice. Host observability and experiment execution are intentionally added in
later slices. Do not interpret a successful infrastructure deployment as a
completed load or memory test.

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
