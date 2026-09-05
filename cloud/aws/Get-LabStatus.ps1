[CmdletBinding()]
param(
    [AllowEmptyString()][string]$AwsProfile = "tinyevents-lab"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot 'ExpiryWatchdog.ps1')
$profileArguments = @(Get-AwsProfileArguments $AwsProfile)

$output = Get-LabTerraformOutput
$instanceId = $output.instance_id.value
$region = $output.aws_region.value
$identity = Assert-AwsIdentity $AwsProfile $region
if ($identity.Account -ne $output.account_id.value) { throw 'AWS identity does not match the deployed lab account.' }
$watchdogStatus = try {
    $watchdog = Get-VerifiedLabWatchdog $output $AwsProfile
    [pscustomobject]@{ ConfigurationVerified = $true; StartDate = $watchdog.StartDate; Detail = 'Stop execution still requires live acceptance.' }
}
catch {
    [pscustomobject]@{ ConfigurationVerified = $false; Detail = $_.Exception.Message }
}

$instance = & aws ec2 describe-instances `
    @profileArguments `
    --region $region `
    --instance-ids $instanceId `
    --query "Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress,LaunchTime:LaunchTime}" `
    --output json

if ($LASTEXITCODE -ne 0) {
    throw "Could not read EC2 instance '$instanceId'."
}

$ssm = & aws ssm describe-instance-information `
    @profileArguments `
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
        @profileArguments `
        --region $region `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --parameters 'commands=["cat /opt/tinyevents-lab/bootstrap-status 2>/dev/null || echo pending"]' `
        --query "Command.CommandId" `
        --output text

    if ($LASTEXITCODE -eq 0) {
        & aws ssm wait command-executed `
            @profileArguments `
            --region $region `
            --command-id $commandId.Trim() `
            --instance-id $instanceId

        if ($LASTEXITCODE -eq 0) {
            $bootstrapStatus = (& aws ssm get-command-invocation `
                @profileArguments `
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
    ExpiryWatchdog = $watchdogStatus
    Instance = $instance | ConvertFrom-Json
    Ssm = $ssmValue
    BootstrapStatus = $bootstrapStatus
} | ConvertTo-Json -Depth 5
