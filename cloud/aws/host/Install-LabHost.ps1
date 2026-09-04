[CmdletBinding()]
param(
    [string]$DogfoodRoot = "/opt/tinyevents-lab/sources/TinyEvents.Dogfood",
    [string]$TinyEventsRoot = "/opt/tinyevents-lab/sources/TinyEvents"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (!$IsLinux) {
    throw "The cloud host installer supports Linux only."
}

$environmentFile = "/etc/tinyevents-lab/environment"
if (!(Test-Path -LiteralPath $environmentFile)) {
    throw "Laboratory environment file '$environmentFile' was not found."
}

$environmentValues = @{}
foreach ($line in Get-Content -LiteralPath $environmentFile) {
    if ($line -match "^([^=]+)=(.*)$") {
        $environmentValues[$Matches[1]] = $Matches[2]
    }
}

$resultsBucket = $environmentValues["LAB_RESULTS_BUCKET"]
if ([string]::IsNullOrWhiteSpace($resultsBucket)) {
    throw "LAB_RESULTS_BUCKET is missing from '$environmentFile'."
}

$secretDirectory = "/etc/tinyevents-lab/secrets"
New-Item -ItemType Directory -Force -Path $secretDirectory | Out-Null
$grafanaPasswordPath = Join-Path $secretDirectory "grafana-admin-password"
if (!(Test-Path -LiteralPath $grafanaPasswordPath)) {
    $passwordBytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
    [Convert]::ToBase64String($passwordBytes) |
        Set-Content -NoNewline -LiteralPath $grafanaPasswordPath
    & chmod 600 $grafanaPasswordPath
}

$tinyEventsCompose = Join-Path $TinyEventsRoot "docker-compose.yml"
$cloudCompose = Join-Path $DogfoodRoot "cloud/aws/host/docker-compose.cloud.yml"

& docker compose -f $tinyEventsCompose up -d postgresql
if ($LASTEXITCODE -ne 0) {
    throw "PostgreSQL container could not be started."
}

$databaseDeadline = [DateTimeOffset]::UtcNow.AddMinutes(3)
do {
    $databaseHealth = (& docker inspect --format "{{.State.Health.Status}}" tinyevents-postgresql 2>$null)
    if ($LASTEXITCODE -eq 0 -and $databaseHealth -eq "healthy") {
        break
    }

    Start-Sleep -Seconds 2
} while ([DateTimeOffset]::UtcNow -lt $databaseDeadline)

if ($databaseHealth -ne "healthy") {
    throw "PostgreSQL did not become healthy within three minutes."
}

& docker compose -f $cloudCompose up -d
if ($LASTEXITCODE -ne 0) {
    throw "The observability stack could not be started."
}

$project = Join-Path $DogfoodRoot "operations/TinyEvents.Dogfood.Operations/TinyEvents.Dogfood.Operations.csproj"
& dotnet build $project -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    throw "TinyEvents dogfood could not be built."
}

$smokeScript = Join-Path $DogfoodRoot "cloud/aws/host/Run-CloudSmoke.ps1"
$resultPath = & $smokeScript -DogfoodRoot $DogfoodRoot
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resultPath)) {
    throw "The cloud smoke test did not return an evidence path."
}

$runDirectory = Split-Path $resultPath -Parent
$runName = Split-Path $runDirectory -Leaf
& aws s3 cp $runDirectory "s3://$resultsBucket/runs/$runName/" --recursive --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Smoke evidence could not be uploaded to '$resultsBucket'."
}

"smoke-ready" | Set-Content -LiteralPath "/opt/tinyevents-lab/bootstrap-status"
Write-Output $resultPath

