#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsLinux) { throw 'Run this suite in the documented isolated Linux container.' }
$awsRoot = Split-Path $PSScriptRoot -Parent
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-bootstrap-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$env:BOOTSTRAP_TEST_STATE = Join-Path $testDirectory 'state.json'
$env:BOOTSTRAP_TEST_LOG = Join-Path $testDirectory 'calls.jsonl'
$env:PATH = "$testDirectory$([IO.Path]::PathSeparator)$env:PATH"
$env:AWS_EC2_METADATA_DISABLED = 'true'
$env:AWS_CONFIG_FILE = Join-Path $testDirectory 'no-real-config'
$env:AWS_SHARED_CREDENTIALS_FILE = Join-Path $testDirectory 'no-real-credentials'
foreach ($name in @('aws', 'terraform')) {
    $target = Join-Path $testDirectory $name
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/bootstrap-command.ps1') -Destination $target
    & chmod 700 $target
    if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare command double.' }
}
function Assert($condition, [string]$message) { if (!$condition) { throw $message } }
function Save-State($state) { $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $env:BOOTSTRAP_TEST_STATE }
function Read-State { Get-Content -LiteralPath $env:BOOTSTRAP_TEST_STATE -Raw | ConvertFrom-Json -AsHashtable }
function Clear-Credentials { $env:AWS_ACCESS_KEY_ID = $null; $env:AWS_SECRET_ACCESS_KEY = $null; $env:AWS_SESSION_TOKEN = $null }
function Reset-State {
    Clear-Credentials
    Save-State @{
        Account = '123456789012'; Arn = 'arn:aws:iam::123456789012:user/bootstrap-admin'
        User = $null; Policy = $null; Attached = @(); LoginProfile = $false; Quota = 8; Mfa = $true
        SensitiveFailure = $false; SensitiveHang = $false; PolicyFailure = $false; PlanFailure = $false
        Config = @{}; LoginArn = 'arn:aws:iam::123456789012:user/tinyevents-lab-operator'
        QuotaOnlyPlan = $false; QuotaRequested = $false; InstanceCreated = $false
    }
    Set-Content -LiteralPath $env:BOOTSTRAP_TEST_LOG -Value ''
}
function Set-FixtureCredentials {
    $env:AWS_ACCESS_KEY_ID = 'fixture-access-key'; $env:AWS_SECRET_ACCESS_KEY = 'fixture-secret-key'; $env:AWS_SESSION_TOKEN = 'fixture-session-token'
}
function Calls { Get-Content -LiteralPath $env:BOOTSTRAP_TEST_LOG | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } }
function Assert-NoWrites {
    Assert (@(Calls | Where-Object { $_.Operation -in @('create-user', 'put-user-policy', 'attach-user-policy', 'create-login-profile', 'apply', 'destroy') }).Count -eq 0) 'Read-only guard allowed an external mutation.'
}
function Expect-Failure([scriptblock]$action, [string]$pattern) {
    $caught = $null
    try { & $action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -match $pattern) "Expected '$pattern'; received '$caught'."
    Assert (!$caught.Contains('Fixture-only-password!42')) 'Password leaked in an exception.'
}
function Assert-InputCleanup {
    foreach ($call in @(Calls | Where-Object { $_.PSObject.Properties.Name -contains 'InputPath' })) {
        Assert $call.PrivateDirectory 'Request directory was not private.'
        Assert (!(Test-Path -LiteralPath $call.InputPath)) 'Request file was not removed.'
    }
    $log = Get-Content -LiteralPath $env:BOOTSTRAP_TEST_LOG -Raw
    foreach ($secret in @('Fixture-only-password!42', 'fixture-access-key', 'fixture-secret-key', 'fixture-session-token')) {
        Assert (!$log.Contains($secret)) 'Secret present in recorded command arguments.'
    }
}
$bootstrap = Join-Path $awsRoot 'Bootstrap-Account.ps1'
$options = @{ ExpectedAccountId = '123456789012' }
$password = ConvertTo-SecureString 'Fixture-only-password!42' -AsPlainText -Force
$policy = Get-Content (Join-Path $awsRoot 'bootstrap/operator-mfa-policy.json') -Raw | ConvertFrom-Json
Assert (($policy | ConvertTo-Json -Depth 20 -Compress).Length -le 2048) 'Inline user policy exceeds IAM size limit.'
Assert ($policy.Statement[0].Effect -eq 'Deny' -and $policy.Statement[0].Condition.BoolIfExists.'aws:MultiFactorAuthPresent' -eq 'false') 'MFA guard must fail closed.'
Assert (!(Test-Path (Join-Path $awsRoot 'bootstrap/template.json'))) 'Bootstrap still contains CloudFormation.'

