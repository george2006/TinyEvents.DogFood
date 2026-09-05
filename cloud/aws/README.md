# Run TinyEvents Tests on AWS

This is the only AWS user guide. Follow it in order; no separate architecture,
setup or first-day documents are required. Local preparation has passed, but
**the first real AWS deployment and full-duration campaign are still unvalidated**.

Two scripts prepare the infrastructure: `Bootstrap-Account.ps1` creates the
operator; `Deploy-Lab.ps1` lets Terraform create the lab. The later commands run
tests, collect results and remove the lab. Deployment alone does not run tests.

## Before you start

Use a dedicated AWS account with payment details and root MFA. The operator will
have account-wide administrator permissions, not sandbox permissions. Install
PowerShell 7.4+, AWS CLI 2.32+, Terraform 1.6+ and Git. Keep TinyEvents and
TinyEvents.Dogfood as sibling repositories with clean, committed source. Run the
commands below from the TinyEvents.Dogfood repository root in PowerShell 7.

The default VM is one Linux `m7i.2xlarge` (8 vCPU, 32 GiB), with a 150-GiB gp3
disk and a private S3 results bucket. Check current
[EC2](https://aws.amazon.com/ec2/pricing/on-demand/),
[EBS](https://aws.amazon.com/ebs/pricing/),
[IPv4](https://aws.amazon.com/vpc/pricing/) and
[S3](https://aws.amazon.com/s3/pricing/) prices before applying.
Terraform shows resources, not their price. Budget alerts default to 50 USD/month
at 50/80/100%; **alerts and expiry are not a spending cap**. Stopped disks and
retained results remain billable.

## 1. Create the operator once

Inject temporary privileged credentials into `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` in your local process.
Never put credentials in chat, files, Terraform variables or command arguments.
Do not create permanent root access keys. If needed, use the optional browser
helper at the end of this page before this step.

```powershell
$accountId = '123456789012' # Replace with your dedicated account ID.
.\cloud\aws\Bootstrap-Account.ps1 -ExpectedAccountId $accountId -AllowRootBootstrap
# Review the preview, then explicitly create the operator:
.\cloud\aws\Bootstrap-Account.ps1 -ExpectedAccountId $accountId -AllowRootBootstrap -Apply
```

Omit `-AllowRootBootstrap` for a non-root administrator. Store the securely
prompted operator password in your password manager. Open the console URL printed
by the script, sign in as `tinyevents-lab-operator`, change its password, and
enroll MFA with device name `tinyevents-lab-operator`. Sign out and back in with MFA.
These personal authentication steps remain manual.

Clear privileged bootstrap credentials, including after a failure:

```powershell
$env:AWS_ACCESS_KEY_ID = $null
$env:AWS_SECRET_ACCESS_KEY = $null
$env:AWS_SESSION_TOKEN = $null
# Only if you used the optional browser helper:
aws logout --profile tinyevents-bootstrap
```

## 2. Create one lab with Terraform

```powershell
$lab = @{
    ExpectedAccountId = $accountId
    Owner = 'your-name'
    AlertEmail = 'you@example.com'
    Region = 'eu-west-1'
    LifetimeHours = 6
}
.\cloud\aws\Deploy-Lab.ps1 @lab -OperatorLogin
# Review the plan and costs. The following command creates resources after confirmation:
.\cloud\aws\Deploy-Lab.ps1 @lab -Apply
.\cloud\aws\Get-LabStatus.ps1
```

Choose the operator, not root, in the login browser. If the regional quota is
below eight vCPUs, the script submits only a quota request: wait for AWS approval,
then rerun this step. Do not bypass MFA or identity checks.

Continue only after full deployment succeeds, SSM is `Online`,
`ExpiryWatchdog.ConfigurationVerified` is true, and bootstrap says
`host-prerequisites-ready`. A failed partial deployment may have a VM without
its stop schedule: stop/recover/destroy it promptly, never leave it unattended.

The first session is supervised and limited to six hours from planning time.
For a later 24-hour soak, create a fresh lab with `LifetimeHours = 30`.
Never redeploy to extend an active experiment: changed user data can replace
its VM. Keep private `terraform.tfstate` and `.lab-context.json` until cleanup ends.

## 3. Load the application and wait for smoke

```powershell
.\cloud\aws\Publish-LabSources.ps1
.\cloud\aws\Initialize-LabHost.ps1
.\cloud\aws\Get-LabStatus.ps1
```

Source staging uses exact clean commits. Initialization builds the application,
starts PostgreSQL and monitoring, resets the disposable database, runs a
100-message smoke test and uploads evidence. Repeat only the status command until
`smoke-ready`. Do not repeat initialization during an experiment or while another
initialization is running. A submitted SSM command is not a passed test.

## 4. Run a test and retrieve results

First validate scheduled execution and evidence recovery:

```powershell
.\cloud\aws\Start-Experiment.ps1 -Scenario cloud-smoke
.\cloud\aws\Get-ExperimentStatus.ps1
```

Repeat the status command until this run is terminal. Require `Succeeded`, then:

```powershell
.\cloud\aws\Get-Results.ps1 -OutputDirectory .\artifacts\cloud\first-session
```

Open the downloaded run under `runs/<run-id>/`: its `README.md`,
`metadata/status.json`, source manifest and workload result. Check the intended
source commits and successful workload/upload before continuing.

Use the same start/status/download sequence with `memory-soak-2h`. Close and
reopen your local terminal to verify the workload continues independently.
After a checkpoint attempt, download again: the same run folder should contain
growing evidence. Only one experiment can run at a time. Each variant resets
the disposable database; never target production data.

### Available tests

| Scenario | What it measures |
| --- | --- |
| `cloud-smoke` | 100 successful events and evidence collection |
| `memory-soak-2h` | Two-hour mixed-workload instrumentation rehearsal |
| `worker-batch-matrix` | Three repetitions of workers 1/2/4/8/12/16/24 at batch 50, backlog 100,000; batches 1/10/25/50/100 at four workers, backlog 20,000 |
| `monitoring-overhead` | Three alternating full/minimal monitoring pairs |
| `mixed-pressure` | Overload/recovery, then payload and cleanup comparisons |
| `memory-diagnostics-24h` | Steady mixed load for 24 hours with bounded automatic GC-dump diagnostics |

Run the full campaign only after the rehearsal and live safety checks below.
Use sequential labs as needed, not parallel VMs. The complete campaign does not
fit a single 30-hour lease. Admission requires each scenario's conservative
maximum duration plus five minutes to fit the remaining TTL; that budget is not
a predicted runtime. Use a fresh lease for the 24-hour soak. The older
`worker-scaling` and `memory-soak-24h` are compatibility scenarios, not extra
mandatory stages.

## 5. Download, verify and destroy

Do not wait for shutdown to save results. Checkpoints attempt uploads every five
minutes, but are partial copies, not guaranteed snapshots or a maximum data-loss
window. Final upload is also bounded; failure does not prevent expiry shutdown.
Raw database/Prometheus volumes are not exported. S3 objects expire after 30 days.

```powershell
.\cloud\aws\Get-Results.ps1 -OutputDirectory .\artifacts\cloud\first-session
.\cloud\aws\Destroy-Lab.ps1 -ExpectedAccountId $accountId -WhatIf
```

Verify the downloaded evidence and preview. Only then explicitly authorize deletion:

```powershell
.\cloud\aws\Destroy-Lab.ps1 -ExpectedAccountId $accountId -DeleteResults
```

This permanently deletes cloud evidence and the lab after confirmation; the
downloaded copy remains. Without `-DeleteResults`, a populated bucket can leave
partial teardown. Check the result and AWS console for leftovers, not just a
stopped VM. Keep state/context through recovery, including after interrupted
deployment. They cannot be replaced by deleting state and starting over.
The operator and approved quota increase survive lab teardown.

## Safety checks before unattended tests

Stop and investigate process/collector death, missing metrics, failing uploads
or a nearly full disk. Ordinary test failure does not immediately stop the VM.
`Running`, `Uploading`, `Failed`, missing status or forced termination is not
successful acceptance. Short runs and `MemoryVerdict: Inconclusive` do not prove
memory stability or V1 release readiness.

Validate both expiry paths before unattended runs: the host timer stops work,
attempts upload and shuts down; the independent AWS Scheduler starts ten minutes
after TTL and repeats every five minutes. Timing/API delays are possible.
An enabled schedule proves configuration, not a successful stop.

To test the independent path, use a separate explicitly authorized short-lived
lab with no workload, after downloading its evidence. Disable only that lab's
host expiry timer and verify AWS stops it after TTL plus the grace period.
Never disable expiry on an active soak lab. If it remains running, manually stop
the exact lab instance and resolve Scheduler/IAM before leaving tests unattended.

## Optional details

<details>
<summary>Get temporary bootstrap credentials through browser login</summary>

Use this before step 1 only if credentials are not already injected:

```powershell
aws login --profile tinyevents-bootstrap --region eu-west-1
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap login failed' }
$sessionJson = aws configure export-credentials --profile tinyevents-bootstrap --format process
if ($LASTEXITCODE -ne 0) { throw 'Credential export failed' }
$session = $sessionJson | ConvertFrom-Json
$env:AWS_ACCESS_KEY_ID = $session.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $session.SecretAccessKey
$env:AWS_SESSION_TOKEN = $session.SessionToken
$session = $null
$sessionJson = $null
```

The export is captured, not printed. Do not run it standalone or share environment
dumps. See [AWS console credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

</details>

<details>
<summary>Operator session expired, environment-only login, or bootstrap retry</summary>

Refresh login without deploying again:
`aws login --profile tinyevents-operator-login --region eu-west-1`.

If operator temporary credentials are already injected, replace `-OperatorLogin`
with `-AwsProfile ''` in step 2 and pass `-AwsProfile ''` to subsequent wrappers.
Do not mix named profiles with credential environment variables. Conflicting
local profiles are rejected, not overwritten.

Bootstrap retries resume owned users without rotating passwords; foreign users
or changed policies are rejected. It creates no operator access keys. The initial
password briefly occupies a private temporary request file; a crash can leave it
behind. Do not use transcripts/debug dumps. Expiring a session does not revoke
the operator's administrator access.

</details>

<details>
<summary>Read metrics and open the dashboard</summary>

Scheduled bench details live in `workload/bench/`: open
`metadata/bench-status.json` and `reports/bench-report.md` there. JSON retains
per-kind latency, coverage and comparison caveats. Nested smoke has `result.json`
and `workload/smoke/result.json`, not its own scheduled-run status.
Keep logs and diagnostics private.

Processing timestamps are proxies, not exact commit-to-ACK timings. Cleanup
censors processed-row latency; permanent failures are not zero-latency successes.
Do not pool percentiles by averaging them or compare different backlogs as
identical trials. No worker/batch defaults are inferred automatically.

Runtime slopes exclude 15 minutes of warm-up and require six later samples over
30 minutes. Diagnostic capture requires sustained resident growth (256 MiB and
50%, five samples at least a minute apart after warm-up). At most one GC-dump
attempt occurs across PIDs, with a 65-second deadline, monitored 1-GiB output
threshold and 10 GiB free plus the output budget. Size checks can overshoot; they
are not a filesystem quota. Capture forces GC, consumes memory and contaminates
performance comparisons. Neither a trigger nor a slope is a leak verdict.

Full monitoring includes six services, runtime collectors and infrastructure
samples; minimal mode retains lightweight process samples, journals and TTL/S3
safeguards. Missing scrapes are not zero. PostgreSQL is a real server in a
four-CPU/8-GiB container on the same eight-vCPU host, not a managed database.

Run `.\cloud\aws\Open-LabDashboard.ps1` with the Session Manager plugin installed.
It forwards localhost:3000 over SSM without public ingress. Sign in as `admin`
with the host-local secret at `/etc/tinyevents-lab/secrets/grafana-admin-password`,
read through your private host session, never chat. Grafana shows infrastructure;
runtime GC and latency remain in CSV/JSON reports.

</details>

Maintaining the scripts? [Contributor tests](tests/README.md) are separate from
this user workflow. Outstanding acceptance is tracked in the
[roadmap](../../docs/roadmap.md#active-v1-operational-evidence---aws-laboratory).
