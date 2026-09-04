[CmdletBinding()]
param(
    [string]$AwsProfile = "default",
    [string]$Region = "eu-west-1",
    [Parameter(Mandatory)][string]$Owner,
    [string]$ExperimentName = "foundation",
    [string]$InstanceType = "m7i.2xlarge",
    [ValidateRange(80, 1000)][int]$VolumeSizeGiB = 150,
    [ValidateRange(1, 30)][int]$LifetimeHours = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$identity = Assert-AwsIdentity $AwsProfile $Region
$expiresAt = [DateTimeOffset]::UtcNow.AddHours($LifetimeHours).ToString("O")

Write-Host "AWS account: $($identity.Account)"
Write-Host "AWS identity: $($identity.Arn)"
Write-Host "Region: $Region"
Write-Host "Instance type: $InstanceType"
Write-Host "Mandatory expiry: $expiresAt"

Invoke-Terraform @("init", "-upgrade")
Invoke-Terraform @(
    "apply",
    "-auto-approve",
    "-var", "aws_profile=$AwsProfile",
    "-var", "aws_region=$Region",
    "-var", "owner=$Owner",
    "-var", "experiment_name=$ExperimentName",
    "-var", "instance_type=$InstanceType",
    "-var", "root_volume_size_gib=$VolumeSizeGiB",
    "-var", "expires_at=$expiresAt"
)

$output = Get-LabTerraformOutput
$instanceId = $output.instance_id.value
Write-Host "Instance: $($output.instance_id.value)"
Write-Host "Results bucket: $($output.results_bucket.value)"

Write-Host "Waiting up to ten minutes for Systems Manager connectivity..."
$deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
$online = $false

while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $pingStatus = & aws ssm describe-instance-information `
        --profile $AwsProfile `
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
