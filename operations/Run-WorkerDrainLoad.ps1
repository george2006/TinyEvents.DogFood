param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(100, 100000)]
    [int]$Backlog = 10000,

    [ValidateNotNullOrEmpty()]
    [int[]]$WorkerCounts = @(1, 2, 4, 8)
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\Database.ps1")
. (Join-Path $PSScriptRoot "support\Workers.ps1")
. (Join-Path $PSScriptRoot "support\Observations.ps1")
. (Join-Path $PSScriptRoot "support\Assertions.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-L02-prebuilt-backlog-drain.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$invalidWorkerCounts = @(
    $WorkerCounts |
        Where-Object { $_ -lt 1 -or $_ -gt 32 })
$normalizedWorkerCounts = @(
    $WorkerCounts |
        Sort-Object -Unique)

if ($invalidWorkerCounts.Count -gt 0) {
    throw "Worker counts must be between 1 and 32."
}

if ($normalizedWorkerCounts -notcontains 1) {
    throw "Worker counts must include the one-worker baseline."
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

$result = Invoke-TEL02PrebuiltBacklogDrain `
    $assembly `
    $normalizedWorkerCounts `
    $Backlog `
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
$result.Variants |
    Select-Object `
        WorkerCount,
        Backlog,
        DrainMessagesPerSecond,
        Speedup,
        ScalingEfficiencyPercentage,
        AllWorkersParticipated,
        AcceptancePassed |
    Format-Table

if (!$result.AcceptancePassed) {
    throw "Prebuilt backlog drain acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Prebuilt backlog drain acceptance completed. Evidence: $artifactDirectory"
