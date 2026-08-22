param(
    [ValidateSet("all", "TE-S01", "TE-S03", "TE-S04")]
    [string]$Scenario = "all",

    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$operationsDirectory = Join-Path $dogfoodRoot "operations"

. (Join-Path $operationsDirectory "support\Process.ps1")
. (Join-Path $operationsDirectory "support\Database.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-S01-concurrent-application-migrations.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-S03-interrupted-migration.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-S04-incompatible-schema.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$project = Join-Path $operationsDirectory "TinyEvents.Dogfood.Operations\TinyEvents.Dogfood.Operations.csproj"
$assembly = Join-Path $operationsDirectory "TinyEvents.Dogfood.Operations\bin\Release\net8.0\TinyEvents.Dogfood.Operations.dll"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\schema\$runId"
$database = New-DogfoodDatabase $StorageProvider $composeFile

$scenarioRunners = [ordered]@{
    "TE-S01" = {
        Invoke-TES01ConcurrentApplicationMigrations `
            $assembly `
            $artifactDirectory
    }
    "TE-S03" = {
        Invoke-TES03InterruptedMigration `
            $assembly `
            $artifactDirectory
    }
    "TE-S04" = {
        Invoke-TES04IncompatibleSchema `
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

$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "Schema acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Schema acceptance completed. Evidence: $artifactDirectory"
