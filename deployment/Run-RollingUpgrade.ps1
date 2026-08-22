param(
    [string]$AlphaVersion = "0.1.0-alpha.3",
    [string]$CandidateRoot = "",
    [ValidateRange(2, 10000)]
    [int]$MessageCount = 100
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-TES05GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

function Get-TES05ProviderConfigurations {
    param([string]$DatabaseSuffix)

    return @(
        [pscustomobject]@{
            Name = "sqlserver"
            ConnectionVariable = "TINYEVENTS_DOGFOOD_UPGRADE_SQLSERVER"
            ConnectionString = "Server=localhost,14333;Database=TinyEventsDogfoodUpgrade_${DatabaseSuffix}_sqlserver;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"
        },
        [pscustomobject]@{
            Name = "postgresql"
            ConnectionVariable = "TINYEVENTS_DOGFOOD_UPGRADE_POSTGRESQL"
            ConnectionString = "Host=localhost;Port=54323;Database=TinyEventsDogfoodUpgrade_${DatabaseSuffix}_postgresql;Username=postgres;Password=postgres;"
        }
    )
}

function Get-TES05Observation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "Rolling-upgrade observation failed."
    }

    return $json | ConvertFrom-Json
}

function Test-TES05Backlog {
    param(
        [object]$Observation,
        [int]$ExpectedMessageCount
    )

    return (
        $Observation.MessageCount -eq $ExpectedMessageCount -and
        $Observation.PendingCount -eq $ExpectedMessageCount -and
        $Observation.ProcessingCount -eq 0 -and
        $Observation.ProcessedCount -eq 0 -and
        $Observation.FailedCount -eq 0 -and
        $Observation.MigrationCount -eq 1 -and
        $Observation.EffectCount -eq 0)
}

function Test-TES05CompletedState {
    param(
        [object]$Observation,
        [int]$ExpectedMessageCount,
        [string]$ExpectedEventType
    )

    return (
        $Observation.MessageCount -eq $ExpectedMessageCount -and
        $Observation.PendingCount -eq 0 -and
        $Observation.ProcessingCount -eq 0 -and
        $Observation.ProcessedCount -eq $ExpectedMessageCount -and
        $Observation.FailedCount -eq 0 -and
        $null -eq $Observation.FailedLastError -and
        $Observation.DistinctEventTypeCount -eq 1 -and
        $Observation.EventType -eq $ExpectedEventType -and
        $Observation.MigrationCount -eq 1 -and
        $Observation.EffectCount -eq $ExpectedMessageCount -and
        $Observation.DistinctOperationEffectCount -eq $ExpectedMessageCount -and
        $Observation.DistinctWorkerCount -eq 2)
}

function Complete-TES05Workers {
    param(
        [object]$AlphaWorker,
        [object]$CandidateWorker
    )

    $alphaOutputSaved = $false
    $candidateOutputSaved = $false

    try {
        Complete-LoggedProcess $AlphaWorker 120000
        $alphaOutputSaved = $true
        Complete-LoggedProcess $CandidateWorker 120000
        $candidateOutputSaved = $true
    }
    finally {
        if (!$alphaOutputSaved) {
            $null = Stop-LoggedProcess $AlphaWorker
        }

        if (!$candidateOutputSaved) {
            $null = Stop-LoggedProcess $CandidateWorker
        }
    }
}

