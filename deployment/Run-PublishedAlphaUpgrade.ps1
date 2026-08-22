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

function Wait-ForContainerHealth {
    param(
        [string]$ContainerName,
        [string]$DisplayName
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $health = docker inspect --format "{{.State.Health.Status}}" $ContainerName 2>$null

        if ($LASTEXITCODE -eq 0 -and $health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "$DisplayName did not become healthy within two minutes."
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

function Get-ProviderConfigurations {
    param([string]$DatabaseSuffix)

    return @(
        [pscustomobject]@{
            Name = "sqlserver"
            Checkpoint = "TE-S02-B"
            ContainerName = "tinyevents-sqlserver"
            DisplayName = "SQL Server"
            ConnectionVariable = "TINYEVENTS_DOGFOOD_UPGRADE_SQLSERVER"
            ConnectionString = "Server=localhost,14333;Database=TinyEventsDogfoodUpgrade_${DatabaseSuffix}_sqlserver;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"
        },
        [pscustomobject]@{
            Name = "postgresql"
            Checkpoint = "TE-S02-C"
            ContainerName = "tinyevents-postgresql"
            DisplayName = "PostgreSQL"
            ConnectionVariable = "TINYEVENTS_DOGFOOD_UPGRADE_POSTGRESQL"
            ConnectionString = "Host=localhost;Port=54323;Database=TinyEventsDogfoodUpgrade_${DatabaseSuffix}_postgresql;Username=postgres;Password=postgres;"
        }
    )
}

function Test-AlphaObservation {
    param(
        [object]$Observation,
        [string]$ExpectedEventType,
        [string]$ExpectedFailure
    )

    return (
        $Observation.MessageCount -eq 3 -and
        $Observation.PendingCount -eq 1 -and
        $Observation.ProcessingCount -eq 1 -and
        $Observation.ReclaimableProcessingCount -eq 1 -and
        $Observation.ProcessedCount -eq 0 -and
        $Observation.FailedCount -eq 1 -and
        $Observation.FailedAttemptCount -eq 1 -and
        $Observation.FailedLastError -eq $ExpectedFailure -and
        $Observation.DistinctEventTypeCount -eq 1 -and
        $Observation.EventType -eq $ExpectedEventType -and
        $Observation.MigrationCount -eq 1 -and
        $Observation.EffectCount -eq 0 -and
        $Observation.DistinctEffectCount -eq 0)
}

function Test-CandidateObservation {
    param(
        [object]$Observation,
        [string]$ExpectedEventType,
        [string]$ExpectedFailure
    )

    return (
        $Observation.MessageCount -eq 3 -and
        $Observation.PendingCount -eq 0 -and
        $Observation.ProcessingCount -eq 0 -and
        $Observation.ReclaimableProcessingCount -eq 0 -and
        $Observation.ProcessedCount -eq 2 -and
        $Observation.FailedCount -eq 1 -and
        $Observation.FailedAttemptCount -eq 1 -and
        $Observation.FailedLastError -eq $ExpectedFailure -and
        $Observation.DistinctEventTypeCount -eq 1 -and
        $Observation.EventType -eq $ExpectedEventType -and
        $Observation.MigrationCount -eq 1 -and
        $Observation.EffectCount -eq 2 -and
        $Observation.DistinctEffectCount -eq 2 -and
        $Observation.DistinctOperationEffectCount -eq 2 -and
        $Observation.DistinctWorkerCount -eq 1 -and
        $Observation.PendingEffectCount -eq 1 -and
        $Observation.ProcessingEffectCount -eq 1 -and
        $Observation.FailedEffectCount -eq 0)
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
$databaseSuffix = $runId.Replace('-', '')
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$scenarioDirectory = Join-Path $dogfoodRoot "artifacts\deployment\$runId\TE-S02"
$alphaPackageCache = Join-Path $scenarioDirectory "alpha-package-cache"
$alphaIntermediateOutput = Join-Path $scenarioDirectory "alpha-obj\"
$alphaBuildOutput = Join-Path $scenarioDirectory "alpha-bin\"
$alphaNugetConfig = Join-Path $scenarioDirectory "NuGet.alpha.config"
$alphaAssembly = Join-Path $alphaBuildOutput "TinyEvents.Dogfood.AlphaUpgrade.dll"
$candidateVersion = "0.1.0-local.upgrade.$databaseSuffix"
$candidatePackages = Join-Path $CandidateRoot "artifacts\package-smoke\$candidateVersion\packages"
$candidatePackageCache = Join-Path $scenarioDirectory "candidate-package-cache"
$candidateIntermediateOutput = Join-Path $scenarioDirectory "candidate-obj\"
$candidateBuildOutput = Join-Path $scenarioDirectory "candidate-bin\"
$candidateNugetConfig = Join-Path $scenarioDirectory "NuGet.candidate.config"
$candidateAssembly = Join-Path $candidateBuildOutput "TinyEvents.Dogfood.AlphaUpgrade.dll"
$seededFailure = "Seeded terminal failure from published alpha."
$expectedEventType = "TinyEvents.Dogfood.AlphaUpgrade.Contracts.UpgradeProbeEvent"
$providerConfigurations = Get-ProviderConfigurations $databaseSuffix
$resolvedAlphaPackages = @(
    "TinyEvents/$AlphaVersion",
    "TinyEvents.SqlServer.AdoNet/$AlphaVersion",
    "TinyEvents.PostgreSql.AdoNet/$AlphaVersion"
)
$resolvedCandidatePackages = @(
    "TinyEvents/$candidateVersion",
    "TinyEvents.SqlServer.AdoNet/$candidateVersion",
    "TinyEvents.PostgreSql.AdoNet/$candidateVersion"
)

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

Invoke-Native "docker" @(
    "compose",
    "-f",
    $composeFile,
    "up",
    "-d",
    "sqlserver",
    "postgresql")

foreach ($provider in $providerConfigurations) {
    Wait-ForContainerHealth $provider.ContainerName $provider.DisplayName
}

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

$allAlphaPackagesResolved = Test-PackagesResolved `
    $alphaPackageCache `
    $resolvedAlphaPackages
$allCandidatePackagesResolved = Test-PackagesResolved `
    $candidatePackageCache `
    $resolvedCandidatePackages
$providerResults = @()

foreach ($provider in $providerConfigurations) {
    $env:TINYEVENTS_DOGFOOD_UPGRADE_STORAGE = $provider.Name
    [Environment]::SetEnvironmentVariable(
        $provider.ConnectionVariable,
        $provider.ConnectionString)

    Invoke-Native "dotnet" @($alphaAssembly, "create-alpha-state")
    $alphaObservationJson = & dotnet $alphaAssembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "$($provider.DisplayName) alpha state inspection failed."
    }

    $alphaObservation = $alphaObservationJson | ConvertFrom-Json
    $alphaAcceptancePassed =
        $allAlphaPackagesResolved -and
        (Test-AlphaObservation `
            $alphaObservation `
            $expectedEventType `
            $seededFailure)
    $alphaResult = [ordered]@{
        Stage = "TE-S02-A"
        Provider = $provider.Name
        Contract = "Published alpha creates representative in-flight state"
        AlphaVersion = $AlphaVersion
        PackageSource = "nuget.org"
        ResolvedPackages = $resolvedAlphaPackages
        Actual = $alphaObservation
        AcceptancePassed = $alphaAcceptancePassed
    }
    $alphaResult | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (
            Join-Path $scenarioDirectory "$($provider.Name)-alpha-state.json")

    if (!$alphaAcceptancePassed) {
        throw "Published alpha state violated $($provider.Checkpoint) acceptance for $($provider.DisplayName). Evidence: $scenarioDirectory"
    }

    Invoke-Native "dotnet" @($candidateAssembly, "migrate-and-drain")
    $candidateObservationJson = & dotnet $candidateAssembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "$($provider.DisplayName) candidate state inspection failed."
    }

    $candidateObservation = $candidateObservationJson | ConvertFrom-Json
    $candidateAcceptancePassed =
        $allCandidatePackagesResolved -and
        (Test-CandidateObservation `
            $candidateObservation `
            $expectedEventType `
            $seededFailure)
    $providerResult = [pscustomobject][ordered]@{
        Checkpoint = $provider.Checkpoint
        Provider = $provider.Name
        Contract = "Clean main candidate migrates and drains supported published-alpha state"
        AlphaState = $alphaResult
        CandidateState = $candidateObservation
        AcceptancePassed = $candidateAcceptancePassed
    }
    $providerResults += $providerResult
    $providerResult | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (
            Join-Path $scenarioDirectory "$($provider.Name)-result.json")

    if (!$candidateAcceptancePassed) {
        throw "Candidate violated $($provider.Checkpoint) acceptance for $($provider.DisplayName). Evidence: $scenarioDirectory"
    }
}

$teS02Complete =
    $providerResults.Count -eq $providerConfigurations.Count -and
    @($providerResults | Where-Object { !$_.AcceptancePassed }).Count -eq 0
$result = [ordered]@{
    Scenario = "TE-S02"
    Contract = "Published alpha state remains supported across SQL Server and PostgreSQL upgrades"
    CandidateVersion = $candidateVersion
    CandidateGitCommit = Get-GitCommit $CandidateRoot
    PackageSource = $candidatePackages
    ResolvedPackages = $resolvedCandidatePackages
    ProviderResults = $providerResults
    AcceptancePassed = $teS02Complete
    SqlServerUpgradeComplete = @(
        $providerResults |
            Where-Object { $_.Provider -eq "sqlserver" -and $_.AcceptancePassed }
    ).Count -eq 1
    PostgreSqlUpgradeComplete = @(
        $providerResults |
            Where-Object { $_.Provider -eq "postgresql" -and $_.AcceptancePassed }
    ).Count -eq 1
    TeS02Complete = $teS02Complete
}
$result | ConvertTo-Json -Depth 10 |
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
    DatabaseEngines = @("SQL Server 2022 Docker", "PostgreSQL 16 Docker")
    Result = $result
}
$manifest | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath (Join-Path $scenarioDirectory "manifest.json")

if (!$teS02Complete) {
    throw "TE-S02 provider parity acceptance failed. Evidence: $scenarioDirectory"
}

Write-Host "TE-S02 published-alpha upgrade acceptance completed for SQL Server and PostgreSQL."
Write-Host "Evidence: $scenarioDirectory"
