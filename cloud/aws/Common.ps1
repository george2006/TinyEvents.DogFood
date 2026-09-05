Set-StrictMode -Version Latest

function Assert-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)

    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH. See cloud/aws/README.md."
    }
}

function Get-TerraformDirectory {
    return Join-Path $PSScriptRoot "terraform"
}

function Assert-AwsIdentity {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$AwsProfile,
        [Parameter(Mandatory)][string]$Region
    )

    Assert-CommandAvailable "aws"
    $profileArguments = @(Get-AwsProfileArguments $AwsProfile)
    $identity = & aws sts get-caller-identity `
        @profileArguments `
        --region $Region `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw "AWS credentials could not be validated for profile '$AwsProfile'."
    }

    $parsedIdentity = $identity | ConvertFrom-Json
    if ($parsedIdentity.Arn -like '*:root') {
        throw 'Root is not supported for routine laboratory operations. Use the lab operator profile.'
    }
    return $parsedIdentity
}

function Get-AwsProfileArguments {
    param([AllowEmptyString()][string]$AwsProfile)
    if ($AwsProfile) {
        foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')) {
            if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
                throw 'Do not mix a named profile with AWS credential environment variables. Clear bootstrap credentials first.'
            }
        }
        return @('--profile', $AwsProfile)
    }
    foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Environment mode requires temporary credentials including $name."
        }
    }
    return @()
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$Arguments)

    Assert-CommandAvailable "terraform"
    $terraformDirectory = Get-TerraformDirectory
    & terraform "-chdir=$terraformDirectory" @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Terraform failed with exit code $LASTEXITCODE."
    }
}

function Get-LabTerraformOutput {
    Assert-CommandAvailable "terraform"
    $terraformDirectory = Get-TerraformDirectory
    $json = & terraform "-chdir=$terraformDirectory" output -json

    if ($LASTEXITCODE -ne 0) {
        throw "Terraform state is unavailable. Deploy the laboratory first."
    }

    $parsed = $json | ConvertFrom-Json
    # PowerShell can parse JSON ISO timestamps into DateTime automatically.
    # Preserve RFC3339 when passing the expiry back to Terraform (including
    # teardown after expiry), rather than interpolating a culture-specific date.
    if ($parsed.PSObject.Properties.Name -contains 'expires_at' -and $parsed.expires_at.value -is [DateTime]) {
        $parsed.expires_at.value = $parsed.expires_at.value.ToUniversalTime().ToString('O')
    }
    return $parsed
}
