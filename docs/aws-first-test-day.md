# First AWS Test Day

Objective: validate the laboratory in a real account, then start the two-hour
instrumentation rehearsal. This is not a V1 release gate or a claim that the
24-hour soak has passed. No AWS resources were created during local preparation.

## Before spending anything

1. Follow [AWS setup: two blocks](aws-account-setup.md). Keep credentials in
   environment variables or the local browser-login profile, never in chat,
   source control, Terraform variables, or screenshots.
2. Use PowerShell 7.4+, Terraform 1.7+ for the offline mock tests (1.6+ for
   deployment), AWS CLI 2.32+, and the dedicated account's MFA-enabled operator.
3. Commit the selected TinyEvents and TinyEvents.Dogfood revisions. Source
   staging deliberately refuses dirty repositories; pushing or opening a PR
   is not required. Keep the repositories as siblings.
4. Run the [offline checks](../cloud/aws/README.md#offline-validation-no-aws-resources).
   Docker tests use cached images/providers, a read-only source mount and
   `--network none`; they do not receive AWS credentials.
5. Agree the spending envelope and alert recipient. The
   [cost estimate](aws-cloud-lab-costs.md) is not a spending cap. Account setup,
   MFA, regional quota approval and actual service authorization remain live
   prerequisites; AWS quota approval can delay the first VM.

## Gate 1: deploy, inspect, and smoke

Use the second setup script, with preview before apply:

```powershell
$lab = @{
    ExpectedAccountId = '<12-digit-account-id>'
    Owner = '<name>'
    AlertEmail = '<email>'
    Region = 'eu-west-1'
    LifetimeHours = 6
}
.\cloud\aws\Deploy-Lab.ps1 @lab -OperatorLogin
# Review the plan. The next command creates chargeable resources after confirmation.
.\cloud\aws\Deploy-Lab.ps1 @lab -Apply
.\cloud\aws\Get-LabStatus.ps1
```

Start with six hours, not a 24-hour unattended test. A quota-only plan is not a
deployed laboratory. Do not continue until the full apply succeeds, SSM is Online,
`ExpiryWatchdog.ConfigurationVerified` is true, and bootstrap reports
`host-prerequisites-ready`. Then:

```powershell
.\cloud\aws\Publish-LabSources.ps1
.\cloud\aws\Initialize-LabHost.ps1
.\cloud\aws\Get-LabStatus.ps1
```

Initialization is asynchronous. Continue only after `smoke-ready`. On any
failure, inspect the status and logs; do not stack repeated initializations or
discard Terraform state. Save `terraform.tfstate` and `.lab-context.json` together
privately; [partial-deployment recovery](../cloud/aws/README.md#destroy) also works
when final outputs are missing.

## Gate 2: prove evidence recovery before a long run

```powershell
.\cloud\aws\Start-Experiment.ps1 -Scenario cloud-smoke
.\cloud\aws\Get-ExperimentStatus.ps1
.\cloud\aws\Get-Results.ps1 -OutputDirectory .\artifacts\cloud\first-aws-day
```

Require a successful workload and successful upload. Open the downloaded run's
`README.md`, `metadata/status.json`, workload result and logs. Check that the
source manifest identifies the intended two commits. Older bootstrap smoke
evidence has a legacy layout; the scheduled experiment has categorized folders.
An SSM command ID means submitted, not passed. A checkpoint receipt means copied,
not a consistent snapshot or a completed test.

## Gate 3: start the two-hour rehearsal

```powershell
.\cloud\aws\Start-Experiment.ps1 -Scenario memory-soak-2h
.\cloud\aws\Get-ExperimentStatus.ps1
.\cloud\aws\Get-Results.ps1 -OutputDirectory .\artifacts\cloud\first-aws-day
```

Close and reopen the operator terminal to confirm that the workload is independent
of it. After at least one five-minute checkpoint attempt, download again and
verify that the same run folder has growing publisher/runtime/infrastructure
evidence. No new folder should be created for each checkpoint.

Stop and investigate if workers/collectors die, disk approaches exhaustion,
uploads repeatedly fail, or observations are missing. Do not interpret missing
metrics as zero. At completion require exact durable accounting, per-PID runtime
CSVs, infrastructure samples, and retained logs. `MemoryVerdict: Inconclusive`
is expected: growth needs analysis after warm-up, not an automatic leak claim.

The scenario validator rejects unknown fields, invalid work mixes and worker
matrices. Admission requires the scenario's maximum duration plus five minutes
before expiry, and verifies the deployed stop schedule before S3/SSM writes.
The host checks TTL again; systemd enforces the declared maximum runtime. A
forced timeout may leave `Running` evidence: that is incomplete, never success.

## Gate 4: validate both expiry paths, then destroy

Retain evidence before deliberately testing shutdown. The host timer should
stop work, attempt a bounded final upload, write `host/expiry.json`, and shut down.
The AWS watchdog independently starts ten minutes after TTL and repeats every
five minutes, targeting only this instance. It can force a stop after a failed
graceful shutdown; unsaved data may be lost. It is not an exact-time guarantee or
a hard cost cap. EBS/S3 storage continues to incur charges after EC2 stops.

Seeing an enabled schedule is **configuration evidence only**. To validate the
independent path, use a separate, explicitly authorized short-lived lab with no
active workload: disable only its host expiry timer and verify that AWS stops it
after TTL plus the grace period. Do not disable the timer in the active soak lab.
If it remains running, manually stop the exact lab instance through EC2 and
investigate Scheduler/IAM before any unattended 24-hour run.

```powershell
.\cloud\aws\Get-Results.ps1 -OutputDirectory .\artifacts\cloud\first-aws-day
.\cloud\aws\Destroy-Lab.ps1 -ExpectedAccountId '<12-digit-account-id>' -WhatIf
# After verifying the downloaded evidence, explicitly authorize bucket deletion:
.\cloud\aws\Destroy-Lab.ps1 -ExpectedAccountId '<12-digit-account-id>' -DeleteResults
```

The last command permanently deletes cloud evidence and the lab, after
confirmation. The downloaded copy is retained. Without `-DeleteResults`, a
non-empty bucket intentionally prevents complete teardown. Check Terraform's
result and the AWS console for leftover resources; do not infer successful
cleanup from a stopped VM. The bootstrap operator and approved quota survive.

An interrupted apply can leave a VM before its Scheduler target is created.
That is a failed deployment, not a protected lab: recover/stop/destroy it promptly.
Do not start experiments or leave it unattended.

## Next sessions, not claims of completed evidence

- A fresh 30-hour lab for `memory-soak-24h`, only after the rehearsal and live
  shutdown/recovery checks pass. Never extend an active experiment by rerunning
  deployment: changing user data can replace the instance.
- Repeated `worker-scaling` measurements, with database pressure and runtime
  evidence. Eight workers is a hypothesis, not a measured limit.
- The [complete bench campaign](aws-bench-campaign.md) now prepares batch scaling,
  per-kind processing-latency proxies, overload/recovery, monitoring comparisons,
  the dashboard and bounded automatic diagnostics. Its short local tests are
  preparation evidence; full-duration cloud execution is still outstanding.
- Analyze retained evidence and publish recommended defaults only after those
  decision inputs exist. See the [roadmap](roadmap.md#active-v1-operational-evidence---aws-laboratory).
