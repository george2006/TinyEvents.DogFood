[CmdletBinding()]
param(
    [string]$AwsProfile = "default",
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\..\artifacts\cloud")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$output = Get-LabTerraformOutput
$region = $output.aws_region.value
$bucket = $output.results_bucket.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

& aws s3 sync "s3://$bucket/" $resolvedOutput `
    --profile $AwsProfile `
    --region $region `
    --only-show-errors

if ($LASTEXITCODE -ne 0) {
    throw "Could not download evidence from bucket '$bucket'."
}

Write-Host "Evidence downloaded to $resolvedOutput"
