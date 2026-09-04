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
        [Parameter(Mandatory)][string]$AwsProfile,
        [Parameter(Mandatory)][string]$Region
    )

    Assert-CommandAvailable "aws"
    $identity = & aws sts get-caller-identity `
        --profile $AwsProfile `
        --region $Region `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw "AWS credentials could not be validated for profile '$AwsProfile'."
    }

    return $identity | ConvertFrom-Json
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

    return $json | ConvertFrom-Json
}

