[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern("^[a-z0-9][a-z0-9-]{1,62}$")][string]$Scenario,
    [string]$AwsProfile = "default"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$localScenario = Join-Path $PSScriptRoot "scenarios/$Scenario.json"
if (!(Test-Path -LiteralPath $localScenario)) {
    $available = Get-ChildItem (Join-Path $PSScriptRoot "scenarios") -Filter "*.json" |
        Select-Object -ExpandProperty BaseName
    throw "Unknown scenario '$Scenario'. Available scenarios: $($available -join ', ')."
}

$output = Get-LabTerraformOutput
$region = $output.aws_region.value
$bucket = $output.results_bucket.value
$instanceId = $output.instance_id.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

& aws s3 cp $localScenario "s3://$bucket/scenarios/$Scenario.json" `
    --profile $AwsProfile `
    --region $region `
    --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Scenario document could not be uploaded."
}

$command = @"
set -euo pipefail
test "`$(cat /opt/tinyevents-lab/bootstrap-status)" = "smoke-ready"
test ! -e /run/systemd/transient/tinyevents-experiment.service
aws s3 cp "s3://$bucket/scenarios/$Scenario.json" "/opt/tinyevents-lab/$Scenario.json" --only-show-errors
systemd-run --unit=tinyevents-experiment --collect --property=Type=exec /usr/bin/pwsh -NoLogo -NoProfile -File /opt/tinyevents-lab/sources/TinyEvents.Dogfood/cloud/aws/host/Invoke-CloudExperiment.ps1 -ScenarioPath "/opt/tinyevents-lab/$Scenario.json"
"@
$parametersPath = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-start-$([Guid]::NewGuid().ToString('N')).json"

try {
    @{ commands = @($command) } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $parametersPath
    $commandId = & aws ssm send-command `
        --profile $AwsProfile `
        --region $region `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "file://$parametersPath" `
        --query "Command.CommandId" `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Experiment '$Scenario' could not be scheduled."
    }

    Write-Host "Scenario '$Scenario' scheduled through SSM command $($commandId.Trim())."
    Write-Host "It runs independently of this terminal. Use Get-ExperimentStatus.ps1 to follow it."
}
finally {
    if (Test-Path -LiteralPath $parametersPath) {
        Remove-Item -LiteralPath $parametersPath -Force
    }
}

