#requires -Version 7.4
# Non-secret recovery metadata for the supported local Terraform backend.
function Get-LocalLabState {
    if ($env:TF_WORKSPACE -and $env:TF_WORKSPACE -ne 'default') { throw 'Recovery supports only the default Terraform workspace.' }
    $workspaceFile = Join-Path (Get-TerraformDirectory) '.terraform/environment'
    if ((Test-Path -LiteralPath $workspaceFile) -and (Get-Content -LiteralPath $workspaceFile -Raw).Trim() -ne 'default') {
        throw 'Recovery supports only the default Terraform workspace.'
    }
    $backendFile = Join-Path (Get-TerraformDirectory) '.terraform/terraform.tfstate'
    if (Test-Path -LiteralPath $backendFile) {
        $metadata = Get-Content -LiteralPath $backendFile -Raw | ConvertFrom-Json -AsHashtable
        $backend = $metadata['backend']
        if ($backend -and ($backend.type -ne 'local' -or ($backend.config['path'] -and $backend.config['path'] -ne 'terraform.tfstate'))) {
            throw 'Recovery supports only the default local Terraform state path, not a custom or remote backend.'
        }
    }
    $path = Join-Path (Get-TerraformDirectory) 'terraform.tfstate'
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($state.version -ne 4) { throw 'Unsupported local Terraform state format. Restore/review state before continuing.' }
    return $state
}

function Get-LabDeploymentContext {
    $path = Join-Path (Get-TerraformDirectory) '.lab-context.json'
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $context = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($context.SchemaVersion -ne 1 -or !$context.Parameters) { throw 'Invalid laboratory recovery context; refusing to replace it.' }
    $allowed = @('expected_account_id', 'aws_region', 'owner', 'alert_email', 'monthly_budget_usd', 'standard_vcpu_quota', 'expires_at', 'instance_type', 'root_volume_size_gib', 'experiment_name')
    if (@($context.Parameters.Keys | Where-Object { $_ -notin $allowed }).Count -gt 0) { throw 'Recovery context contains unsupported parameters.' }
    foreach ($key in $allowed) {
        if (!$context.Parameters.ContainsKey($key)) { throw "Recovery context is missing $key." }
    }
    return $context
}

function Assert-LabStateContext {
    param($State, $Context, [string]$ExpectedAccountId, [string]$Region)
    if ($Context) {
        if ($Context.Parameters.expected_account_id -ne $ExpectedAccountId -or $Context.Parameters.aws_region -ne $Region) {
            throw 'Recovery context, account, and region must match. Use a separate workspace for another lab.'
        }
        if ($State -and $Context.StateLineage -and $Context.StateLineage -ne $State.lineage) {
            throw 'Terraform state lineage differs from the recovery context. Restore the matching pair before continuing.'
        }
    }
    if (!$State) { return }
    if ($State.outputs['account_id'] -and $State.outputs['account_id'].value -ne $ExpectedAccountId) { throw 'Terraform state account does not match.' }
    if ($State.outputs['aws_region'] -and $State.outputs['aws_region'].value -ne $Region) { throw 'Terraform state region does not match.' }
    # Check account-bearing managed-resource ARNs even when final outputs were
    # never persisted. S3 ARNs are global and do not contain an account ID.
    foreach ($resource in @($State.resources)) {
        if ($resource.mode -ne 'managed') { continue }
        foreach ($instance in @($resource.instances)) {
            $arn = $instance.attributes['arn']
            if ($arn -match '^arn:aws:[^:]+:([^:]*):([0-9]{12}):') {
                if ($Matches[2] -ne $ExpectedAccountId -or ($Matches[1] -and $Matches[1] -ne $Region)) {
                    throw 'A managed resource in Terraform state belongs to another account or region.'
                }
            }
        }
    }
}

function Save-LabDeploymentContext {
    param([Collections.IDictionary]$Parameters)
    $state = Get-LocalLabState
    $previous = Get-LabDeploymentContext
    Assert-LabStateContext -State $state -Context $previous -ExpectedAccountId $Parameters.expected_account_id -Region $Parameters.aws_region
    $context = [ordered]@{
        SchemaVersion = 1
        RecordedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        StateLineage = if ($state) { $state.lineage } else { $null }
        Parameters = $Parameters
    }
    $directory = Get-TerraformDirectory
    $temporary = Join-Path $directory ".lab-context.$([Guid]::NewGuid().ToString('N')).tmp"
    $destination = Join-Path $directory '.lab-context.json'
    try {
        $context | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        [IO.File]::Move($temporary, $destination, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Get-LabStateBucket {
    param($State)
    $buckets = @($State.resources | Where-Object { $_.mode -eq 'managed' -and $_.type -eq 'aws_s3_bucket' -and $_.name -eq 'results' })
    if ($buckets.Count -eq 0) { return $null }
    if ($buckets.Count -ne 1 -or @($buckets[0].instances).Count -ne 1) { throw 'Ambiguous results bucket in Terraform state; inspect it before teardown.' }
    return $buckets[0].instances[0].attributes
}

function Assert-BucketSettingPlan {
    param([string]$PlanPath)
    $json = & terraform "-chdir=$(Get-TerraformDirectory)" show -json $PlanPath
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect bucket settings plan; refusing to apply it.' }
    $plan = $json | ConvertFrom-Json -AsHashtable
    if ($plan.format_version -notmatch '^1\.') { throw 'Unsupported Terraform plan format; refusing to apply it.' }
    foreach ($change in @($plan['resource_changes'])) {
        if ($null -eq $change) { continue }
        $actions = @($change.change.actions)
        if ($actions.Count -eq 1 -and $actions[0] -in @('no-op', 'read')) { continue }
        if ($change.address -ne 'aws_s3_bucket.results' -or $actions.Count -ne 1 -or $actions[0] -ne 'update') {
            throw 'Bucket settings plan would create, delete, or change another resource. No recovery apply was performed.'
        }
    }
}
