[CmdletBinding()]
param(
    [string]$AwsProfile = "default"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$output = Get-LabTerraformOutput
$instanceId = $output.instance_id.value
$region = $output.aws_region.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

$instance = & aws ec2 describe-instances `
    --profile $AwsProfile `
    --region $region `
    --instance-ids $instanceId `
    --query "Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress,LaunchTime:LaunchTime}" `
    --output json

if ($LASTEXITCODE -ne 0) {
    throw "Could not read EC2 instance '$instanceId'."
}

$ssm = & aws ssm describe-instance-information `
    --profile $AwsProfile `
    --region $region `
    --filters "Key=InstanceIds,Values=$instanceId" `
    --query "InstanceInformationList[0].{PingStatus:PingStatus,Platform:PlatformName,AgentVersion:AgentVersion}" `
    --output json

if ($LASTEXITCODE -ne 0) {
    throw "Could not read SSM status for '$instanceId'."
}

$ssmValue = if ($ssm -eq "null") { $null } else { $ssm | ConvertFrom-Json }
$bootstrapStatus = $null

if ($null -ne $ssmValue -and $ssmValue.PingStatus -eq "Online") {
    $commandId = & aws ssm send-command `
        --profile $AwsProfile `
        --region $region `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters 'commands=["cat /opt/tinyevents-lab/bootstrap-status 2>/dev/null || echo pending"]' `
        --query "Command.CommandId" `
        --output text

    if ($LASTEXITCODE -eq 0) {
        & aws ssm wait command-executed `
            --profile $AwsProfile `
            --region $region `
            --command-id $commandId.Trim() `
            --instance-id $instanceId

        if ($LASTEXITCODE -eq 0) {
            $bootstrapStatus = (& aws ssm get-command-invocation `
                --profile $AwsProfile `
                --region $region `
                --command-id $commandId.Trim() `
                --instance-id $instanceId `
                --query "StandardOutputContent" `
                --output text).Trim()
        }
    }
}

[pscustomobject]@{
    InstanceId = $instanceId
    Region = $region
    ExpiresAt = $output.expires_at.value
    Instance = $instance | ConvertFrom-Json
    Ssm = $ssmValue
    BootstrapStatus = $bootstrapStatus
} | ConvertTo-Json -Depth 5
