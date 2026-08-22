param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(20, 2000)]
    [int]$TargetRequestsPerSecond = 200,

    [ValidateRange(5, 60)]
    [int]$DurationSeconds = 10,

    [ValidateRange(1, 32)]
    [int]$WorkerCount = 4,

    [ValidateRange(1, 5000)]
    [int]$SlowDelayMilliseconds = 100,

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
. (Join-Path $PSScriptRoot "scenarios\TE-L03-sustained-mixed-load.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
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

$result = Invoke-TEL03SustainedMixedLoad `
    $assembly `
    $TargetRequestsPerSecond `
    $DurationSeconds `
    $WorkerCount `
    $SlowDelayMilliseconds `
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
[pscustomobject]@{
    TargetRequestsPerSecond = $result.TargetRequestsPerSecond
    WorkerCount = $result.WorkerCount
    PublishingDurationMilliseconds = $result.PublishingDurationMilliseconds
    SettlementTailMilliseconds = $result.SettlementTailMilliseconds
    RetryPressureWasVisible = $result.RetryPressureWasVisible
    SuccessProgressedDuringRetries = $result.SuccessProgressedDuringRetries
    AllPublishersCommitted = $result.AllPublishersCommitted
    AllWorkersParticipated = $result.AllWorkersParticipated
    AcceptancePassed = $result.AcceptancePassed
} | Format-List

if (!$result.AcceptancePassed) {
    throw "Sustained mixed-load acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Sustained mixed-load acceptance completed. Evidence: $artifactDirectory"
