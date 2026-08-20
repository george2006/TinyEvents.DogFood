param()

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

function Start-Worker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$ConsumerDelayMilliseconds,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @($Assembly, "worker", $WorkerId, [string]$ConsumerDelayMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Stop-Worker {
    param([System.Diagnostics.Process]$Worker)

    if ($null -ne $Worker -and -not $Worker.HasExited) {
        Stop-Process -Id $Worker.Id
        $Worker.WaitForExit()
    }
}

function Wait-ForSqlServer {
    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $health = docker inspect --format "{{.State.Health.Status}}" tinyevents-sqlserver 2>$null

        if ($LASTEXITCODE -eq 0 -and $health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "SQL Server did not become healthy within two minutes."
}

function Get-Observation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect

    if ($LASTEXITCODE -ne 0) {
        throw "Operational observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Save-Observation {
    param(
        [pscustomobject]$Observation,
        [string]$ArtifactDirectory,
        [string]$Name
    )

    $Observation | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ArtifactDirectory "$Name.json")
}

function Wait-ForClaim {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before claiming the message. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $claim = $observation.WorkerClaims.PSObject.Properties[$WorkerId]

        if ($observation.ProcessingMessages -eq 1 -and
            $observation.Effects -eq 0 -and
            $null -ne $claim -and
            $claim.Value -eq 1 -and
            $null -ne $observation.EarliestClaimExpiresAtUtc) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not claim the message within twenty seconds."
}

function Wait-ForCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before completing the message. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.Effects -eq 1 -and
            $observation.ProcessingMessages -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not complete the message within thirty seconds."
}

function Assert-WorkerOwnsResult {
    param(
        [pscustomobject]$Observation,
        [string]$WorkerId
    )

    $claim = $Observation.WorkerClaims.PSObject.Properties[$WorkerId]
    $effect = $Observation.WorkerEffects.PSObject.Properties[$WorkerId]

    return (
        $Observation.BusinessOperations -eq 1 -and
        $Observation.OutboxMessages -eq 1 -and
        $Observation.PendingMessages -eq 0 -and
        $Observation.ProcessingMessages -eq 0 -and
        $Observation.ProcessedMessages -eq 1 -and
        $Observation.FailedMessages -eq 0 -and
        $Observation.FailedAttempts -eq 0 -and
        $Observation.Effects -eq 1 -and
        $Observation.DuplicateEffects -eq 0 -and
        @($Observation.WorkerClaims.PSObject.Properties).Count -eq 1 -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq 1 -and
        $null -ne $claim -and
        $claim.Value -eq 1 -and
        $null -ne $effect -and
        $effect.Value -eq 1)
}

function Invoke-ActiveClaimScenario {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W03"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W03", "1") $scenarioDirectory "publish"

    $ownerId = "TE-W03-owner"
    $competitorId = "TE-W03-competitor"
    $owner = Start-Worker $Assembly $ownerId 3000 $scenarioDirectory
    $competitor = $null

    try {
        $claimed = Wait-ForClaim $Assembly $owner $ownerId
        Save-Observation $claimed $scenarioDirectory "claimed"

        $competitor = Start-Worker $Assembly $competitorId 0 $scenarioDirectory
        Start-Sleep -Milliseconds 500

        $protected = Get-Observation -Assembly $Assembly
        Save-Observation $protected $scenarioDirectory "protected"

        $claimExpiry = [DateTimeOffset]$protected.EarliestClaimExpiresAtUtc
        $databaseNow = [DateTimeOffset]$protected.DatabaseUtcNow
        $wasProtectedBeforeExpiry =
            $databaseNow -lt $claimExpiry -and
            $protected.ProcessingMessages -eq 1 -and
            $protected.Effects -eq 0 -and
            $null -eq $protected.WorkerClaims.PSObject.Properties[$competitorId]

        $completed = Wait-ForCompletion $Assembly $owner $ownerId
        Save-Observation $completed $scenarioDirectory "completed"
        $passed = $wasProtectedBeforeExpiry -and (Assert-WorkerOwnsResult $completed $ownerId)
    }
    finally {
        Stop-Worker $competitor
        Stop-Worker $owner
    }

    $result = [ordered]@{
        Scenario = "TE-W03"
        ClaimOwner = $ownerId
        Competitor = $competitorId
        ProtectedBeforeExpiry = $wasProtectedBeforeExpiry
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-WorkerDeathScenario {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W04"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W04", "1") $scenarioDirectory "publish"

    $deadWorkerId = "TE-W04-dead-owner"
    $recoveryWorkerId = "TE-W04-recovery"
    $deadWorker = Start-Worker $Assembly $deadWorkerId 30000 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $deadWorker $deadWorkerId
        Save-Observation $claimed $scenarioDirectory "claimed-before-kill"
        Stop-Worker $deadWorker

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 $scenarioDirectory
        Start-Sleep -Milliseconds 500

        if ($recoveryWorker.HasExited) {
            throw "Recovery worker exited while the dead owner's lease was active. Exit code: $($recoveryWorker.ExitCode)."
        }

        $beforeExpiry = Get-Observation -Assembly $Assembly
        Save-Observation $beforeExpiry $scenarioDirectory "protected-after-kill"

        $claimExpiry = [DateTimeOffset]$beforeExpiry.EarliestClaimExpiresAtUtc
        $databaseNow = [DateTimeOffset]$beforeExpiry.DatabaseUtcNow
        $wasProtectedBeforeExpiry =
            $databaseNow -lt $claimExpiry -and
            $beforeExpiry.ProcessingMessages -eq 1 -and
            $beforeExpiry.Effects -eq 0 -and
            $null -eq $beforeExpiry.WorkerClaims.PSObject.Properties[$recoveryWorkerId]

        $recoveryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = Wait-ForCompletion $Assembly $recoveryWorker $recoveryWorkerId
        $recoveryStopwatch.Stop()
        Save-Observation $completed $scenarioDirectory "recovered"

        $passed = $wasProtectedBeforeExpiry -and (Assert-WorkerOwnsResult $completed $recoveryWorkerId)
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $deadWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W04"
        DeadWorker = $deadWorkerId
        RecoveryWorker = $recoveryWorkerId
        ProtectedBeforeExpiry = $wasProtectedBeforeExpiry
        RecoveryDurationMilliseconds = $recoveryStopwatch.ElapsedMilliseconds
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
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
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\workers\$runId\recovery"

$env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodOperations;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

Invoke-Native "docker" @("compose", "-f", $composeFile, "up", "-d", "sqlserver")
Wait-ForSqlServer
Invoke-Native "dotnet" @("build", $project, "-c", "Release", "--nologo")

$results = @(
    Invoke-ActiveClaimScenario $assembly $artifactDirectory
    Invoke-WorkerDeathScenario $assembly $artifactDirectory
)

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-GitCommit $dogfoodRoot
    TinyEventsGitCommit = Get-GitCommit $tinyEventsRoot
    DotNetSdk = (dotnet --version)
    DatabaseEngine = "SQL Server 2022 Docker"
    ClaimTimeoutMilliseconds = 5000
    Results = $results
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, ProtectedBeforeExpiry, RecoveryDurationMilliseconds, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "Worker recovery acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Worker recovery acceptance completed. Evidence: $artifactDirectory"
