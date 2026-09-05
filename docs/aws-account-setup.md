# AWS Setup: Two Blocks

Use a **dedicated laboratory account**. You create the AWS account, add payment
details, and enable root MFA. Install PowerShell 7.4+, AWS CLI 2.32+, Terraform
1.6+, and Git. Run these commands from the repository root.

The scripts are locally tested with command doubles; **real AWS execution is
still unvalidated**, including browser login/MFA policy compatibility. Neither
block writes cloud resources without `-Apply` and confirmation.

## Block 1 - Environment credentials create the operator

Inject `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN`
into your local process, never chat, source files, `.tfvars`, or command-line
arguments. Use a temporary privileged session. If you already have those
variables, skip this optional way to obtain them without permanent root keys:

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

The captured export is intentionally **not printed**. Do not run that export
standalone or share environment dumps. Temporary console login is documented by
[AWS](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

```powershell
# Replace this example with your account's 12-digit ID.
$accountId = '123456789012'
.\cloud\aws\Bootstrap-Account.ps1 -ExpectedAccountId $accountId -AllowRootBootstrap
# Review the preview, then explicitly create the operator:
.\cloud\aws\Bootstrap-Account.ps1 -ExpectedAccountId $accountId -AllowRootBootstrap -Apply
```

Omit `-AllowRootBootstrap` for a non-root administrator. Root requires temporary
credentials, including the session token. The script prompts securely for the
initial operator password; store it in your password manager.

This creates **only** `tinyevents-lab-operator`, its MFA guard, administrator
policy attachment, and console login. No VM, bucket, budget, CloudFormation
stack, or operator access keys. Retries resume owned users without rotating
their password; foreign users or changed policies are rejected.

Open the console URL printed by the script, sign in as the operator, change its
password, and enroll MFA using device name `tinyevents-lab-operator`. Sign out
and back in with MFA. These personal authentication steps cannot be automated
on your behalf. Then clear bootstrap credentials, including after a failure:

```powershell
$env:AWS_ACCESS_KEY_ID = $null
$env:AWS_SECRET_ACCESS_KEY = $null
$env:AWS_SESSION_TOKEN = $null
aws logout --profile tinyevents-bootstrap # if you used the optional login above
```

The operator is an **account administrator**, not a least-privilege sandbox.
It can modify its own permissions after authenticating with MFA. Session expiry
does not remove administrator access. Never use this bootstrap in a shared or
production account. The initial password briefly occupies a private temporary
request file, removed on normal completion/error; a killed process or machine
crash can leave it behind. Do not use transcripts or credential/debug dumps.

## Block 2 - Terraform creates the laboratory

```powershell
.\cloud\aws\Deploy-Lab.ps1 -OperatorLogin `
    -ExpectedAccountId $accountId -Owner 'your-name' -AlertEmail 'you@example.com'

# After reviewing the resource plan and cost, create a fresh plan and confirm:
.\cloud\aws\Deploy-Lab.ps1 `
    -ExpectedAccountId $accountId -Owner 'your-name' -AlertEmail 'you@example.com' -Apply
```

`-OperatorLogin` opens AWS login and configures the `tinyevents-operator-login`
and `tinyevents-lab` profiles for refreshable temporary credentials. Choose the
operator, not root. Existing conflicting profile settings are rejected rather
than overwritten. Repeat with `-OperatorLogin` when the session expires. If you
already injected **operator** temporary credentials, use `-AwsProfile ''`
instead; never mix a named profile with credential environment variables.

Terraform owns the runtime IAM role/profile, monthly cost alerts, networking,
one EC2 VM, encrypted disk, and private results bucket. It also tracks the EC2
quota: if fewer than 8 vCPU are approved, this run plans/applies **only the quota
request**. AWS approval is not automatic; rerun Block 2 after approval. Root,
the wrong account, and the bootstrap principal are rejected before deployment.
MFA/preflight failure stops the script; do not remove the policy guard to bypass it.

Default budget alerts are 50/80/100% of **50 USD/month**, not a spending cap.
The VM expires after at most 30 hours; stopped disks and retained S3 results
remain billable. Review the [cost envelope](aws-cloud-lab-costs.md) before applying.

The [lab runbook](../cloud/aws/README.md) covers source upload, host initialization,
scenarios, result downloads, and teardown. No test starts automatically merely
because Terraform finished. Download results before destroying the lab:

```powershell
.\cloud\aws\Get-Results.ps1
.\cloud\aws\Destroy-Lab.ps1 -ExpectedAccountId $accountId
```

A non-empty bucket blocks deletion unless you explicitly choose `-DeleteResults`.
Lab teardown removes its budget and runtime roles, but **not the operator** or
an approved quota increase. Keep the ignored Terraform state and `.lab-context.json`
until cleanup is complete. The latter records non-secret deployment parameters
before applying, so an interrupted deployment can be cleaned up without final
VM outputs. It does not replace lost state. Removing operator access is a separate,
deliberate account action.
