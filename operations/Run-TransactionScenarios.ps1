param(
    [ValidateSet("all", "TE-T02")]
    [string]$Scenario = "all",

    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\Database.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-T02-business-transaction-rolls-back.ps1")

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
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\transactions\$runId"
$database = New-DogfoodDatabase $StorageProvider $composeFile

$scenarioRunners = [ordered]@{
    "TE-T02" = {
        Invoke-TET02BusinessTransactionRollsBack `
            $assembly `
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
Start-DogfoodDatabase $database
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
    DatabaseEngine = $database.Description
    RequestedScenario = $Scenario
    Results = $results
}

$manifest |
    ConvertTo-Json -Depth 10 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "Transaction acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Transaction acceptance completed. Evidence: $artifactDirectory"
