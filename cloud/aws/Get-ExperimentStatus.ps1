[CmdletBinding()]
param(
    [string]$AwsProfile = "default"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$output = Get-LabTerraformOutput
$region = $output.aws_region.value
$instanceId = $output.instance_id.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

$parametersPath = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-status-$([Guid]::NewGuid().ToString('N')).json"
try {
    @{
        commands = @(
            "cat /opt/tinyevents-lab/experiment-status.json 2>/dev/null || echo '{`"State`":`"NotStarted`"}'"
        )
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $parametersPath

    $commandId = & aws ssm send-command `
        --profile $AwsProfile `
        --region $region `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters "file://$parametersPath" `
        --query "Command.CommandId" `
        --output text
    if ($LASTEXITCODE -ne 0) {
        throw "Experiment status command could not be sent."
    }

    & aws ssm wait command-executed `
        --profile $AwsProfile `
        --region $region `
        --command-id $commandId.Trim() `
        --instance-id $instanceId
    if ($LASTEXITCODE -ne 0) {
        throw "Experiment status command did not complete."
    }

    & aws ssm get-command-invocation `
        --profile $AwsProfile `
        --region $region `
        --command-id $commandId.Trim() `
        --instance-id $instanceId `
        --query "StandardOutputContent" `
        --output text
}
finally {
    if (Test-Path -LiteralPath $parametersPath) {
        Remove-Item -LiteralPath $parametersPath -Force
    }
}
