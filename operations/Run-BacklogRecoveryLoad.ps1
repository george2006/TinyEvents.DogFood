param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(20, 2000)]
    [int]$TargetRequestsPerSecond = 200,

    [ValidateRange(5, 60)]
    [int]$DurationSeconds = 20,

    [ValidateRange(10, 100000)]
    [int]$BacklogTarget = 1000,

    [ValidateRange(1, 32)]
    [int]$WorkerCount = 4,

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
. (Join-Path $PSScriptRoot "scenarios\TE-L04-live-backlog-recovery.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$expectedRequestCount = $TargetRequestsPerSecond * $DurationSeconds

if ($BacklogTarget -ge $expectedRequestCount) {
    throw "Backlog target must be smaller than the total requested operation count."
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

$result = Invoke-TEL04LiveBacklogRecovery `
    $assembly `
    $TargetRequestsPerSecond `
    $DurationSeconds `
    $BacklogTarget `
    $WorkerCount `
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
    ConvertTo-Json -Depth 12 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
[pscustomobject]@{
    TargetRequestsPerSecond = $result.TargetRequestsPerSecond
    BacklogAtWorkerStart = $result.BacklogAtWorkerStart
    WorkerCount = $result.WorkerCount
    BacklogRecoveryThreshold = $result.BacklogRecoveryThreshold
    RecoveredWhilePublishing = $result.RecoveredWhilePublishing
    RecoveryDurationMilliseconds = $result.RecoveryDurationMilliseconds
    AllWorkersParticipated = $result.AllWorkersParticipated
    AcceptancePassed = $result.AcceptancePassed
} | Format-List

if (!$result.AcceptancePassed) {
    throw "Live backlog recovery acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Live backlog recovery acceptance completed. Evidence: $artifactDirectory"
