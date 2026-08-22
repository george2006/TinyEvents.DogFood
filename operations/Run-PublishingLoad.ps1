param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(1, 60)]
    [int]$DurationSeconds = 10,

    [ValidateNotNullOrEmpty()]
    [int[]]$TargetRequestsPerSecond = @(200, 400, 800)
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\Database.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-L01-sustained-publishing.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$invalidTargetRates = @(
    $TargetRequestsPerSecond |
        Where-Object { $_ -lt 1 -or $_ -gt 10000 })

if ($invalidTargetRates.Count -gt 0) {
    throw "Target request rates must be between 1 and 10000 requests per second."
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$project = Join-Path `
    $PSScriptRoot `
    "TinyEvents.Dogfood.Operations\TinyEvents.Dogfood.Operations.csproj"
$assembly = Join-Path `
    $PSScriptRoot `
    "TinyEvents.Dogfood.Operations\bin\Release\net8.0\TinyEvents.Dogfood.Operations.dll"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\load\$runId"
$database = New-DogfoodDatabase $StorageProvider $composeFile

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
Start-DogfoodDatabase $database
Invoke-Native "dotnet" @("build", $project, "-c", "Release")

$result = Invoke-TEL01SustainedPublishing `
    $assembly `
    $TargetRequestsPerSecond `
    $DurationSeconds `
    $artifactDirectory

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
    Result = $result
}

$manifest |
    ConvertTo-Json -Depth 12 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
$result.Rates |
    Select-Object `
        TargetRequestsPerSecond,
        AchievedTargetPercentage,
        TargetWasSustained,
        AllRequestsCommitted,
        DurableCountsAreExact,
        AcceptancePassed,
        @{ Name = "CommittedRequestsPerSecond"; Expression = { $_.Load.CommittedRequestsPerSecond } },
        @{ Name = "P95Milliseconds"; Expression = { $_.Load.CommittedP95LatencyMilliseconds } } |
    Format-Table

if (!$result.AcceptancePassed) {
    throw "Sustained publishing acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Sustained publishing acceptance completed. Evidence: $artifactDirectory"
