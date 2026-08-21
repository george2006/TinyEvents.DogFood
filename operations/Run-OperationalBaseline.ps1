param(
    [ValidateSet("SqlServer", "PostgreSql")]
    [string]$StorageProvider = "SqlServer",

    [ValidateRange(1, 100000)]
    [int]$WorkerBacklog = 100
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-LoggedProcess {
    param(
        [string]$Assembly,
        [string[]]$Arguments,
        [string]$ArtifactDirectory,
        [string]$Name
    )

    $standardOutput = Join-Path $ArtifactDirectory "$Name.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$Name.stderr.log"
    $process = Start-Process `
        -FilePath "dotnet" `
        -ArgumentList (@($Assembly) + $Arguments) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Operational command '$Name' failed with exit code $($process.ExitCode)."
    }
}

function Wait-ForDatabase {
    param(
        [string]$ContainerName,
        [string]$Description
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $health = docker inspect --format "{{.State.Health.Status}}" $ContainerName 2>$null

        if ($LASTEXITCODE -eq 0 -and $health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "$Description did not become healthy within two minutes."
}

function Get-Observation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "Operational observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Wait-ForDrain {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [int]$ExpectedCount
    )

    $deadline = (Get-Date).AddMinutes(1)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Operational worker exited before draining the backlog. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.ProcessedMessages -eq $ExpectedCount -and
            $observation.Effects -eq $ExpectedCount -and
            $observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Operational worker did not drain $ExpectedCount messages within one minute."
}

function Invoke-BaselineScenario {
    param(
        [pscustomobject]$Definition,
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory $Definition.Id
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess `
        -Assembly $Assembly `
        -Arguments @("reset") `
        -ArtifactDirectory $scenarioDirectory `
        -Name "reset"
    Invoke-LoggedProcess `
        -Assembly $Assembly `
        -Arguments @("publish", $Definition.Id, [string]$Definition.Count) `
        -ArtifactDirectory $scenarioDirectory `
        -Name "publish"

    $before = Get-Observation -Assembly $Assembly
    $workerOutput = Join-Path $scenarioDirectory "worker.stdout.log"
    $workerError = Join-Path $scenarioDirectory "worker.stderr.log"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $worker = Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @($Assembly, "worker", "$($Definition.Id)-worker") `
        -RedirectStandardOutput $workerOutput `
        -RedirectStandardError $workerError `
        -WindowStyle Hidden `
        -PassThru

    try {
        $after = Wait-ForDrain `
            -Assembly $Assembly `
            -Worker $worker `
            -ExpectedCount $Definition.Count
    }
    finally {
        $stopwatch.Stop()

        if (-not $worker.HasExited) {
            Stop-Process -Id $worker.Id
            $worker.WaitForExit()
        }
    }

    $passed =
        $before.BusinessOperations -eq $Definition.Count -and
        $before.OutboxMessages -eq $Definition.Count -and
        $before.PendingMessages -eq $Definition.Count -and
        $before.Effects -eq 0 -and
        $after.BusinessOperations -eq $Definition.Count -and
        $after.OutboxMessages -eq $Definition.Count -and
        $after.ProcessedMessages -eq $Definition.Count -and
        $after.FailedMessages -eq 0 -and
        $after.FailedAttempts -eq 0 -and
        $after.Effects -eq $Definition.Count -and
        $after.DuplicateEffects -eq 0

    $result = [ordered]@{
        Scenario = $Definition.Id
        Description = $Definition.Description
        ExpectedCount = $Definition.Count
        DurationMilliseconds = $stopwatch.ElapsedMilliseconds
        BeforeWorker = $before
        AfterWorker = $after
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Get-GitCommit {
    param([string]$Repository)

    return (git -C $Repository rev-parse HEAD).Trim()
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$project = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Operations\TinyEvents.Dogfood.Operations.csproj"
$assembly = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Operations\bin\Release\net8.0\TinyEvents.Dogfood.Operations.dll"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\operations\$runId"

$database = switch ($StorageProvider) {
    "SqlServer" {
        $env:TINYEVENTS_DOGFOOD_STORAGE = "sqlserver"
        $env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodOperations;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

        [pscustomobject]@{
            ComposeService = "sqlserver"
            ContainerName = "tinyevents-sqlserver"
            Description = "SQL Server 2022 Docker"
        }
    }
    "PostgreSql" {
        $env:TINYEVENTS_DOGFOOD_STORAGE = "postgresql"
        $env:TINYEVENTS_DOGFOOD_POSTGRESQL = "Host=localhost;Port=54323;Database=TinyEventsDogfoodOperations;Username=postgres;Password=postgres;"

        [pscustomobject]@{
            ComposeService = "postgresql"
            ContainerName = "tinyevents-postgresql"
            Description = "PostgreSQL 16 Docker"
        }
    }
}

$definitions = @(
    [pscustomobject]@{ Id = "TE-T01"; Description = "Business transaction commits"; Count = 10 },
    [pscustomobject]@{ Id = "TE-W01"; Description = "One worker drains a known backlog"; Count = $WorkerBacklog }
)

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

Invoke-Native "docker" @(
    "compose",
    "-f",
    $composeFile,
    "up",
    "-d",
    $database.ComposeService)
Wait-ForDatabase `
    -ContainerName $database.ContainerName `
    -Description $database.Description
Invoke-Native "dotnet" @("build", $project, "-c", "Release", "--nologo")

$results = foreach ($definition in $definitions) {
    Invoke-BaselineScenario `
        -Definition $definition `
        -Assembly $assembly `
        -ArtifactDirectory $artifactDirectory
}

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-GitCommit -Repository $dogfoodRoot
    TinyEventsGitCommit = Get-GitCommit -Repository $tinyEventsRoot
    DotNetSdk = (dotnet --version)
    DatabaseEngine = $database.Description
    Scenarios = $results
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, ExpectedCount, DurationMilliseconds, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "One or more operational baselines violated the beta acceptance contract. Evidence: $artifactDirectory"
}

Write-Host "Operational baseline completed. Evidence: $artifactDirectory"
