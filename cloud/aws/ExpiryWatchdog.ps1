Set-StrictMode -Version Latest

function Assert-LabWatchdogConfiguration {
    param($Schedule, $Output)
    if ($null -eq $Output.PSObject.Properties['expiry_watchdog']) {
        throw 'Independent expiry outputs are missing. Complete the current Terraform deployment first.'
    }
    $expected = $Output.expiry_watchdog.value
    $inputDocument = $Schedule.Target.Input | ConvertFrom-Json
    $startDate = [DateTimeOffset]$Schedule.StartDate
    $expectedDate = ([DateTimeOffset]$Output.expires_at.value).AddMinutes(10)
    if ($Schedule.State -cne 'ENABLED' -or $Schedule.Name -cne $expected.name -or
        $Schedule.GroupName -cne $expected.group_name -or
        $Schedule.ScheduleExpression -cne 'rate(5 minutes)' -or
        $Schedule.FlexibleTimeWindow.Mode -cne 'OFF' -or
        $startDate -ne $expectedDate -or
        $Schedule.Target.Arn -cne 'arn:aws:scheduler:::aws-sdk:ec2:stopInstances' -or
        $Schedule.Target.RoleArn -cne $expected.role_arn -or
        @($inputDocument.InstanceIds).Count -ne 1 -or
        $inputDocument.InstanceIds[0] -cne $Output.instance_id.value -or
        $inputDocument.Force -isnot [bool] -or !$inputDocument.Force -or
        ($null -ne $Schedule.PSObject.Properties['EndDate'] -and $null -ne $Schedule.EndDate)) {
        throw 'Independent expiry configuration differs from the lab contract. Refusing to start work.'
    }
}

function Get-VerifiedLabWatchdog {
    param($Output, [AllowEmptyString()][string]$AwsProfile)
    if ($null -eq $Output.PSObject.Properties['expiry_watchdog']) {
        throw 'Independent expiry outputs are missing. Complete the current Terraform deployment first.'
    }
    $profileArguments = @(Get-AwsProfileArguments $AwsProfile)
    $expected = $Output.expiry_watchdog.value
    $raw = & aws scheduler get-schedule --name $expected.name --group-name $expected.group_name `
        @profileArguments --region $Output.aws_region.value --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify the independent AWS expiry schedule.' }
    $schedule = $raw | ConvertFrom-Json
    Assert-LabWatchdogConfiguration $schedule $Output
    return $schedule
}
