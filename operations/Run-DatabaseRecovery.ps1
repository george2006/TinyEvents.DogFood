param(
    [ValidateSet("all", "TE-D01")]
    [string]$Scenario = "all"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\SqlServer.ps1")
. (Join-Path $PSScriptRoot "support\Workers.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "support\Assertions.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-D01-database-unavailable-at-startup.ps1")

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
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\database\$runId"

$env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodOperations;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

$scenarioRunners = [ordered]@{
    "TE-D01" = {
        Invoke-TED01DatabaseUnavailableAtStartup `
            $assembly `
            $composeFile `
            $artifactDirectory
    }
}

$selectedScenarios = if ($Scenario -eq "all") {
    @($scenarioRunners.Keys)
}
else {
    @($Scenario)
}

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
Start-SqlServer $composeFile
Invoke-Native "dotnet" @("build", $project, "-c", "Release")

$results = foreach ($scenarioId in $selectedScenarios) {
    & $scenarioRunners[$scenarioId]
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
    RequestedScenario = $Scenario
    Results = $results
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "Database recovery acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Database recovery acceptance completed. Evidence: $artifactDirectory"