function Invoke-TES05Provider {
    param(
        [object]$Provider,
        [string]$AlphaAssembly,
        [string]$CandidateAssembly,
        [string]$ArtifactDirectory,
        [int]$BacklogSize,
        [string]$ExpectedEventType
    )

    $providerDirectory = Join-Path $ArtifactDirectory $Provider.Name
    New-Item -ItemType Directory -Force -Path $providerDirectory | Out-Null
    $env:TINYEVENTS_DOGFOOD_UPGRADE_STORAGE = $Provider.Name
    [Environment]::SetEnvironmentVariable(
        $Provider.ConnectionVariable,
        $Provider.ConnectionString)

    Invoke-LoggedProcess `
        $AlphaAssembly `
        @("create-rolling-state", $BacklogSize) `
        $providerDirectory `
        "create-alpha-backlog"
    $beforeWorkers = Get-TES05Observation $AlphaAssembly
    $iterationCount = $BacklogSize * 2
    $effectDelayMilliseconds = 20
    $alphaWorker = Start-LoggedDotNetProcess `
        $AlphaAssembly `
        @(
            "process-rolling",
            "rolling-alpha",
            $iterationCount,
            $effectDelayMilliseconds) `
        $providerDirectory `
        "alpha-worker"
    $candidateWorker = $null

    try {
        $candidateWorker = Start-LoggedDotNetProcess `
            $CandidateAssembly `
            @(
                "process-rolling",
                "rolling-candidate",
                $iterationCount,
                $effectDelayMilliseconds) `
            $providerDirectory `
            "candidate-worker"

        Complete-TES05Workers $alphaWorker $candidateWorker
    }
    catch {
        if ($null -eq $candidateWorker) {
            $null = Stop-LoggedProcess $alphaWorker
        }

        throw
    }

    $afterWorkers = Get-TES05Observation $CandidateAssembly
    $backlogWasExact = Test-TES05Backlog $beforeWorkers $BacklogSize
    $completedStateWasExact = Test-TES05CompletedState `
        $afterWorkers `
        $BacklogSize `
        $ExpectedEventType
    $passed = $backlogWasExact -and $completedStateWasExact
    $result = [ordered]@{
        Provider = $Provider.Name
        BacklogWasExact = $backlogWasExact
        BothVersionsParticipated = $afterWorkers.DistinctWorkerCount -eq 2
        EveryMessageProducedOneDistinctEffect =
            $afterWorkers.EffectCount -eq $BacklogSize -and
            $afterWorkers.DistinctOperationEffectCount -eq $BacklogSize
        CompletedStateWasExact = $completedStateWasExact
        BeforeWorkers = $beforeWorkers
        AfterWorkers = $afterWorkers
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $providerDirectory "result.json")
    return [pscustomobject]$result
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$operationsSupport = Join-Path $dogfoodRoot "operations\support\Process.ps1"
. $operationsSupport

if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    $CandidateRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
}

$CandidateRoot = (Resolve-Path $CandidateRoot).Path
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$databaseSuffix = $runId.Replace('-', '')
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$publishedUpgradeRunner = Join-Path $PSScriptRoot "Run-PublishedAlphaUpgrade.ps1"
$deploymentDirectory = Join-Path $dogfoodRoot "artifacts\deployment\$runId"
$packageDirectory = Join-Path $deploymentDirectory "TE-S02"
$scenarioDirectory = Join-Path $deploymentDirectory "TE-S05"
$alphaAssembly = Join-Path `
    $packageDirectory `
    "alpha-bin\TinyEvents.Dogfood.AlphaUpgrade.dll"
$candidateAssembly = Join-Path `
    $packageDirectory `
    "candidate-bin\TinyEvents.Dogfood.AlphaUpgrade.dll"
$expectedEventType =
    "TinyEvents.Dogfood.AlphaUpgrade.Contracts.UpgradeProbeEvent"

& $publishedUpgradeRunner `
    -AlphaVersion $AlphaVersion `
    -CandidateRoot $CandidateRoot `
    -RunId $runId

New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null
$providerConfigurations = Get-TES05ProviderConfigurations $databaseSuffix
$providerResults = foreach ($provider in $providerConfigurations) {
    Invoke-TES05Provider `
        $provider `
        $alphaAssembly `
        $candidateAssembly `
        $scenarioDirectory `
        $MessageCount `
        $expectedEventType
}

$passed =
    $providerResults.Count -eq $providerConfigurations.Count -and
    @($providerResults | Where-Object { !$_.AcceptancePassed }).Count -eq 0
$result = [ordered]@{
    Scenario = "TE-S05"
    Contract = "Published alpha and clean-main application versions safely process one shared backlog"
    AlphaVersion = $AlphaVersion
    CandidateGitCommit = Get-TES05GitCommit $CandidateRoot
    MessageCountPerProvider = $MessageCount
    ProviderResults = $providerResults
    AcceptancePassed = $passed
}
$result |
    ConvertTo-Json -Depth 10 |
    Set-Content (Join-Path $scenarioDirectory "result.json")

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-TES05GitCommit $dogfoodRoot
    CandidateGitCommit = Get-TES05GitCommit $CandidateRoot
    AlphaVersion = $AlphaVersion
    DotNetSdk = (dotnet --version)
    Result = $result
}
$manifest |
    ConvertTo-Json -Depth 12 |
    Set-Content (Join-Path $scenarioDirectory "manifest.json")

$providerResults | Format-Table Provider, AcceptancePassed

if (!$passed) {
    throw "TE-S05 rolling-upgrade acceptance failed. Evidence: $scenarioDirectory"
}

Write-Host "TE-S05 rolling-upgrade acceptance completed for SQL Server and PostgreSQL."
Write-Host "Evidence: $scenarioDirectory"
