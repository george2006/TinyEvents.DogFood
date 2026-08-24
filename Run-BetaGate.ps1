param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-GitCommit {
    param([string]$Repository)

    $commit = git -C $Repository rev-parse HEAD

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Git commit for $Repository."
    }

    return $commit.Trim()
}

function Assert-CleanRepository {
    param([string]$Repository)

    $changes = @(git -C $Repository status --porcelain)

    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the Git working tree for $Repository."
    }

    if ($changes.Count -gt 0) {
        throw "The beta gate requires a clean working tree: $Repository"
    }
}

function Invoke-GateCommand {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$ArtifactDirectory
    )

    $logPath = Join-Path $ArtifactDirectory "$Name.log"
    $startedAtUtc = [DateTimeOffset]::UtcNow

    Write-Host ""
    Write-Host "=== $Name ==="

    & $FilePath @Arguments 2>&1 |
        Tee-Object -FilePath $logPath |
        Out-Host

    $exitCode = $LASTEXITCODE
    $completedAtUtc = [DateTimeOffset]::UtcNow

    return [pscustomobject]@{
        Name = $Name
        Passed = $exitCode -eq 0
        ExitCode = $exitCode
        StartedAtUtc = $startedAtUtc.ToString("O")
        CompletedAtUtc = $completedAtUtc.ToString("O")
        DurationSeconds = [Math]::Round(
            ($completedAtUtc - $startedAtUtc).TotalSeconds,
            2)
        Log = $logPath
    }
}