Reset-State
Expect-Failure { & $bootstrap @options } 'AWS_ACCESS_KEY_ID'
Set-FixtureCredentials
& $bootstrap @options
& $bootstrap @options -Apply -WhatIf
Assert-NoWrites
Expect-Failure { & $bootstrap @options -ExpectedAccountId '000000000000' -Apply -Confirm:$false } 'account mismatch'
$state = Read-State; $state.Arn = 'arn:aws:iam::123456789012:root'; Save-State $state
Expect-Failure { & $bootstrap @options -Apply -Confirm:$false } 'AllowRootBootstrap'
$env:AWS_SESSION_TOKEN = $null
Expect-Failure { & $bootstrap @options -AllowRootBootstrap -Apply -Confirm:$false } 'temporary session token'
Assert-NoWrites
Write-Host 'PASS environment, preview, account, and root guards'

Reset-State; Set-FixtureCredentials
Expect-Failure { & $bootstrap @options -Apply -OperatorPassword (ConvertTo-SecureString 'short' -AsPlainText -Force) -Confirm:$false } '14 characters'
Assert-NoWrites
$output = (& $bootstrap @options -Apply -OperatorPassword $password -Confirm:$false *>&1 | Out-String)
Assert (!$output.Contains('Fixture-only-password!42')) 'Sensitive success output leaked.'
$completed = Read-State
Assert $completed.LoginProfile 'Console access not created.'
$writes = @(Calls | Where-Object { $_.Operation -in @('create-user', 'put-user-policy', 'attach-user-policy', 'create-login-profile') } | ForEach-Object Operation)
Assert (($writes -join ',') -eq 'create-user,put-user-policy,attach-user-policy,create-login-profile') 'Guard/admin/login creation order is unsafe.'
Assert (@(Calls | Where-Object { $_.Service -notin @('sts', 'iam') }).Count -eq 0) 'Block 1 used infrastructure services.'
Assert-InputCleanup
Clear-Content $env:BOOTSTRAP_TEST_LOG
& $bootstrap @options -Apply -Confirm:$false
Assert-NoWrites
Write-Host 'PASS IAM-only creation, private password transport, and idempotent resume'

$state = Read-State; $state.User.Tags[0].Value = 'SomeoneElse'; Save-State $state
Expect-Failure { & $bootstrap @options -Apply -Confirm:$false } 'unrelated IAM user'
Save-State $completed
$state = Read-State; $state.User.Tags[1].Value = 'old-version'; Save-State $state
Expect-Failure { & $bootstrap @options -Apply -Confirm:$false } 'configuration differs'
Save-State $completed
$state = Read-State; $state.Policy.Statement[0].Effect = 'Allow'; Save-State $state
Expect-Failure { & $bootstrap @options -Apply -Confirm:$false } 'MFA policy differs'
Assert-NoWrites
Reset-State; Set-FixtureCredentials
$state = Read-State; $state.PolicyFailure = $true; Save-State $state
Expect-Failure { & $bootstrap @options -Apply -OperatorPassword $password -Confirm:$false } 'policy failure'
Assert (@(Calls | Where-Object Operation -in @('attach-user-policy', 'create-login-profile')).Count -eq 0) 'Admin/access granted after guard failure.'
$state = Read-State; $state.PolicyFailure = $false; Save-State $state
& $bootstrap @options -Apply -OperatorPassword $password -Confirm:$false
Assert (@(Calls | Where-Object Operation -eq 'create-user').Count -eq 1) 'Retry recreated the user.'
Write-Host 'PASS foreign identity, policy drift, and interrupted bootstrap recovery'

. (Join-Path $awsRoot 'bootstrap/Native.ps1')
$request = @{ UserName = 'fixture'; Password = 'Fixture-only-password!42'; PasswordResetRequired = $true }
foreach ($mode in @('SensitiveFailure', 'SensitiveHang')) {
    Reset-State
    $state = Read-State; $state[$mode] = $true; Save-State $state
    $pattern = if ($mode -eq 'SensitiveFailure') { 'sensitive diagnostics suppressed' } else { 'time budget' }
    Expect-Failure { Invoke-BootstrapAws -Command @('iam', 'create-login-profile') -InputObject $request -SensitiveInput -TimeoutSeconds 2 } $pattern
    Assert-InputCleanup
}
Write-Host 'PASS sensitive error redaction and timeout cleanup'

