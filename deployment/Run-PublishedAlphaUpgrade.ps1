param(
    [string]$AlphaVersion = "0.1.0-alpha.3"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Wait-ForSqlServer {
    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $health = docker inspect --format "{{.State.Health.Status}}" tinyevents-sqlserver 2>$null

        if ($LASTEXITCODE -eq 0 -and $health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "SQL Server did not become healthy within two minutes."
}

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$project = Join-Path $PSScriptRoot "TinyEvents.Dogfood.AlphaUpgrade\TinyEvents.Dogfood.AlphaUpgrade.csproj"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$scenarioDirectory = Join-Path $dogfoodRoot "artifacts\deployment\$runId\TE-S02"
$packageCache = Join-Path $scenarioDirectory "alpha-package-cache"
$intermediateOutput = Join-Path $scenarioDirectory "alpha-obj\"
$buildOutput = Join-Path $scenarioDirectory "alpha-bin\"
$nugetConfig = Join-Path $scenarioDirectory "NuGet.alpha.config"
$assembly = Join-Path $buildOutput "TinyEvents.Dogfood.AlphaUpgrade.dll"
$databaseName = "TinyEventsDogfoodUpgrade_$($runId.Replace('-', ''))"
$env:TINYEVENTS_DOGFOOD_UPGRADE_SQLSERVER =
    "Server=localhost,14333;Database=$databaseName;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"
$env:NUGET_PACKAGES = $packageCache

New-Item -ItemType Directory -Force -Path $scenarioDirectory, $packageCache | Out-Null

@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@ | Set-Content -LiteralPath $nugetConfig -Encoding UTF8

Invoke-Native "docker" @("compose", "-f", $composeFile, "up", "-d", "sqlserver")
Wait-ForSqlServer

Invoke-Native "dotnet" @(
    "restore",
    $project,
    "--configfile",
    $nugetConfig,
    "--no-cache",
    "--force",
    "/p:TinyEventsPackageVersion=$AlphaVersion",
    "/p:BaseIntermediateOutputPath=$intermediateOutput")
Invoke-Native "dotnet" @(
    "build",
    $project,
    "-c",
    "Release",
    "--no-restore",
    "/p:TinyEventsPackageVersion=$AlphaVersion",
    "/p:BaseIntermediateOutputPath=$intermediateOutput",
    "/p:OutputPath=$buildOutput")

Invoke-Native "dotnet" @($assembly, "create-alpha-state")
$observationJson = & dotnet $assembly inspect

if ($LASTEXITCODE -ne 0) {
    throw "Alpha state inspection failed."
}

$observation = $observationJson | ConvertFrom-Json
$expectedEventType = "TinyEvents.Dogfood.AlphaUpgrade.Contracts.UpgradeProbeEvent"
$resolvedAlphaPackages = @(
    "TinyEvents/$AlphaVersion",
    "TinyEvents.SqlServer.AdoNet/$AlphaVersion"
)
$allAlphaPackagesResolved = $true

foreach ($package in $resolvedAlphaPackages) {
    $packagePath = Join-Path $packageCache $package.ToLowerInvariant().Replace('/', '\')
    $allAlphaPackagesResolved =
        $allAlphaPackagesResolved -and
        (Test-Path -LiteralPath $packagePath)
}

$acceptancePassed =
    $allAlphaPackagesResolved -and
    $observation.MessageCount -eq 3 -and
    $observation.PendingCount -eq 1 -and
    $observation.ProcessingCount -eq 1 -and
    $observation.ReclaimableProcessingCount -eq 1 -and
    $observation.ProcessedCount -eq 0 -and
    $observation.FailedCount -eq 1 -and
    $observation.FailedAttemptCount -eq 1 -and
    $observation.DistinctEventTypeCount -eq 1 -and
    $observation.EventType -eq $expectedEventType -and
    $observation.MigrationCount -eq 1 -and
    $observation.EffectCount -eq 0

$result = [ordered]@{
    Scenario = "TE-S02-A"
    Contract = "Published alpha creates representative in-flight state"
    AlphaVersion = $AlphaVersion
    PackageSource = "nuget.org"
    ResolvedPackages = $resolvedAlphaPackages
    Actual = $observation
    AcceptancePassed = $acceptancePassed
    TeS02Complete = $false
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $scenarioDirectory "result.json")

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-GitCommit $dogfoodRoot
    AlphaVersion = $AlphaVersion
    DotNetSdk = (dotnet --version)
    DatabaseEngine = "SQL Server 2022 Docker"
    Result = $result
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $scenarioDirectory "manifest.json")

if (!$acceptancePassed) {
    throw "Published alpha state violated TE-S02-A acceptance. Evidence: $scenarioDirectory"
}

Write-Host "TE-S02-A alpha state acceptance completed."
Write-Host "TE-S02 remains incomplete until the candidate migrates and drains this state."
Write-Host "Evidence: $scenarioDirectory"
