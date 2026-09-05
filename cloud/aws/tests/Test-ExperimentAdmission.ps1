#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$cloudRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $cloudRoot 'ScenarioContract.ps1')
. (Join-Path $cloudRoot 'ExpiryWatchdog.ps1')

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Label)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw "Unsafe input accepted: $Label" }
    Write-Host "PASS: $Label rejected"
}

foreach ($file in Get-ChildItem (Join-Path $cloudRoot 'scenarios') -Filter '*.json') {
    $document = Read-LabScenario $file.FullName
    if ($document.name -cne $file.BaseName) { throw 'Filename and scenario name differ.' }
    Assert-ScenarioFitsLab $document ([DateTimeOffset]::UtcNow.AddHours(30))
}
Write-Host 'PASS: every shipped scenario validates and fits a fresh 30-hour lab'

$testFile = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-admission-$([Guid]::NewGuid().ToString('N')).json"
$original = Get-Content (Join-Path $cloudRoot 'scenarios/memory-soak-2h.json') -Raw
try {
    $mutations = @(
        { param($d) $d.rate = 21 },
        { param($d) $d.workerCount = 25 },
        { param($d) $d.durationSeconds = '7200' },
        { param($d) $d.durationSeconds = 7.5 },
        { param($d) $d.durationSeconds = $true },
        { param($d) $d.estimatedMaximumMinutes = 1 },
        { param($d) $d.storageProvider = 'SqlServer' },
        { param($d) $d.runner = 'invented-runner' },
        { param($d) $d | Add-Member ratee 20 },
        { param($d) $d.PSObject.Properties.Remove('rate') }
    )
    foreach ($mutate in $mutations) {
        $document = $original | ConvertFrom-Json
        & $mutate $document
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testFile
        Assert-Rejected { Read-LabScenario $testFile } 'invalid soak contract'
    }
    $scaling = Get-Content (Join-Path $cloudRoot 'scenarios/worker-scaling.json') -Raw
    foreach ($counts in @(@(2, 4), @(1, 2, 2), @(1, 4, 2), @(1, 25), @(1, '2'))) {
        $document = $scaling | ConvertFrom-Json
        $document.workerCounts = $counts
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testFile
        Assert-Rejected { Read-LabScenario $testFile } 'invalid worker matrix'
    }
}
finally { if (Test-Path -LiteralPath $testFile) { Remove-Item -LiteralPath $testFile -Force } }

$soak = Read-LabScenario (Join-Path $cloudRoot 'scenarios/memory-soak-24h.json')
$now = [DateTimeOffset]::UtcNow
Assert-Rejected { Assert-ScenarioFitsLab $soak $now.AddHours(24) $now } 'insufficient TTL for settle/upload'
Assert-Rejected { Assert-ScenarioFitsLab $soak $now.AddMinutes(-1) $now } 'expired lab'