# Disposable entry points/state, never the repository's Terraform state.
$deployRoot = Join-Path $testDirectory 'deploy'
New-Item -ItemType Directory -Path (Join-Path $deployRoot 'terraform') | Out-Null
foreach ($file in @('Deploy-Lab.ps1', 'Destroy-Lab.ps1', 'Common.ps1')) { Copy-Item (Join-Path $awsRoot $file) $deployRoot }
Copy-Item (Join-Path $awsRoot 'bootstrap') $deployRoot -Recurse
$deploy = Join-Path $deployRoot 'Deploy-Lab.ps1'
$deployOptions = @{ Owner = 'offline'; ExpectedAccountId = '123456789012'; AlertEmail = 'lab@example.invalid' }
Reset-State
& $deploy @deployOptions -OperatorLogin -WhatIf
Assert (@(Calls).Count -eq 0) 'WhatIf opened a login.'
Set-FixtureCredentials
Expect-Failure { & $deploy @deployOptions -OperatorLogin } 'Clear bootstrap'
Clear-Credentials
& $deploy @deployOptions -OperatorLogin
Assert-NoWrites
$state = Read-State
Assert ($state.Config['tinyevents-lab/credential_process'] -eq 'aws configure export-credentials --profile tinyevents-operator-login --format process') 'Login bridge not configured.'
& $deploy @deployOptions -Apply -WhatIf
Assert-NoWrites
& $deploy @deployOptions -Apply -Confirm:$false
Assert (@(Calls | Where-Object { $_.Service -eq 'terraform' -and $_.Operation -eq 'apply' }).Count -eq 1) 'Explicit apply missing.'
Write-Host 'PASS operator login bridge, Terraform preview, WhatIf, and explicit apply'

Reset-State
Expect-Failure { & $deploy @deployOptions -ExpectedAccountId '000000000000' -Apply -Confirm:$false } 'account mismatch'
Expect-Failure { & $deploy @deployOptions -Apply -Confirm:$false } 'requires the tinyevents-lab-operator'
$state = Read-State; $state.Arn = 'arn:aws:iam::123456789012:root'; Save-State $state
Expect-Failure { & $deploy @deployOptions -Apply -Confirm:$false } 'Root is not supported'
Assert-NoWrites
Reset-State
$state = Read-State; $state.Config['tinyevents-lab/credential_process'] = 'unrelated-helper'; Save-State $state
Expect-Failure { & $deploy @deployOptions -OperatorLogin } 'another credential process'
Assert (@(Calls | Where-Object Service -eq login).Count -eq 0) 'Conflicting profile opened login.'
Reset-State
$state = Read-State; $state.LoginArn = 'arn:aws:iam::123456789012:root'; Save-State $state
Expect-Failure { & $deploy @deployOptions -OperatorLogin } 'Wrong operator login'
Assert (@(Calls | Where-Object Service -eq terraform).Count -eq 0) 'Wrong login reached Terraform.'
Write-Host 'PASS wrong account/principal/root and conflicting login guards'

Reset-State; Set-FixtureCredentials
$state = Read-State; $state.Arn = $state.LoginArn; Save-State $state
& $deploy @deployOptions -AwsProfile ''
Assert-NoWrites
Assert (@(Calls | Where-Object { $_.Arguments -contains '--profile' }).Count -eq 0) 'Environment credentials were overridden by a profile.'
Assert-InputCleanup
Clear-Credentials
$state = Read-State; $state.Mfa = $false; Save-State $state
Expect-Failure { & $deploy @deployOptions -Apply -Confirm:$false } 'preflight failed'
Assert-NoWrites
Write-Host 'PASS operator environment mode and MFA/preflight failure'

Reset-State
$state = Read-State; $state.Arn = $state.LoginArn; $state.Quota = 4; Save-State $state
& $deploy @deployOptions -Apply -Confirm:$false
$state = Read-State
Assert ($state.QuotaRequested -and !$state.InstanceCreated) 'Low quota attempted compute creation.'
Assert (@(Calls | Where-Object { $_.Service -eq 'terraform' -and $_.Operation -eq 'output' }).Count -eq 0) 'Quota-only apply continued to deployment.'
$state.Quota = 16; Save-State $state
& $deploy @deployOptions
$plan = @(Calls | Where-Object { $_.Service -eq 'terraform' -and $_.Operation -eq 'plan' })[-1]
Assert ($plan.Arguments -contains 'standard_vcpu_quota=16') 'Larger existing quota was reduced.'
Write-Host 'PASS Terraform-only quota request and preservation of larger quota'

Reset-State
$state = Read-State; $state.Arn = $state.LoginArn; $state.PlanFailure = $true; Save-State $state
Expect-Failure { & $deploy @deployOptions -Apply -Confirm:$false } 'Terraform failed'
Assert-NoWrites
$destroy = Join-Path $deployRoot 'Destroy-Lab.ps1'
& $destroy -ExpectedAccountId '123456789012' -DeleteResults -WhatIf
Assert-NoWrites
Expect-Failure { & $destroy -ExpectedAccountId '000000000000' -Confirm:$false } 'must match'
& $destroy -ExpectedAccountId '123456789012' -Confirm:$false
$destroyCall = @(Calls | Where-Object Operation -eq destroy)[-1]
$expiryArgument = @($destroyCall.Arguments | Where-Object { $_ -like 'expires_at=*' })[0]
Assert ($expiryArgument -match '^expires_at=2020-01-01T00:00:00' -and [DateTimeOffset]::Parse($expiryArgument.Substring(11)).Year -eq 2020) 'Teardown did not retain expired RFC3339 configuration.'
Write-Host 'PASS failed plan and guarded teardown with expired configuration'
Write-Host 'All offline tests passed. Real AWS permissions, login/MFA semantics, and deployment remain unvalidated.'
