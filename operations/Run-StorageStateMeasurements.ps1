param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(100, 100000)]
    [int]$RowCount = 5000,

    [ValidateRange(0, 1048576)]
    [int]$ContentCharacterCount = 1024,

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
. (Join-Path $PSScriptRoot "scenarios\TE-L05-storage-states.ps1")

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

$result = Invoke-TEL05StorageStateMeasurements `
    $assembly `
    $RowCount `
    $ContentCharacterCount `
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
    ConvertTo-Json -Depth 10 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
$result.States |
    Select-Object `
        State,
        RowCount,
        PayloadBytesPerRow,
        TableAllocatedBytesPerRow,
        IndexAllocatedBytesPerRow,
        TotalAllocatedBytesPerRow,
        AcceptancePassed |
    Format-Table

if (!$result.AcceptancePassed) {
    throw "Storage state measurement acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Storage state measurement acceptance completed. Evidence: $artifactDirectory"