# Fake CLI functions only: tests never execute the installed AWS/Terraform CLI.
$expiry = [DateTimeOffset]::UtcNow.AddHours(30)
$global:tinyeventsAdmissionoutputs = [pscustomobject]@{
    aws_region = @{ value = 'eu-west-1' }; account_id = @{ value = '123456789012' }
    results_bucket = @{ value = 'offline-test-bucket' }; instance_id = @{ value = 'i-0123456789abcdef0' }
    expires_at = @{ value = $expiry.ToString('O') }
    expiry_watchdog = @{ value = @{ name = 'stop-expired-lab'; group_name = 'offline-expiry'; role_arn = 'arn:aws:iam::123456789012:role/offline-expiry' } }
}
$validScheduleJson = @{
    Name = 'stop-expired-lab'; GroupName = 'offline-expiry'; State = 'ENABLED'
    StartDate = $expiry.AddMinutes(10).ToString('O'); ScheduleExpression = 'rate(5 minutes)'
    FlexibleTimeWindow = @{ Mode = 'OFF' }
    Target = @{
        Arn = 'arn:aws:scheduler:::aws-sdk:ec2:stopInstances'
        RoleArn = 'arn:aws:iam::123456789012:role/offline-expiry'
        Input = (@{ InstanceIds = @('i-0123456789abcdef0'); Force = $true } | ConvertTo-Json -Compress)
    }
} | ConvertTo-Json -Depth 10
$global:tinyeventsAdmissionschedule = $validScheduleJson | ConvertFrom-Json
$global:tinyeventsAdmissionwriteCalls = 0
$global:tinyeventsAdmissionaccount = '123456789012'
$global:tinyeventsAdmissioncommandText = ''
function terraform { $global:LASTEXITCODE = 0; $global:tinyeventsAdmissionoutputs | ConvertTo-Json -Depth 10 }
function aws {
    $global:LASTEXITCODE = 0
    switch ("$($args[0]) $($args[1])") {
        'sts get-caller-identity' { @{ Account = $global:tinyeventsAdmissionaccount; Arn = "arn:aws:iam::$($global:tinyeventsAdmissionaccount):user/tinyevents-lab-operator" } | ConvertTo-Json }
        'scheduler get-schedule' { $global:tinyeventsAdmissionschedule | ConvertTo-Json -Depth 10 }
        's3 cp' { $global:tinyeventsAdmissionwriteCalls++ }
        'ssm send-command' {
            $global:tinyeventsAdmissionwriteCalls++
            $parameters = $args[[Array]::IndexOf($args, '--parameters') + 1] -replace '^file://', ''
            $global:tinyeventsAdmissioncommandText = (Get-Content $parameters -Raw | ConvertFrom-Json).commands[0]
            'offline-command'
        }
        default { throw "Unexpected fake AWS command: $($args[0]) $($args[1])" }
    }
}
$savedEnvironment = @{}
try {
    foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    & (Join-Path $cloudRoot 'Start-Experiment.ps1') -Scenario memory-soak-2h
    if ($global:tinyeventsAdmissionwriteCalls -ne 2 -or $global:tinyeventsAdmissioncommandText -notmatch 'RuntimeMaxSec=8400') {
        throw 'Valid admission did not schedule exactly one bounded experiment.'
    }
    Write-Host 'PASS: valid scenario schedules one experiment with a systemd runtime deadline'
    $mutations = @(
        { $global:tinyeventsAdmissionaccount = '999999999999' },
        { $global:tinyeventsAdmissionoutputs.expires_at.value = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O') },
        { $global:tinyeventsAdmissionschedule.State = 'DISABLED' },
        { $global:tinyeventsAdmissionschedule.StartDate = $expiry.AddHours(1).ToString('O') },
        { $global:tinyeventsAdmissionschedule.Target.Input = '{"InstanceIds":["i-another"],"Force":true}' },
        { $global:tinyeventsAdmissionschedule.Target.Input = '{"InstanceIds":["i-0123456789abcdef0","i-another"],"Force":true}' },
        { $global:tinyeventsAdmissionschedule.Target.Input = '{"InstanceIds":["i-0123456789abcdef0"],"Force":false}' },
        { $global:tinyeventsAdmissionschedule.Target.RoleArn = 'arn:aws:iam::123456789012:role/another' },
        { $global:tinyeventsAdmissionschedule.ScheduleExpression = 'rate(1 day)' },
        { $global:tinyeventsAdmissionschedule.FlexibleTimeWindow.Mode = 'FLEXIBLE' },
        { $global:tinyeventsAdmissionschedule | Add-Member EndDate $expiry.AddMinutes(11).ToString('O') },
        { $global:tinyeventsAdmissionoutputs.PSObject.Properties.Remove('expiry_watchdog') }
    )
    foreach ($mutate in $mutations) {
        $global:tinyeventsAdmissionaccount = '123456789012'
        $global:tinyeventsAdmissionoutputs.expires_at.value = $expiry.ToString('O')
        $global:tinyeventsAdmissionschedule = $validScheduleJson | ConvertFrom-Json
        $global:tinyeventsAdmissionwriteCalls = 0
        & $mutate
        Assert-Rejected { & (Join-Path $cloudRoot 'Start-Experiment.ps1') -Scenario memory-soak-2h } 'unsafe admission'
        if ($global:tinyeventsAdmissionwriteCalls -ne 0) { throw 'Admission failure caused an external write.' }
    }
    Write-Host 'PASS: account, TTL, missing/modified watchdog block all S3 and SSM writes'
}
finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
}
