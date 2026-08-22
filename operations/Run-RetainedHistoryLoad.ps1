param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateNotNullOrEmpty()]
    [int[]]$RetainedHistoryCounts = @(0, 10000, 100000),

    [ValidateRange(100, 100000)]
    [int]$ActiveBacklog = 1000,

    [ValidateRange(1, 32)]
    [int]$WorkerCount = 4,

    [ValidateRange(1, 1000)]
    [int]$WorkerBatchSize = 10,

    [ValidateRange(1, 50)]
    [int]$ConnectionPoolSize = 16
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\Database.ps1")
. (Join-Path $PSScriptRoot "support\Workers.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-L05-retained-history.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$invalidHistoryCounts = @(
    $RetainedHistoryCounts |
        Where-Object { $_ -lt 0 -or $_ -gt 1000000 })
$normalizedHistoryCounts = @(
    $RetainedHistoryCounts |
        Sort-Object -Unique)

if ($invalidHistoryCounts.Count -gt 0) {
    throw "Retained history counts must be between 0 and 1000000."
}

if ($normalizedHistoryCounts -notcontains 0) {
    throw "Retained history counts must include the empty-history baseline."
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

$result = Invoke-TEL05RetainedHistoryLoad `
    $assembly `
    $normalizedHistoryCounts `
    $ActiveBacklog `
    $WorkerCount `
    $WorkerBatchSize `
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
    WorkerBatchSize = $WorkerBatchSize
    Result = $result
}

$manifest |
    ConvertTo-Json -Depth 12 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
$result.Variants |
    Select-Object `
        RetainedHistoryCount,
        ActiveBacklog,
        ActiveDrainMessagesPerSecond,
        ThroughputComparedToEmptyHistoryPercentage,
        AcceptancePassed |
    Format-Table

if (!$result.AcceptancePassed) {
    throw "Retained-history acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Retained-history acceptance completed. Evidence: $artifactDirectory"
