param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(1, 60)]
    [int]$DurationSeconds = 10,

    [ValidateNotNullOrEmpty()]
    [int[]]$TargetRequestsPerSecond = @(200, 400, 800),

    [ValidateRange(1, 32)]
    [int]$WorkerCount = 4,

    [ValidateRange(1, 1000000)]
    [int]$EligibleHistoryCount = 50000,

    [ValidateRange(1, 50)]
    [int]$ConnectionPoolSize = 16
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\Database.ps1")
. (Join-Path $PSScriptRoot "support\Workers.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "support\Assertions.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-L06-cleanup-under-load.ps1")

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
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\cleanup-load\$runId"
$database = New-DogfoodDatabase $StorageProvider $composeFile
$connectionStringVariable = $database.ConnectionStringVariable
$connectionString =
    [Environment]::GetEnvironmentVariable($connectionStringVariable)
$boundedConnectionString =
    "$connectionString;$($database.PoolSizeSetting)=$ConnectionPoolSize;"
[Environment]::SetEnvironmentVariable(
    $connectionStringVariable,
    $boundedConnectionString)

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
Start-DogfoodDatabase $database
Invoke-Native "dotnet" @("build", $project, "-c", "Release")

$result = Invoke-TEL06CleanupUnderLoad `
    $assembly `
    $TargetRequestsPerSecond `
    $DurationSeconds `
    $WorkerCount `
    $EligibleHistoryCount `
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
    MaximumConnectionPoolSizePerProcess = $ConnectionPoolSize
    Result = $result
}

$manifest |
    ConvertTo-Json -Depth 14 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
$result.Rates |
    Select-Object `
        TargetRequestsPerSecond,
        @{ Name = "BaselineRps"; Expression = { $_.Baseline.PublisherLoad.CommittedRequestsPerSecond } },
        @{ Name = "CleanupRps"; Expression = { $_.Candidate.PublisherLoad.CommittedRequestsPerSecond } },
        @{ Name = "BaselineP95Ms"; Expression = { $_.Baseline.PublisherLoad.CommittedP95LatencyMilliseconds } },
        @{ Name = "CleanupP95Ms"; Expression = { $_.Candidate.PublisherLoad.CommittedP95LatencyMilliseconds } },
        @{ Name = "HistoryDeleted"; Expression = { $_.Candidate.EligibleHistoryDeleted } },
        AcceptancePassed |
    Format-Table

if (!$result.AcceptancePassed) {
    throw "Cleanup-under-load acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Cleanup-under-load acceptance completed. Evidence: $artifactDirectory"
