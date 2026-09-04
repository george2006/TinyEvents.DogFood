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