function Write-GateResult {
    param(
        [string]$Path,
        [string]$Status,
        [string]$StartedAtUtc,
        [string]$DogfoodCommit,
        [string]$TinyEventsCommit,
        [System.Collections.Generic.List[object]]$Suites,
        [string]$Failure = ""
    )

    [pscustomobject]@{
        Status = $Status
        StartedAtUtc = $StartedAtUtc
        UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
        DogfoodCommit = $DogfoodCommit
        TinyEventsCommit = $TinyEventsCommit
        Failure = $Failure
        Suites = @($Suites)
    } |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-DogfoodSuite {
    param(
        [string]$Name,
        [string]$Script,
        [string[]]$Arguments = @()
    )

    return [pscustomobject]@{
        Name = $Name
        Script = $Script
        Arguments = $Arguments
    }
}

$dogfoodRoot = Resolve-Path $PSScriptRoot
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")

Assert-CleanRepository $dogfoodRoot
Assert-CleanRepository $tinyEventsRoot

$dogfoodCommit = Get-GitCommit $dogfoodRoot
$tinyEventsCommit = Get-GitCommit $tinyEventsRoot
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\beta-gate\$runId"
$resultPath = Join-Path $artifactDirectory "result.json"
$powerShellPath = (Get-Process -Id $PID).Path
$tinyEventsSolution = Join-Path $tinyEventsRoot "TinyEvents.sln"
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$packageSmoke = Join-Path `
    $tinyEventsRoot `
    "samples\TinyEvents.PackageSmoke\Test-PackageSmoke.ps1"

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

$env:TINYEVENTS_RUN_SQLSERVER_TESTS = "true"
$env:TINYEVENTS_RUN_POSTGRESQL_TESTS = "true"
$env:TINYEVENTS_PACKAGE_SMOKE_SQLSERVER =
    "Server=localhost,14333;Database=TinyEventsPackageSmoke;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"
$env:TINYEVENTS_PACKAGE_SMOKE_POSTGRESQL =
    "Host=localhost;Port=54323;Database=tinyevents_package_smoke;Username=postgres;Password=postgres;"

$powerShellArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File")
$postgreSqlArguments = @("-StorageProvider", "PostgreSql")
$suites = @(
    [pscustomobject]@{
        Name = "product-tests"
        FilePath = "dotnet"
        Arguments = @("test", $tinyEventsSolution, "-c", "Release")
    }
    New-DogfoodSuite -Name "identity" -Script "identity\Run-IdentityScenarios.ps1"
    New-DogfoodSuite -Name "baseline-sqlserver" -Script "operations\Run-OperationalBaseline.ps1"
    New-DogfoodSuite -Name "baseline-postgresql" -Script "operations\Run-OperationalBaseline.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "transactions-sqlserver" -Script "operations\Run-TransactionScenarios.ps1"
    New-DogfoodSuite -Name "transactions-postgresql" -Script "operations\Run-TransactionScenarios.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "worker-scaling-sqlserver" -Script "operations\Run-WorkerScaling.ps1"
    New-DogfoodSuite -Name "worker-recovery-sqlserver" -Script "operations\Run-WorkerRecovery.ps1"
    New-DogfoodSuite -Name "worker-recovery-postgresql" -Script "operations\Run-WorkerRecovery.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "database-recovery-sqlserver" -Script "operations\Run-DatabaseRecovery.ps1"
    New-DogfoodSuite -Name "database-recovery-postgresql" -Script "operations\Run-DatabaseRecovery.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "publishing-load-sqlserver" -Script "operations\Run-PublishingLoad.ps1"
    New-DogfoodSuite -Name "publishing-load-postgresql" -Script "operations\Run-PublishingLoad.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "worker-drain-sqlserver" -Script "operations\Run-WorkerDrainLoad.ps1"
    New-DogfoodSuite -Name "worker-drain-postgresql" -Script "operations\Run-WorkerDrainLoad.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "mixed-load-sqlserver" -Script "operations\Run-MixedLoad.ps1"
    New-DogfoodSuite -Name "mixed-load-postgresql" -Script "operations\Run-MixedLoad.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "backlog-recovery-sqlserver" -Script "operations\Run-BacklogRecoveryLoad.ps1"
    New-DogfoodSuite -Name "backlog-recovery-postgresql" -Script "operations\Run-BacklogRecoveryLoad.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "storage-measurements-sqlserver" -Script "operations\Run-StorageMeasurements.ps1"
    New-DogfoodSuite -Name "storage-measurements-postgresql" -Script "operations\Run-StorageMeasurements.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "storage-states-sqlserver" -Script "operations\Run-StorageStateMeasurements.ps1"
    New-DogfoodSuite -Name "storage-states-postgresql" -Script "operations\Run-StorageStateMeasurements.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "retained-history-sqlserver" -Script "operations\Run-RetainedHistoryLoad.ps1"
    New-DogfoodSuite -Name "retained-history-postgresql" -Script "operations\Run-RetainedHistoryLoad.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "cleanup-sqlserver" -Script "operations\Run-CleanupScenarios.ps1"
    New-DogfoodSuite -Name "cleanup-postgresql" -Script "operations\Run-CleanupScenarios.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "cleanup-load-sqlserver" -Script "operations\Run-CleanupUnderLoad.ps1"
    New-DogfoodSuite -Name "cleanup-load-postgresql" -Script "operations\Run-CleanupUnderLoad.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "disruption-soak-sqlserver" -Script "operations\Run-DisruptionSoak.ps1"
    New-DogfoodSuite -Name "disruption-soak-postgresql" -Script "operations\Run-DisruptionSoak.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "schema-sqlserver" -Script "deployment\Run-SchemaScenarios.ps1"
    New-DogfoodSuite -Name "schema-postgresql" -Script "deployment\Run-SchemaScenarios.ps1" -Arguments $postgreSqlArguments
    New-DogfoodSuite -Name "published-alpha-upgrade" -Script "deployment\Run-PublishedAlphaUpgrade.ps1"
    New-DogfoodSuite -Name "rolling-upgrade" -Script "deployment\Run-RollingUpgrade.ps1"
    [pscustomobject]@{ Name = "package-consumer"; FilePath = $powerShellPath; Arguments = $powerShellArguments + @($packageSmoke, "-Run") }
)

$results = [System.Collections.Generic.List[object]]::new()
Write-GateResult `
    -Path $resultPath `
    -Status "Running" `
    -StartedAtUtc $startedAtUtc `
    -DogfoodCommit $dogfoodCommit `
    -TinyEventsCommit $tinyEventsCommit `
    -Suites $results

try {
    docker info | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Docker is not available."
    }

    docker compose -f $composeFile up -d --wait sqlserver postgresql

    if ($LASTEXITCODE -ne 0) {
        throw "Could not start the TinyEvents databases."
    }

    foreach ($suite in $suites) {
        $hasScript = $suite.PSObject.Properties.Name -contains "Script"
        $hasArguments = $suite.PSObject.Properties.Name -contains "Arguments"

        if ($hasScript) {
            $scriptPath = Join-Path $dogfoodRoot $suite.Script
            $scriptArguments = if ($hasArguments) { $suite.Arguments } else { @() }
            $filePath = $powerShellPath
            $arguments = $powerShellArguments + @($scriptPath) + $scriptArguments
        }
        else {
            $filePath = $suite.FilePath
            $arguments = $suite.Arguments
        }

        if ($suite.Name -eq "package-consumer") {
            docker compose -f $composeFile up -d --wait sqlserver postgresql

            if ($LASTEXITCODE -ne 0) {
                throw "Could not prepare the package-consumer databases."
            }
        }

        $result = Invoke-GateCommand `
            -Name $suite.Name `
            -FilePath $filePath `
            -Arguments $arguments `
            -ArtifactDirectory $artifactDirectory

        $results.Add($result)

        Write-GateResult `
            -Path $resultPath `
            -Status "Running" `
            -StartedAtUtc $startedAtUtc `
            -DogfoodCommit $dogfoodCommit `
            -TinyEventsCommit $tinyEventsCommit `
            -Suites $results

        if (-not $result.Passed) {
            throw "Beta gate suite failed: $($suite.Name)"
        }
    }

    Write-GateResult `
        -Path $resultPath `
        -Status "Passed" `
        -StartedAtUtc $startedAtUtc `
        -DogfoodCommit $dogfoodCommit `
        -TinyEventsCommit $tinyEventsCommit `
        -Suites $results

    Write-Host ""
    Write-Host "TinyEvents beta gate passed. Evidence: $artifactDirectory"
}
catch {
    $failure = $_.Exception.Message

    Write-GateResult `
        -Path $resultPath `
        -Status "Failed" `
        -StartedAtUtc $startedAtUtc `
        -DogfoodCommit $dogfoodCommit `
        -TinyEventsCommit $tinyEventsCommit `
        -Suites $results `
        -Failure $failure

    Write-Host "TinyEvents beta gate failed: $failure"
    Write-Host "Evidence: $artifactDirectory"
    throw
}
