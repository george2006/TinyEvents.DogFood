#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsLinux) { throw 'Run inside the documented offline Linux container.' }
$awsRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-recovery-tests-$([Guid]::NewGuid().ToString('N'))"
$deployRoot = Join-Path $testRoot 'deploy'
$terraformDirectory = Join-Path $deployRoot 'terraform'
New-Item -ItemType Directory -Path $terraformDirectory | Out-Null
foreach ($file in @('Deploy-Lab.ps1', 'Destroy-Lab.ps1', 'Common.ps1', 'DeploymentContext.ps1')) { Copy-Item (Join-Path $awsRoot $file) $deployRoot }
foreach ($name in @('aws', 'terraform')) {
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/bootstrap-command.ps1') (Join-Path $testRoot $name)
    & chmod 700 (Join-Path $testRoot $name)
}
$env:BOOTSTRAP_TEST_STATE = Join-Path $testRoot 'fixture.json'
$env:BOOTSTRAP_TEST_LOG = Join-Path $testRoot 'calls.jsonl'
$env:PATH = "$testRoot$([IO.Path]::PathSeparator)$env:PATH"
$env:AWS_CONFIG_FILE = Join-Path $testRoot 'no-config'
$env:AWS_SHARED_CREDENTIALS_FILE = Join-Path $testRoot 'no-credentials'
$env:AWS_ACCESS_KEY_ID = $null; $env:AWS_SECRET_ACCESS_KEY = $null; $env:AWS_SESSION_TOKEN = $null
$env:AWS_EC2_METADATA_DISABLED = 'true'
$statePath = Join-Path $terraformDirectory 'terraform.tfstate'
$contextPath = Join-Path $terraformDirectory '.lab-context.json'
function Assert($condition, $message) { if (!$condition) { throw $message } }
function Write-Json($value, $path) { $value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $path }
function Calls { Get-Content $env:BOOTSTRAP_TEST_LOG | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } }
function Clear-Calls { Set-Content $env:BOOTSTRAP_TEST_LOG '' }
function Expect-Failure([scriptblock]$action, [string]$pattern) {
    $message = $null
    try { & $action } catch { $message = $_.Exception.Message }
    Assert ($message -and $message -match $pattern) "Expected '$pattern', received '$message'."
}
function Assert-NoMutations {
    Assert (@(Calls | Where-Object { $_.Operation -in @('apply', 'destroy') }).Count -eq 0) 'Unsafe mutation was attempted.'
}
$localState = @{ version = 4; lineage = 'fixture-lineage'; outputs = @{}; resources = @(@{
    mode = 'managed'; type = 'aws_iam_role'; name = 'lab'
    instances = @(@{ attributes = @{ arn = 'arn:aws:iam::123456789012:role/partial-lab' } })
}) }
$fixture = @{
    Account = '123456789012'; Arn = 'arn:aws:iam::123456789012:user/tinyevents-lab-operator'
    Mfa = $true; Quota = 8; PlanFailure = $false; ApplyFailure = $true; QuotaOnlyPlan = $false
    TerraformState = $localState; BucketPlanAddress = 'aws_s3_bucket.results'; BucketPlanActions = @('update')
}
Write-Json $fixture $env:BOOTSTRAP_TEST_STATE
Clear-Calls
$deploy = Join-Path $deployRoot 'Deploy-Lab.ps1'
$destroy = Join-Path $deployRoot 'Destroy-Lab.ps1'
$options = @{ ExpectedAccountId = '123456789012'; Owner = 'offline'; AlertEmail = 'lab@example.invalid' }
& $deploy @options
Assert (!(Test-Path $contextPath)) 'Preview wrote recovery parameters.'
Expect-Failure { & $deploy @options -Apply -Confirm:$false } 'Terraform failed'
$context = Get-Content $contextPath -Raw | ConvertFrom-Json -AsHashtable
Assert ($context.StateLineage -eq 'fixture-lineage') 'Partial state lineage was not recorded.'
Assert ($context.Parameters.expected_account_id -eq '123456789012' -and !$context.Parameters.ContainsKey('aws_profile')) 'Recovery parameters contain the wrong identity or credentials configuration.'
Assert (@(Calls | Where-Object Operation -eq output).Count -eq 0) 'Failed apply required final outputs.'
$fixture.ApplyFailure = $false
Write-Json $fixture $env:BOOTSTRAP_TEST_STATE
Clear-Calls
& $destroy -ExpectedAccountId '123456789012' -DeleteResults -WhatIf
Assert-NoMutations
& $destroy -ExpectedAccountId '123456789012' -DeleteResults -Confirm:$false
Assert (@(Calls | Where-Object Operation -eq apply).Count -eq 0) 'Cleanup created a missing bucket.'
Assert (@(Calls | Where-Object Operation -eq destroy).Count -eq 1) 'Partial deployment did not reach teardown.'
Write-Host 'PASS interrupted apply records recovery inputs; missing bucket/outputs do not require creation'

