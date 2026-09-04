[CmdletBinding()]
param(
    [string]$AwsProfile = "default",
    [switch]$DeleteResults
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$output = Get-LabTerraformOutput
$region = $output.aws_region.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

if (!$DeleteResults) {
    Write-Host "The evidence bucket is protected. Terraform destruction will stop if it contains objects."
}
else {
    Write-Warning "DeleteResults permits permanent deletion of every object in the laboratory evidence bucket."
}

Invoke-Terraform @(
    "destroy",
    "-auto-approve",
    "-var", "aws_profile=$AwsProfile",
    "-var", "aws_region=$region",
    "-var", "owner=destroy",
    "-var", "expires_at=$($output.expires_at.value)",
    "-var", "allow_results_bucket_destroy=$($DeleteResults.IsPresent.ToString().ToLowerInvariant())"
)

