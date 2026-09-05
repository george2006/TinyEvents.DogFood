[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [AllowEmptyString()][string]$AwsProfile = "tinyevents-lab",
    [Parameter(Mandatory)][ValidatePattern('^[0-9]{12}$')][string]$ExpectedAccountId,
    [switch]$DeleteResults
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$output = Get-LabTerraformOutput
$region = $output.aws_region.value
$identity = Assert-AwsIdentity $AwsProfile $region
if ($identity.Account -ne $ExpectedAccountId -or $output.account_id.value -ne $ExpectedAccountId) {
    throw 'Credential, Terraform state, and expected account must match before destruction.'
}

if (!$DeleteResults) {
    Write-Host "The evidence bucket is protected. Terraform destruction will stop if it contains objects."
}
else {
    Write-Warning "DeleteResults permits permanent deletion of every object in the laboratory evidence bucket."
}

$variables = @(
    "-var", "aws_profile=$AwsProfile",
    "-var", "aws_region=$region",
    "-var", "expected_account_id=$ExpectedAccountId",
    "-var", "alert_email=$($output.alert_email.value)",
    "-var", "monthly_budget_usd=$($output.monthly_budget_usd.value)",
    "-var", "standard_vcpu_quota=$($output.standard_vcpu_quota.value)",
    "-var", "owner=destroy",
    "-var", "expires_at=$($output.expires_at.value)",
    "-var", "allow_results_bucket_destroy=$($DeleteResults.IsPresent.ToString().ToLowerInvariant())"
)
if (!$PSCmdlet.ShouldProcess("AWS account $ExpectedAccountId, instance $($output.instance_id.value), bucket $($output.results_bucket.value)", 'Destroy the laboratory (operator remains; budget is removed)')) { return }
if ($DeleteResults) {
    # force_destroy is stored in state: persist the explicitly authorized change
    # before destroy, which otherwise uses the old false value.
    Invoke-Terraform (@('apply', '-input=false', '-auto-approve', '-target=aws_s3_bucket.results') + $variables)
}
Invoke-Terraform (@('destroy', '-input=false', '-auto-approve') + $variables)
Write-Host 'Laboratory teardown completed. The bootstrap operator and any approved quota increase remain.'
