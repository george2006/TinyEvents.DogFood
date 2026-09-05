#requires -Version 7.4
# Block 2 helper, not a third setup entry point. Stores configuration, not keys.
function Initialize-OperatorLogin {
    param([string]$ExpectedAccountId, [string]$Region)
    . (Join-Path $PSScriptRoot 'Native.ps1')
    foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')) {
        if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw 'Clear bootstrap AWS credential environment variables before operator login.'
        }
    }
    $loginProfile = 'tinyevents-operator-login'
    $toolProfile = 'tinyevents-lab'
    $bridge = "aws configure export-credentials --profile $loginProfile --format process"
    foreach ($selectedProfile in @($loginProfile, $toolProfile)) {
        foreach ($key in @('aws_access_key_id', 'aws_secret_access_key', 'aws_session_token', 'role_arn', 'source_profile', 'credential_source', 'sso_session', 'sso_start_url')) {
            $value = Invoke-BootstrapAws -Command @('configure', 'get', $key) -Profile $selectedProfile -Region $Region -AllowMissing -RawOutput
            if ($value) { throw "Profile '$selectedProfile' has conflicting credential configuration. Use a clean lab profile; nothing was overwritten." }
        }
        $existingBridge = Invoke-BootstrapAws -Command @('configure', 'get', 'credential_process') -Profile $selectedProfile -Region $Region -AllowMissing -RawOutput
        if ($existingBridge -and ($selectedProfile -eq $loginProfile -or $existingBridge -ne $bridge)) { throw "Profile '$selectedProfile' is already configured for another credential process." }
        $session = Invoke-BootstrapAws -Command @('configure', 'get', 'login_session') -Profile $selectedProfile -Region $Region -AllowMissing -RawOutput
        if ($session -and ($selectedProfile -eq $toolProfile -or $session -ne "arn:aws:iam::${ExpectedAccountId}:user/tinyevents-lab-operator")) { throw "Profile '$selectedProfile' belongs to another login identity." }
    }
    Write-Host 'Sign in as tinyevents-lab-operator with MFA in the browser, not as root.'
    & aws login --profile $loginProfile --region $Region --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw 'Operator login failed. No Terraform actions were taken.' }
    $identity = Invoke-BootstrapAws -Command @('sts', 'get-caller-identity') -Profile $loginProfile -Region $Region
    if ($identity.Account -ne $ExpectedAccountId -or $identity.Arn -ne "arn:aws:iam::${ExpectedAccountId}:user/tinyevents-lab-operator") {
        throw 'Wrong operator login. Sign out of that profile; no Terraform actions were taken.'
    }
    Invoke-BootstrapAws -Command @('configure', 'set', 'credential_process', $bridge) -Profile $toolProfile -Region $Region -RawOutput | Out-Null
    Invoke-BootstrapAws -Command @('configure', 'set', 'region', $Region) -Profile $toolProfile -Region $Region -RawOutput | Out-Null
}