Clear-Calls
$localState.lineage = 'different-state'; Write-Json $localState $statePath
Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -Confirm:$false } 'lineage differs'
$localState.lineage = 'fixture-lineage'
$localState.resources[0].instances[0].attributes.arn = 'arn:aws:iam::000000000000:role/wrong-account'
Write-Json $localState $statePath
Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -Confirm:$false } 'another account or region'
Assert-NoMutations
$localState.resources[0].instances[0].attributes.arn = 'arn:aws:iam::123456789012:role/partial-lab'
Write-Json $localState $statePath
Expect-Failure { & $deploy @options -Region us-east-1 -Apply -Confirm:$false } 'context, account, and region must match'
Assert-NoMutations
Write-Host 'PASS stale lineage, resource account, and cross-region guards'

$bucketResource = @{ mode = 'managed'; type = 'aws_s3_bucket'; name = 'results'; instances = @(@{
    attributes = @{ id = 'offline-bucket'; arn = 'arn:aws:s3:::offline-bucket'; force_destroy = $false }
}) }
$localState.resources += $bucketResource
Write-Json $localState $statePath
$fixture.TerraformState = $localState
foreach ($actions in @(@('create'), @('delete', 'create'))) {
    Clear-Calls
    $fixture.BucketPlanActions = $actions; Write-Json $fixture $env:BOOTSTRAP_TEST_STATE
    Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -DeleteResults -Confirm:$false } 'would create, delete, or change another resource'
    Assert-NoMutations
}
Clear-Calls
$fixture.BucketPlanActions = @('update'); $fixture.BucketPlanAddress = 'aws_instance.lab'; Write-Json $fixture $env:BOOTSTRAP_TEST_STATE
Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -DeleteResults -Confirm:$false } 'would create, delete, or change another resource'
Assert-NoMutations
Write-Host 'PASS bucket recovery rejects creation, replacement, and unrelated updates'

Clear-Calls
$fixture.BucketPlanAddress = 'aws_s3_bucket.results'; Write-Json $fixture $env:BOOTSTRAP_TEST_STATE
& $destroy -ExpectedAccountId '123456789012' -DeleteResults -Confirm:$false
Assert (@(Calls | Where-Object Operation -eq apply).Count -eq 1 -and @(Calls | Where-Object Operation -eq destroy).Count -eq 1) 'Authorized bucket setting update/teardown missing.'
Clear-Calls
$localState.resources[-1].instances[0].attributes.force_destroy = $true
Write-Json $localState $statePath
$fixture.TerraformState = $localState; Write-Json $fixture $env:BOOTSTRAP_TEST_STATE
& $destroy -ExpectedAccountId '123456789012' -Confirm:$false
$plan = @(Calls | Where-Object Operation -eq plan)[0]
Assert ($plan.Arguments -contains 'allow_results_bucket_destroy=false') 'Retry silently reused old evidence deletion permission.'
Assert (@(Calls | Where-Object Operation -eq apply).Count -eq 1) 'Old force_destroy permission was not reset.'
Write-Host 'PASS explicit deletion authorization and revocation on a protected retry'

Clear-Calls
Move-Item -LiteralPath $contextPath -Destination (Join-Path $terraformDirectory 'saved-context.json')
# The fixture returns complete legacy outputs: the original completion path stays supported.
& $destroy -ExpectedAccountId '123456789012' -WhatIf
Assert-NoMutations
Move-Item -LiteralPath $statePath -Destination (Join-Path $terraformDirectory 'saved-state.json')
Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -Confirm:$false } 'state is missing'
Assert-NoMutations
Write-Host 'PASS legacy completed outputs and missing-state fail-closed behavior'
Clear-Calls
$env:TF_WORKSPACE = 'another-lab'
Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -Confirm:$false } 'default Terraform workspace'
$env:TF_WORKSPACE = $null
$metadataDirectory = Join-Path $terraformDirectory '.terraform'
New-Item -ItemType Directory -Path $metadataDirectory | Out-Null
Write-Json @{ backend = @{ type = 's3'; config = @{} } } (Join-Path $metadataDirectory 'terraform.tfstate')
Expect-Failure { & $destroy -ExpectedAccountId '123456789012' -Confirm:$false } 'custom or remote backend'
Assert-NoMutations
Write-Host 'PASS alternate-workspace and backend rejection'
Write-Host 'All partial-deployment recovery tests passed (offline command doubles only).'
