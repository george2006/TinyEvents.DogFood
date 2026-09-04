[CmdletBinding()]
param(
    [string]$AwsProfile = "default"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

Assert-CommandAvailable "git"
$output = Get-LabTerraformOutput
$region = $output.aws_region.value
$bucket = $output.results_bucket.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$repositories = @(
    [pscustomobject]@{ Name = "TinyEvents.Dogfood"; Root = $dogfoodRoot },
    [pscustomobject]@{ Name = "TinyEvents"; Root = $tinyEventsRoot }
)

foreach ($repository in $repositories) {
    $dirty = & git -C $repository.Root status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect repository '$($repository.Root)'."
    }

    if ($dirty) {
        throw "Repository '$($repository.Name)' must be clean before its exact commit can be staged."
    }
}

$temporaryDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "tinyevents-cloud-sources-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    $manifestRepositories = @()

    foreach ($repository in $repositories) {
        $commit = (& git -C $repository.Root rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Could not resolve commit for '$($repository.Name)'."
        }

        $archive = Join-Path $temporaryDirectory "$($repository.Name).zip"
        & git -C $repository.Root archive `
            --format=zip `
            "--output=$archive" `
            HEAD

        if ($LASTEXITCODE -ne 0) {
            throw "Could not archive '$($repository.Name)' at '$commit'."
        }

        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
        $key = "sources/$commit/$($repository.Name).zip"
        & aws s3 cp $archive "s3://$bucket/$key" `
            --profile $AwsProfile `
            --region $region `
            --only-show-errors

        if ($LASTEXITCODE -ne 0) {
            throw "Could not upload '$($repository.Name)' source archive."
        }

        $manifestRepositories += [ordered]@{
            Name = $repository.Name
            Commit = $commit
            Key = $key
            Sha256 = $hash
        }
    }

    $manifest = [ordered]@{
        CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        Repositories = $manifestRepositories
    }
    $manifestPath = Join-Path $temporaryDirectory "source-manifest.json"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath

    & aws s3 cp $manifestPath "s3://$bucket/sources/source-manifest.json" `
        --profile $AwsProfile `
        --region $region `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Could not upload the source manifest."
    }

    $manifest | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

