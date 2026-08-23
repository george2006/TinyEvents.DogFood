param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(20, 2000)]
    [int]$TargetRequestsPerSecond = 200,

    [ValidateRange(30, 600)]
    [int]$DurationSeconds = 120,

    [ValidateRange(1, 5000)]
    [int]$SlowDelayMilliseconds = 100,

    [ValidateRange(1000, 500000)]
    [int]$EligibleHistoryCount = 50000,

    [ValidateRange(1, 30)]
    [int]$OutageDurationSeconds = 5,

    [ValidateRange(2, 60)]
    [int]$ResourceSampleIntervalSeconds = 10,

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
. (Join-Path $PSScriptRoot "scenarios\TE-L07-disruption-soak.ps1")

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
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\soak\$runId"
$database = New-DogfoodDatabase $StorageProvider $composeFile
$connectionStringVariable = $database.ConnectionStringVariable
$connectionString =
    [Environment]::GetEnvironmentVariable($connectionStringVariable)
$boundedConnectionString =
    "$connectionString;" +
    "$($database.PoolSizeSetting)=$ConnectionPoolSize;" +
    "$($database.ConnectionTimeoutSetting)=1;"
[Environment]::SetEnvironmentVariable(
    $connectionStringVariable,
    $boundedConnectionString)
$usesContractConfiguration =
    $TargetRequestsPerSecond -eq 200 -and
    $DurationSeconds -eq 120 -and
    $SlowDelayMilliseconds -eq 100 -and
    $EligibleHistoryCount -eq 50000 -and
    $OutageDurationSeconds -eq 5 -and
    $ResourceSampleIntervalSeconds -eq 10 -and
    $ConnectionPoolSize -eq 16

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null
Start-DogfoodDatabase $database
Invoke-Native "dotnet" @("build", $project, "-c", "Release")

$result = Invoke-TEL07DisruptionSoak `
    $assembly `
    $database `
    $TargetRequestsPerSecond `
    $DurationSeconds `
    $SlowDelayMilliseconds `
    $EligibleHistoryCount `
    $OutageDurationSeconds `
    $ResourceSampleIntervalSeconds `
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
    ConnectionTimeoutSeconds = 1
    UsesContractConfiguration = $usesContractConfiguration
    Result = $result
}

$manifest |
    ConvertTo-Json -Depth 18 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
[pscustomobject]@{
    TargetRequestsPerSecond = $result.TargetRequestsPerSecond
    DurationSeconds = $result.DurationSeconds
    AcknowledgedCommittedRequests = $result.AcknowledgedCommittedRequests
    DurableCommittedRequests = $result.DurableCommittedRequests
    AmbiguousCommitCount = $result.AmbiguousCommitCount
    InterruptedFailureRecordingCount =
        $result.InterruptedFailureRecordingCount
    FailedRequests = @(
        $result.PublisherResults.Values |
            ForEach-Object { $_.FailedRequests } |
            Measure-Object -Sum).Sum
    WorkerDeaths = $result.WorkerDeaths.Count
    DatabaseOutages = $result.DatabaseOutages.Count
    DistinctEffects = $result.DistinctEffects
    DuplicateEffects = $result.DuplicateEffects
    ResourceSamples = $result.ResourceSamples.Count
    UsesContractConfiguration = $usesContractConfiguration
    AcceptancePassed = $result.AcceptancePassed
} | Format-List

if (!$result.AcceptancePassed) {
    throw "Disruption soak acceptance failed. Evidence: $artifactDirectory"
}

$completion = if ($usesContractConfiguration) {
    "TE-L07 contract acceptance completed"
}
else {
    "TE-L07 development run completed; contract configuration was not used"
}
Write-Host "$completion. Evidence: $artifactDirectory"
