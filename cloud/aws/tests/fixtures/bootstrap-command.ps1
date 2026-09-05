#!/usr/bin/env pwsh
# Offline process double, not an IAM authorization simulator.
$ErrorActionPreference = 'Stop'
$state = Get-Content -LiteralPath $env:BOOTSTRAP_TEST_STATE -Raw | ConvertFrom-Json -AsHashtable
$commandArgs = @($args)
$service = if ($commandArgs[0] -like '-chdir=*') { 'terraform' } else { $commandArgs[0] }
$operation = if ($service -eq 'login') { '' } else { $commandArgs[1] }
$record = @{ Service = $service; Operation = $operation; Arguments = $commandArgs }
$inputObject = $null
$inputIndex = [Array]::IndexOf($commandArgs, '--cli-input-json')
if ($inputIndex -ge 0) {
    $inputPath = $commandArgs[$inputIndex + 1].Substring(7)
    $inputObject = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json -AsHashtable
    $record.InputPath = $inputPath
    $record.PrivateDirectory = [int][IO.File]::GetUnixFileMode([IO.Path]::GetDirectoryName($inputPath)) -eq 448
}
$record | ConvertTo-Json -Compress -Depth 10 | Add-Content -LiteralPath $env:BOOTSTRAP_TEST_LOG
function Save-State { $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:BOOTSTRAP_TEST_STATE }
function Emit($value) { $value | ConvertTo-Json -Depth 50 -Compress; exit 0 }
function Fail($value) { [Console]::Error.WriteLine($value); exit 1 }
$profileIndex = [Array]::IndexOf($commandArgs, '--profile')
$selectedProfile = if ($profileIndex -ge 0) { $commandArgs[$profileIndex + 1] } else { '' }
switch ("$service/$operation") {
    'sts/get-caller-identity' { Emit @{ Account = $state.Account; Arn = $state.Arn } }
    'iam/get-user' { if (!$state.User) { Fail '(NoSuchEntity) Missing user' }; Emit @{ User = $state.User } }
    'iam/create-user' {
        $state.User = @{ UserName = $inputObject.UserName; Path = '/'; Tags = $inputObject.Tags }
        Save-State; Emit @{ User = $state.User }
    }
    'iam/get-user-policy' { if (!$state.Policy) { Fail '(NoSuchEntity) Missing policy' }; Emit @{ PolicyDocument = $state.Policy } }
    'iam/put-user-policy' {
        if ($state.PolicyFailure) { Fail '(AccessDenied) fixture policy failure' }
        $state.Policy = $inputObject.PolicyDocument | ConvertFrom-Json -AsHashtable
        Save-State; exit 0
    }
    'iam/list-attached-user-policies' { Emit @{ AttachedPolicies = @($state.Attached | ForEach-Object { @{ PolicyArn = $_ } }) } }
    'iam/attach-user-policy' { $state.Attached = @('arn:aws:iam::aws:policy/AdministratorAccess'); Save-State; exit 0 }
    'iam/get-login-profile' { if (!$state.LoginProfile) { Fail '(NoSuchEntity) Missing login' }; Emit @{ LoginProfile = @{ UserName = 'tinyevents-lab-operator' } } }
    'iam/create-login-profile' {
        if ($state.SensitiveFailure) { Fail $inputObject.Password }
        if ($state.SensitiveHang) { Start-Sleep -Seconds 30 }
        if (!$inputObject.PasswordResetRequired) { Fail 'Password reset must be required' }
        $state.LoginProfile = $true; Save-State
        Emit $inputObject # deliberate echo: wrapper must suppress sensitive success
    }
    'configure/get' {
        $key = "$selectedProfile/$($commandArgs[2])"
        if ($state.Config.ContainsKey($key)) { Write-Output $state.Config[$key]; exit 0 }
        exit 1
    }
    'configure/set' { $state.Config["$selectedProfile/$($commandArgs[2])"] = $commandArgs[3]; Save-State; exit 0 }
    'login/' { $state.Arn = $state.LoginArn; Save-State; exit 0 }
    'service-quotas/get-service-quota' {
        if (!$state.Mfa) { Fail '(AccessDenied) MFA required' }
        Emit @{ Quota = @{ Value = $state.Quota } }
    }
    'terraform/init' { exit 0 }
    'terraform/plan' {
        if ($state.PlanFailure) { Fail 'fixture planning failure' }
        $state.QuotaOnlyPlan = $commandArgs -contains '-target=aws_servicequotas_service_quota.standard_ec2'
        Save-State
        Write-Output 'Offline Terraform plan fixture'; exit 0
    }
    'terraform/apply' {
        $workingDirectory = $commandArgs[0].Substring(7)
        $testRoot = [IO.Path]::GetDirectoryName($env:BOOTSTRAP_TEST_STATE) + [IO.Path]::DirectorySeparatorChar
        if (![IO.Path]::GetFullPath($workingDirectory).StartsWith($testRoot, [StringComparison]::Ordinal)) { Fail 'Fixture refused state outside its temporary workspace' }
        $localState = if ($state.ContainsKey('TerraformState')) { $state.TerraformState } else {
            @{ version = 4; lineage = 'fixture-lineage'; outputs = @{}; resources = @() }
        }
        $localState | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $workingDirectory 'terraform.tfstate')
        if ($state.ContainsKey('ApplyFailure') -and $state.ApplyFailure) { Fail 'fixture interrupted apply' }
        if ($state.QuotaOnlyPlan) { $state.QuotaRequested = $true } else { $state.InstanceCreated = $true }
        Save-State; exit 0
    }
    'terraform/show' {
        Emit @{ format_version = '1.2'; resource_changes = @(@{
            address = $state.BucketPlanAddress; change = @{ actions = $state.BucketPlanActions }
        }) }
    }
    'terraform/destroy' { exit 0 }
    'terraform/output' {
        Emit @{
            instance_id = @{ value = 'i-offline' }; results_bucket = @{ value = 'offline-bucket' }
            account_id = @{ value = '123456789012' }; aws_region = @{ value = 'eu-west-1' }
            expires_at = @{ value = '2020-01-01T00:00:00Z' }; alert_email = @{ value = 'lab@example.invalid' }
            monthly_budget_usd = @{ value = 50 }; standard_vcpu_quota = @{ value = 8 }
        }
    }
    'ssm/describe-instance-information' { Write-Output 'Online'; exit 0 }
    default { Fail "Unexpected offline call: $service/$operation" }
}
