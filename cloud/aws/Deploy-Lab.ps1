#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [AllowEmptyString()][string]$AwsProfile = "tinyevents-lab",
    [string]$Region = "eu-west-1",
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]{12}$')][string]$ExpectedAccountId,
    [Parameter(Mandatory)][ValidatePattern('^[^\s@]+@[^\s@]+\.[^\s@]+$')][string]$AlertEmail,
    [ValidateRange(1, 2000)][int]$MonthlyBudgetUsd = 50,
    [switch]$OperatorLogin,
    [string]$ExperimentName = "foundation",
    [string]$InstanceType = "m7i.2xlarge",
    [ValidateRange(80, 1000)][int]$VolumeSizeGiB = 150,
    [ValidateRange(1, 30)][int]$LifetimeHours = 30,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")
if ($OperatorLogin) {
    if ($AwsProfile -ne 'tinyevents-lab') { throw '-OperatorLogin uses the tinyevents-lab profile.' }
    if ($WhatIfPreference) { Write-Host 'WhatIf: would open operator login and prepare a Terraform plan. No login or resources changed.'; return }
    . (Join-Path $PSScriptRoot 'bootstrap/OperatorLogin.ps1')
    Initialize-OperatorLogin -ExpectedAccountId $ExpectedAccountId -Region $Region
}

$identity = Assert-AwsIdentity $AwsProfile $Region
if ($identity.Account -ne $ExpectedAccountId) { throw 'AWS account mismatch. No resources were changed.' }
if ($identity.Arn -ne "arn:aws:iam::${ExpectedAccountId}:user/tinyevents-lab-operator") { throw 'Block 2 requires the tinyevents-lab-operator identity, not the bootstrap principal.' }
$profileArguments = @(Get-AwsProfileArguments $AwsProfile)
# This API also exercises the MFA deny before Terraform can change resources.
$quotaJson = & aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A @profileArguments --region $Region --output json
if ($LASTEXITCODE -ne 0) { throw 'Operator/quota preflight failed. Re-login with MFA; do not remove the MFA guard to bypass AccessDenied.' }
$quota = $quotaJson | ConvertFrom-Json
$quotaOnly = [double]$quota.Quota.Value -lt 8
$desiredQuota = [Math]::Max(8, [double]$quota.Quota.Value)
$targetArguments = @()
if ($quotaOnly) {
    Write-Warning 'Insufficient EC2 quota. This run plans only a Terraform quota-increase request, not a VM. AWS approval is asynchronous.'
    $targetArguments = @('-target=aws_servicequotas_service_quota.standard_ec2')
}
$expiresAt = [DateTimeOffset]::UtcNow.AddHours($LifetimeHours).ToString("O")

Write-Host "AWS account: $($identity.Account)"
Write-Host "AWS identity: $($identity.Arn)"
Write-Host "Region: $Region"
Write-Host "Instance type: $InstanceType"
Write-Host "Mandatory expiry: $expiresAt"

$planPath = Join-Path (Get-TerraformDirectory) "deploy-$([Guid]::NewGuid().ToString('N')).tfplan"
Invoke-Terraform @("init", "-input=false")
Invoke-Terraform (@(
    "plan",
    "-input=false",
    "-out=$planPath",
    "-var", "aws_profile=$AwsProfile",
    "-var", "aws_region=$Region",
    "-var", "expected_account_id=$ExpectedAccountId",
    "-var", "alert_email=$AlertEmail",
    "-var", "monthly_budget_usd=$MonthlyBudgetUsd",
    "-var", "standard_vcpu_quota=$desiredQuota",
    "-var", "owner=$Owner",
    "-var", "experiment_name=$ExperimentName",
    "-var", "instance_type=$InstanceType",
    "-var", "root_volume_size_gib=$VolumeSizeGiB",
    "-var", "expires_at=$expiresAt"
) + $targetArguments)
if (!$Apply) {
    Write-Host "Preview only. Saved plan: $planPath"
    Write-Host 'Review the plan and cost, then rerun with -Apply for a fresh plan and confirmation. No resources were created.'
    return
}
$action = if ($quotaOnly) { 'Submit the Terraform quota request displayed above (no VM)' } else { 'Apply the Terraform plan displayed above (billable resources)' }
if (!$PSCmdlet.ShouldProcess("AWS account $ExpectedAccountId in $Region", $action)) { return }
if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($expiresAt)) { throw 'Plan expiry has passed; create a fresh plan.' }
$applyIdentity = Assert-AwsIdentity $AwsProfile $Region
if ($applyIdentity.Account -ne $ExpectedAccountId -or $applyIdentity.Arn -ne $identity.Arn) { throw 'Identity changed since planning. Refusing to apply.' }
Invoke-Terraform @('apply', '-input=false', $planPath)
if ($quotaOnly) {
    Write-Host 'Quota request submitted/tracked by Terraform, not necessarily approved. Rerun this script after AWS approval; no VM was requested.'
    return
}

$output = Get-LabTerraformOutput
$instanceId = $output.instance_id.value
Write-Host "Instance: $($output.instance_id.value)"
Write-Host "Results bucket: $($output.results_bucket.value)"

Write-Host "Waiting up to ten minutes for Systems Manager connectivity..."
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
$online = $false

while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $pingStatus = & aws ssm describe-instance-information `
        @profileArguments `
        --region $Region `
        --filters "Key=InstanceIds,Values=$instanceId" `
        --query "InstanceInformationList[0].PingStatus" `
        --output text

    if ($LASTEXITCODE -eq 0 -and $pingStatus.Trim() -eq "Online") {
        $online = $true
        break
    }

    Start-Sleep -Seconds 10
}

if (!$online) {
    throw "Instance '$instanceId' was created but did not become SSM-online within ten minutes. It still expires at $expiresAt."
}

Write-Host "The instance is SSM-online. Run Get-LabStatus.ps1 to inspect bootstrap readiness."
Write-Host "Stage exact clean source commits with Publish-LabSources.ps1 after bootstrap reports host-prerequisites-ready."
