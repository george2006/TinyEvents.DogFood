param(
    [string]$AlphaVersion = "0.1.0-alpha.3",
    [string]$CandidateRoot = ""
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

function Assert-CleanMainCandidate {
    param([string]$Repository)

    $branch = (git -C $Repository branch --show-current).Trim()

    if ($branch -ne "main") {
        throw "Candidate repository must be on main. Actual branch: '$branch'."
    }

    $changes = @(git -C $Repository status --porcelain)

    if ($changes.Count -gt 0) {
        throw "Candidate repository must be clean. Uncommitted paths: $($changes -join ', ')"
    }
}

function Test-PackagesResolved {
    param(
        [string]$PackageCache,
        [string[]]$Packages
    )

    foreach ($package in $Packages) {
        $packagePath = Join-Path $PackageCache $package.ToLowerInvariant().Replace('/', '\')

        if (!(Test-Path -LiteralPath $packagePath)) {
            return $false
        }
    }

    return $true
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tinyEventsInfrastructureRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")

if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    $CandidateRoot = $tinyEventsInfrastructureRoot
}

$CandidateRoot = (Resolve-Path $CandidateRoot).Path
Assert-CleanMainCandidate $CandidateRoot

$composeFile = Join-Path $tinyEventsInfrastructureRoot "docker-compose.yml"
$packageSmokeScript = Join-Path $CandidateRoot "samples\TinyEvents.PackageSmoke\Test-PackageSmoke.ps1"
$project = Join-Path $PSScriptRoot "TinyEvents.Dogfood.AlphaUpgrade\TinyEvents.Dogfood.AlphaUpgrade.csproj"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$scenarioDirectory = Join-Path $dogfoodRoot "artifacts\deployment\$runId\TE-S02"
$alphaPackageCache = Join-Path $scenarioDirectory "alpha-package-cache"
$alphaIntermediateOutput = Join-Path $scenarioDirectory "alpha-obj\"
$alphaBuildOutput = Join-Path $scenarioDirectory "alpha-bin\"
$alphaNugetConfig = Join-Path $scenarioDirectory "NuGet.alpha.config"
$alphaAssembly = Join-Path $alphaBuildOutput "TinyEvents.Dogfood.AlphaUpgrade.dll"
$candidateVersion = "0.1.0-local.upgrade.$($runId.Replace('-', ''))"
$candidatePackages = Join-Path $CandidateRoot "artifacts\package-smoke\$candidateVersion\packages"
$candidatePackageCache = Join-Path $scenarioDirectory "candidate-package-cache"
$candidateIntermediateOutput = Join-Path $scenarioDirectory "candidate-obj\"
$candidateBuildOutput = Join-Path $scenarioDirectory "candidate-bin\"
$candidateNugetConfig = Join-Path $scenarioDirectory "NuGet.candidate.config"
$candidateAssembly = Join-Path $candidateBuildOutput "TinyEvents.Dogfood.AlphaUpgrade.dll"
$databaseName = "TinyEventsDogfoodUpgrade_$($runId.Replace('-', ''))"
$seededFailure = "Seeded terminal failure from published alpha."
$expectedEventType = "TinyEvents.Dogfood.AlphaUpgrade.Contracts.UpgradeProbeEvent"
$resolvedAlphaPackages = @(
    "TinyEvents/$AlphaVersion",
    "TinyEvents.SqlServer.AdoNet/$AlphaVersion"
)
$resolvedCandidatePackages = @(
    "TinyEvents/$candidateVersion",
    "TinyEvents.SqlServer.AdoNet/$candidateVersion"
)

$env:TINYEVENTS_DOGFOOD_UPGRADE_SQLSERVER =
    "Server=localhost,14333;Database=$databaseName;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

New-Item -ItemType Directory -Force -Path `
    $scenarioDirectory, `
    $alphaPackageCache, `
    $candidatePackageCache | Out-Null

@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@ | Set-Content -LiteralPath $alphaNugetConfig -Encoding UTF8

Invoke-Native "docker" @("compose", "-f", $composeFile, "up", "-d", "sqlserver")
Wait-ForSqlServer

$env:NUGET_PACKAGES = $alphaPackageCache
Invoke-Native "dotnet" @(
    "restore",
    $project,
    "--configfile",
    $alphaNugetConfig,
    "--no-cache",
    "--force",
    "/p:TinyEventsPackageVersion=$AlphaVersion",
    "/p:BaseIntermediateOutputPath=$alphaIntermediateOutput")
Invoke-Native "dotnet" @(
    "build",
    $project,
    "-c",
    "Release",
    "--no-restore",
    "/p:TinyEventsPackageVersion=$AlphaVersion",
    "/p:BaseIntermediateOutputPath=$alphaIntermediateOutput",
    "/p:OutputPath=$alphaBuildOutput")

Invoke-Native "dotnet" @($alphaAssembly, "create-alpha-state")
$alphaObservationJson = & dotnet $alphaAssembly inspect

if ($LASTEXITCODE -ne 0) {
    throw "Alpha state inspection failed."
}

$alphaObservation = $alphaObservationJson | ConvertFrom-Json
$allAlphaPackagesResolved = Test-PackagesResolved `
    $alphaPackageCache `
    $resolvedAlphaPackages
$alphaAcceptancePassed =
    $allAlphaPackagesResolved -and
    $alphaObservation.MessageCount -eq 3 -and
    $alphaObservation.PendingCount -eq 1 -and
    $alphaObservation.ProcessingCount -eq 1 -and
    $alphaObservation.ReclaimableProcessingCount -eq 1 -and
    $alphaObservation.ProcessedCount -eq 0 -and
    $alphaObservation.FailedCount -eq 1 -and
    $alphaObservation.FailedAttemptCount -eq 1 -and
    $alphaObservation.FailedLastError -eq $seededFailure -and
    $alphaObservation.DistinctEventTypeCount -eq 1 -and
    $alphaObservation.EventType -eq $expectedEventType -and
    $alphaObservation.MigrationCount -eq 1 -and
    $alphaObservation.EffectCount -eq 0 -and
    $alphaObservation.DistinctEffectCount -eq 0

$alphaResult = [ordered]@{
    Stage = "TE-S02-A"
    Contract = "Published alpha creates representative in-flight state"
    AlphaVersion = $AlphaVersion
    PackageSource = "nuget.org"
    ResolvedPackages = $resolvedAlphaPackages
    Actual = $alphaObservation
    AcceptancePassed = $alphaAcceptancePassed
}
$alphaResult | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $scenarioDirectory "alpha-state.json")

if (!$alphaAcceptancePassed) {
    throw "Published alpha state violated TE-S02-A acceptance. Evidence: $scenarioDirectory"
}

& $packageSmokeScript -PackageVersion $candidateVersion

if ($LASTEXITCODE -ne 0) {
    throw "Candidate package smoke failed with exit code $LASTEXITCODE."
}

@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="TinyEventsCandidate" value="$candidatePackages" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@ | Set-Content -LiteralPath $candidateNugetConfig -Encoding UTF8

$env:NUGET_PACKAGES = $candidatePackageCache
Invoke-Native "dotnet" @(
    "restore",
    $project,
    "--configfile",
    $candidateNugetConfig,
    "--no-cache",
    "--force",
    "/p:TinyEventsPackageVersion=$candidateVersion",
    "/p:BaseIntermediateOutputPath=$candidateIntermediateOutput")
Invoke-Native "dotnet" @(
    "build",
    $project,
    "-c",
    "Release",
    "--no-restore",
    "/p:TinyEventsPackageVersion=$candidateVersion",
    "/p:BaseIntermediateOutputPath=$candidateIntermediateOutput",
    "/p:OutputPath=$candidateBuildOutput")

Invoke-Native "dotnet" @($candidateAssembly, "migrate-and-drain")
$candidateObservationJson = & dotnet $candidateAssembly inspect

if ($LASTEXITCODE -ne 0) {
    throw "Candidate state inspection failed."
}

$candidateObservation = $candidateObservationJson | ConvertFrom-Json
$allCandidatePackagesResolved = Test-PackagesResolved `
    $candidatePackageCache `
    $resolvedCandidatePackages
$candidateAcceptancePassed =
    $allCandidatePackagesResolved -and
    $candidateObservation.MessageCount -eq 3 -and
    $candidateObservation.PendingCount -eq 0 -and
    $candidateObservation.ProcessingCount -eq 0 -and
    $candidateObservation.ReclaimableProcessingCount -eq 0 -and
    $candidateObservation.ProcessedCount -eq 2 -and
    $candidateObservation.FailedCount -eq 1 -and
    $candidateObservation.FailedAttemptCount -eq 1 -and
    $candidateObservation.FailedLastError -eq $seededFailure -and
    $candidateObservation.DistinctEventTypeCount -eq 1 -and
    $candidateObservation.EventType -eq $expectedEventType -and
    $candidateObservation.MigrationCount -eq 1 -and
    $candidateObservation.EffectCount -eq 2 -and
    $candidateObservation.DistinctEffectCount -eq 2 -and
    $candidateObservation.PendingEffectCount -eq 1 -and
    $candidateObservation.ProcessingEffectCount -eq 1 -and
    $candidateObservation.FailedEffectCount -eq 0

$result = [ordered]@{
    Scenario = "TE-S02-B"
    Contract = "Clean main candidate migrates and drains supported published-alpha state"
    CandidateVersion = $candidateVersion
    CandidateGitCommit = Get-GitCommit $CandidateRoot
    PackageSource = $candidatePackages
    ResolvedPackages = $resolvedCandidatePackages
    AlphaState = $alphaResult
    Actual = $candidateObservation
    AcceptancePassed = $candidateAcceptancePassed
    SqlServerUpgradeComplete = $candidateAcceptancePassed
    TeS02Complete = $false
}
$result | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $scenarioDirectory "result.json")

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-GitCommit $dogfoodRoot
    CandidateGitCommit = Get-GitCommit $CandidateRoot
    AlphaVersion = $AlphaVersion
    CandidateVersion = $candidateVersion
    DotNetSdk = (dotnet --version)
    DatabaseEngine = "SQL Server 2022 Docker"
    Result = $result
}
$manifest | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $scenarioDirectory "manifest.json")

if (!$candidateAcceptancePassed) {
    throw "Candidate violated TE-S02-B acceptance. Evidence: $scenarioDirectory"
}

Write-Host "TE-S02-B SQL Server upgrade acceptance completed."
Write-Host "TE-S02 remains incomplete until the same contract passes against PostgreSQL."
Write-Host "Evidence: $scenarioDirectory"
