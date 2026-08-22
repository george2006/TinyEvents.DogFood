param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(100, 100000)]
    [int]$RowCount = 10000,

    [ValidateNotNullOrEmpty()]
    [int[]]$ContentCharacterCounts = @(0, 1024, 16384)
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "support\Process.ps1")
. (Join-Path $PSScriptRoot "support\Database.ps1")
. (Join-Path $PSScriptRoot "scenarios\TE-L05-storage-measurements.ps1")

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$invalidContentCharacterCounts = @(
    $ContentCharacterCounts |
        Where-Object { $_ -lt 0 -or $_ -gt 1048576 })
$normalizedContentCharacterCounts = @(
    $ContentCharacterCounts |
        Sort-Object -Unique)

if ($invalidContentCharacterCounts.Count -gt 0) {
    throw "Content character counts must be between 0 and 1048576."
}

if ($normalizedContentCharacterCounts -notcontains 0) {
    throw "Content character counts must include the empty-content baseline."
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

$result = Invoke-TEL05StorageMeasurements `
    $assembly `
    $RowCount `
    $normalizedContentCharacterCounts `
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
    ConvertTo-Json -Depth 10 |
    Set-Content (Join-Path $artifactDirectory "manifest.json")
$result.Variants |
    Select-Object `
        ContentCharacterCount,
        RowCount,
        PayloadBytesPerRow,
        TableAllocatedBytesPerRow,
        IndexAllocatedBytesPerRow,
        TotalAllocatedBytesPerRow,
        AcceptancePassed |
    Format-Table

if (!$result.AcceptancePassed) {
    throw "Storage measurement acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Storage measurement acceptance completed. Evidence: $artifactDirectory"
