[CmdletBinding()]
param([AllowEmptyString()][string]$AwsProfile = 'tinyevents-lab', [ValidateRange(1024,65535)][int]$LocalPort = 3000)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')
$output = Get-LabTerraformOutput
$identity = Assert-AwsIdentity $AwsProfile $output.aws_region.value
if ($identity.Account -ne $output.account_id.value) { throw 'AWS account mismatch.' }
Assert-CommandAvailable 'session-manager-plugin'
$profileArguments = @(Get-AwsProfileArguments $AwsProfile)
Write-Host "Grafana tunnel: http://localhost:$LocalPort/d/tinyevents-lab/ . Keep this terminal open."
Write-Host 'Sign in as admin using the host-local Grafana secret; never paste it into chat or commit it.'
& aws ssm start-session --target $output.instance_id.value --region $output.aws_region.value @profileArguments `
    --document-name AWS-StartPortForwardingSession --parameters "portNumber=3000,localPortNumber=$LocalPort"
if ($LASTEXITCODE -ne 0) { throw 'SSM dashboard tunnel failed.' }
