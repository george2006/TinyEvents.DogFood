param(
    [ValidateSet(
        "all",
        "TE-W03",
        "TE-W04",
        "TE-W05",
        "TE-W07",
        "TE-W08-idle",
        "TE-W08-active",
        "TE-W09",
        "TE-W10",
        "TE-W11",
        "TE-W12",
        "TE-W13")]
    [string]$Scenario = "all"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\SqlServer.ps1")
. (Join-Path $PSScriptRoot "support\Workers.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "support\Assertions.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W03-active-claim.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W04-worker-death-recovery.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W05-effect-before-death.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W07-long-consumer-lease-loss.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W08-idle-shutdown.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W08-active-shutdown.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W09-retry-survives-restart.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W10-transient-failure-recovers.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W11-permanent-failure-exhausts-retries.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W12-later-consumer-failure.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-W13-duplicate-worker-identity.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$project = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Operations\TinyEvents.Dogfood.Operations.csproj"
$assembly = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Operations\bin\Release\net8.0\TinyEvents.Dogfood.Operations.dll"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\workers\$runId\recovery"

$env:TINYEVENTS_DOGFOOD_STORAGE = "sqlserver"
$env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodOperations;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

$scenarioRunners = [ordered]@{
    "TE-W03" = { Invoke-TEW03ActiveClaim $assembly $artifactDirectory }
    "TE-W04" = { Invoke-TEW04WorkerDeathRecovery $assembly $artifactDirectory }
    "TE-W05" = { Invoke-TEW05EffectBeforeDeath $assembly $artifactDirectory }
    "TE-W07" = { Invoke-TEW07LongConsumerLeaseLoss $assembly $artifactDirectory }
    "TE-W08-idle" = { Invoke-TEW08IdleShutdown $assembly $artifactDirectory }
    "TE-W08-active" = { Invoke-TEW08ActiveShutdown $assembly $artifactDirectory }
    "TE-W09" = { Invoke-TEW09RetrySurvivesRestart $assembly $artifactDirectory }
    "TE-W10" = { Invoke-TEW10TransientFailureRecovers $assembly $artifactDirectory }
    "TE-W11" = { Invoke-TEW11PermanentFailureExhaustsRetries $assembly $artifactDirectory }
    "TE-W12" = { Invoke-TEW12LaterConsumerFailure $assembly $artifactDirectory }
    "TE-W13" = { Invoke-TEW13DuplicateWorkerIdentity $assembly $artifactDirectory }
}

$selectedScenarios = if ($Scenario -eq "all") {
    $scenarioRunners.Keys
}
else {
    @($Scenario)
}

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

Invoke-Native "docker" @("compose", "-f", $composeFile, "up", "-d", "sqlserver")
Wait-ForSqlServer
Invoke-Native "dotnet" @("build", $project, "-c", "Release", "--nologo")

$results = foreach ($scenarioName in $selectedScenarios) {
    & $scenarioRunners[$scenarioName]
}

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-GitCommit $dogfoodRoot
    TinyEventsGitCommit = Get-GitCommit $tinyEventsRoot
    DotNetSdk = (dotnet --version)
    DatabaseEngine = "SQL Server 2022 Docker"
    ClaimTimeoutMilliseconds = 5000
    RetryDelayMilliseconds = 3000
    RequestedScenario = $Scenario
    Results = $results
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "Worker recovery acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Worker recovery acceptance completed. Evidence: $artifactDirectory"
