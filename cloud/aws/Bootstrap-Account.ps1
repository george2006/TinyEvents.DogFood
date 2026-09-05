#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9]{12}$')][string]$ExpectedAccountId,
    [ValidatePattern('^[a-z]{2}-[a-z]+-[0-9]+$')][string]$Region = 'eu-west-1',
    [switch]$AllowRootBootstrap,
    [switch]$Apply,
    [Security.SecureString]$OperatorPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'bootstrap/Native.ps1')
$operatorName = 'tinyevents-lab-operator'
$policyName = 'RequireMFA'
$adminPolicy = 'arn:aws:iam::aws:policy/AdministratorAccess'

# Explicit environment credentials only: no fallback to shared profiles or IMDS.
foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Set $name in this process environment. Never paste credential values into chat."
    }
}
function Invoke-AccountAws {
    param([string[]]$Command, [object]$InputObject, [switch]$AllowMissing, [switch]$SensitiveInput)
    Invoke-BootstrapAws -Command $Command -Region $Region -InputObject $InputObject `
        -AllowMissing:$AllowMissing -SensitiveInput:$SensitiveInput
}
function Normalize-Policy($document) {
    if ($document -is [string]) { $document = [Uri]::UnescapeDataString($document) | ConvertFrom-Json }
    function Sort-Value($value) {
        if ($null -eq $value) { return $null }
        if ($value -is [Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($value.Keys | Sort-Object)) { $result[$key] = Sort-Value $value[$key] }
            return $result
        }
        if ($value -is [array]) { return ,@($value | ForEach-Object { Sort-Value $_ }) }
        return $value
    }
    $parsed = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    Sort-Value $parsed | ConvertTo-Json -Depth 30 -Compress
}

$identity = Invoke-AccountAws @('sts', 'get-caller-identity')
if ($identity.Account -ne $ExpectedAccountId) { throw 'AWS account mismatch. No changes were made.' }
if ($identity.Arn -notlike 'arn:aws:*') { throw 'Only the commercial AWS partition is supported.' }
if ($identity.Arn -like '*:root') {
    if (!$AllowRootBootstrap) { throw 'Root requires explicit -AllowRootBootstrap for this initial setup only.' }
    if ([string]::IsNullOrWhiteSpace($env:AWS_SESSION_TOKEN)) { throw 'Root requires a temporary session token; permanent root access keys are not supported.' }
}
$policyText = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bootstrap/operator-mfa-policy.json') -Raw).Replace('ACCOUNT_ID', $ExpectedAccountId)
$policy = $policyText | ConvertFrom-Json
$policyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes((Normalize-Policy $policy)))).ToLowerInvariant()
$existing = Invoke-AccountAws @('iam', 'get-user', '--user-name', $operatorName) -AllowMissing
$existingPolicy = $null
$login = $null
$hasAdmin = $false
if ($null -ne $existing) {
    $tags = @()
    if ($existing.User.PSObject.Properties.Name -contains 'Tags') { $tags = @($existing.User.Tags) }
    if (@($tags | Where-Object { $_.Key -eq 'ManagedBy' -and $_.Value -eq 'TinyEventsBootstrap' }).Count -ne 1) {
        throw 'An unrelated IAM user owns the operator name; refusing to adopt it.'
    }
    if ($existing.User.Path -ne '/' -or @($tags | Where-Object { $_.Key -eq 'PolicySha256' -and $_.Value -eq $policyHash }).Count -ne 1) {
        throw 'Existing operator configuration differs. Review it explicitly; no automatic policy upgrade.'
    }
    $existingPolicy = Invoke-AccountAws @('iam', 'get-user-policy', '--user-name', $operatorName, '--policy-name', $policyName) -AllowMissing
    if ($null -ne $existingPolicy -and (Normalize-Policy $existingPolicy.PolicyDocument) -ne (Normalize-Policy $policy)) {
        throw 'Existing MFA policy differs. Refusing to overwrite it.'
    }
    $attached = Invoke-AccountAws @('iam', 'list-attached-user-policies', '--user-name', $operatorName)
    $hasAdmin = @($attached.AttachedPolicies | Where-Object PolicyArn -eq $adminPolicy).Count -gt 0
    $login = Invoke-AccountAws @('iam', 'get-login-profile', '--user-name', $operatorName) -AllowMissing
}
Write-Host "Account: $ExpectedAccountId; principal: $($identity.Arn)"
Write-Warning 'DEDICATED LAB ACCOUNT ONLY: the operator receives AdministratorAccess across the whole account, not just lab resources.'
Write-Host 'Block 1 creates only the IAM operator, its MFA policy, and console access. No CloudFormation, Terraform, budget, storage, or VM.'
if (!$Apply) { Write-Host 'Preview only. Run again with -Apply to confirm operator creation.'; return }
if (!$PSCmdlet.ShouldProcess("AWS account $ExpectedAccountId", "Create/resume administrator $operatorName")) { return }

# Validate the local password before any writes. On retry, never rotate a login.
if ($null -eq $login) {
    if ($null -eq $OperatorPassword) { $OperatorPassword = Read-Host 'Initial operator password (save in your password manager)' -AsSecureString }
    if ($OperatorPassword.Length -lt 14) { throw 'Use at least 14 characters. No changes were made.' }
}
if ($null -eq $existing) {
    Invoke-AccountAws @('iam', 'create-user') -InputObject @{
        UserName = $operatorName
        Tags = @(@{ Key = 'ManagedBy'; Value = 'TinyEventsBootstrap' }, @{ Key = 'PolicySha256'; Value = $policyHash })
    } | Out-Null
}
# Guard before admin/access. Partial failure is resumable; never delete a user
# automatically after a failure, as that identity might now be in use.
if ($null -eq $existingPolicy) {
    Invoke-AccountAws @('iam', 'put-user-policy') -InputObject @{
        UserName = $operatorName; PolicyName = $policyName; PolicyDocument = $policyText
    } | Out-Null
}
if (!$hasAdmin) {
    Invoke-AccountAws @('iam', 'attach-user-policy', '--user-name', $operatorName, '--policy-arn', $adminPolicy) | Out-Null
}
if ($null -eq $login) {
    $pointer = [IntPtr]::Zero
    $request = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($OperatorPassword)
        $request = @{ UserName = $operatorName; Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer); PasswordResetRequired = $true }
        Invoke-AccountAws @('iam', 'create-login-profile') -InputObject $request -SensitiveInput
    }
    finally {
        if ($null -ne $request) { $request.Password = $null }
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}
Write-Host "Operator ready: https://$ExpectedAccountId.signin.aws.amazon.com/console (user $operatorName)."
Write-Host 'Change the initial password, enroll MFA with device name tinyevents-lab-operator, and sign in again with MFA.'
Write-Host 'Clear the bootstrap environment credentials before Block 2. No operator access keys were created.'
Write-Host 'Block 2: Deploy-Lab.ps1 -OperatorLogin prepares login and Terraform. See cloud/aws/README.md.'
