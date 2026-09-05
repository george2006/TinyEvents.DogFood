#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [AllowEmptyString()][string]$AwsProfile = "tinyevents-lab",
    [Parameter(Mandatory)][ValidatePattern('^[0-9]{12}$')][string]$ExpectedAccountId,
    [switch]$DeleteResults
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot 'DeploymentContext.ps1')

$state = Get-LocalLabState
if ($null -eq $state) { throw 'Local Terraform state is missing. Restore it before teardown; a recovery context cannot replace state.' }
$context = Get-LabDeploymentContext
if ($context) {
    $parameters = $context.Parameters
    Write-Host 'Using saved deployment parameters; final instance/bucket outputs are not required.'
}
else {
    # Compatibility with completed deployments predating the recovery record.
    $output = Get-LabTerraformOutput
    foreach ($key in @('account_id', 'aws_region', 'alert_email', 'monthly_budget_usd', 'standard_vcpu_quota', 'expires_at')) {
        if ($null -eq $output.PSObject.Properties[$key]) { throw 'Deployment outputs are incomplete and no recovery context exists. Restore the matching context or review recovery manually.' }
    }
    $parameters = [ordered]@{
        expected_account_id = $output.account_id.value; aws_region = $output.aws_region.value
        owner = 'destroy'; alert_email = $output.alert_email.value; monthly_budget_usd = $output.monthly_budget_usd.value
        standard_vcpu_quota = $output.standard_vcpu_quota.value; expires_at = $output.expires_at.value
    }
}
$region = $parameters.aws_region
if ($parameters.expected_account_id -ne $ExpectedAccountId) { throw 'Credential, Terraform state, and expected account must match before destruction.' }
Assert-LabStateContext -State $state -Context $context -ExpectedAccountId $ExpectedAccountId -Region $region
$identity = Assert-AwsIdentity $AwsProfile $region
if ($identity.Account -ne $ExpectedAccountId) {
    throw 'Credential, Terraform state, and expected account must match before destruction.'
}

if (!$DeleteResults) {
    Write-Host "The evidence bucket is protected. Terraform destruction will stop if it contains objects."
}
else {
    Write-Warning "DeleteResults permits permanent deletion of every object in the laboratory evidence bucket."
}

$variables = @('-var', "aws_profile=$AwsProfile", '-var', "allow_results_bucket_destroy=$($DeleteResults.IsPresent.ToString().ToLowerInvariant())")
foreach ($key in $parameters.Keys) {
    $value = $parameters[$key]
    if ($value -is [DateTime]) { $value = $value.ToUniversalTime().ToString('O') }
    $variables += @('-var', "$key=$value")
}
$bucket = Get-LabStateBucket $state
$bucketDescription = if ($bucket) { $bucket.id } else { 'not recorded in state' }
if (!$PSCmdlet.ShouldProcess("AWS account $ExpectedAccountId, region $region, bucket $bucketDescription", 'Destroy resources recorded in local Terraform state (operator remains; budget is removed)')) { return }
$currentIdentity = Assert-AwsIdentity $AwsProfile $region
if ($currentIdentity.Account -ne $ExpectedAccountId -or $currentIdentity.Arn -ne $identity.Arn) { throw 'Identity changed before teardown; refusing to proceed.' }
if ($bucket -and $bucket.force_destroy -ne $DeleteResults.IsPresent) {
    # Never create a bucket during cleanup. Also reset a previous true value on
    # a retry without -DeleteResults: old authorization must not silently persist.
    $planPath = Join-Path (Get-TerraformDirectory) "bucket-settings-$([Guid]::NewGuid().ToString('N')).tfplan"
    Invoke-Terraform (@('plan', '-input=false', '-target=aws_s3_bucket.results', "-out=$planPath") + $variables)
    Assert-BucketSettingPlan -PlanPath $planPath
    Invoke-Terraform @('apply', '-input=false', $planPath)
}
Invoke-Terraform (@('destroy', '-input=false', '-auto-approve') + $variables)
Write-Host 'Laboratory teardown completed. The bootstrap operator and any approved quota increase remain.'
