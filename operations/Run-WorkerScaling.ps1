param(
    [ValidateRange(100, 100000)]
    [int]$Backlog = 1000
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

function Start-Workers {
    param(
        [string]$Assembly,
        [int]$WorkerCount,
        [string]$ArtifactDirectory
    )

    return @(
        for ($index = 1; $index -le $WorkerCount; $index++) {
            $workerId = "TE-W02-$WorkerCount-worker-$index"
            $standardOutput = Join-Path $ArtifactDirectory "$workerId.stdout.log"
            $standardError = Join-Path $ArtifactDirectory "$workerId.stderr.log"

            Start-Process `
                -FilePath "dotnet" `
                -ArgumentList @($Assembly, "worker", $workerId) `
                -RedirectStandardOutput $standardOutput `
                -RedirectStandardError $standardError `
                -WindowStyle Hidden `
                -PassThru
        }
    )
}

function Stop-Workers {
    param([System.Diagnostics.Process[]]$Workers)

    foreach ($worker in $Workers) {
        if (-not $worker.HasExited) {
            Stop-Process -Id $worker.Id
            $worker.WaitForExit()
        }
    }
}

function Wait-ForDrain {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [int]$ExpectedCount
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers | Where-Object { $_.HasExited } | Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Worker process $($exitedWorker.Id) exited before draining the backlog. Exit code: $($exitedWorker.ExitCode)."
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

    throw "Workers did not drain $ExpectedCount messages within two minutes."
}

function Invoke-WorkerScalingVariant {
    param(
        [int]$WorkerCount,
        [int]$Backlog,
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $variantDirectory = Join-Path $ArtifactDirectory "$WorkerCount-workers"
    New-Item -ItemType Directory -Force -Path $variantDirectory | Out-Null

    Invoke-LoggedProcess `
        -Assembly $Assembly `
        -Arguments @("reset") `
        -ArtifactDirectory $variantDirectory `
        -Name "reset"

    $workers = Start-Workers `
        -Assembly $Assembly `
        -WorkerCount $WorkerCount `
        -ArtifactDirectory $variantDirectory

    try {
        Start-Sleep -Seconds 1

        $exitedWorker = $workers | Where-Object { $_.HasExited } | Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Worker process $($exitedWorker.Id) exited before publishing began. Exit code: $($exitedWorker.ExitCode)."
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-LoggedProcess `
            -Assembly $Assembly `
            -Arguments @("publish", "TE-W02", [string]$Backlog) `
            -ArtifactDirectory $variantDirectory `
            -Name "publish"
        $observation = Wait-ForDrain `
            -Assembly $Assembly `
            -Workers $workers `
            -ExpectedCount $Backlog
        $stopwatch.Stop()
    }
    finally {
        Stop-Workers -Workers $workers
    }

    $claimProperties = @($observation.WorkerClaims.PSObject.Properties)
    $effectProperties = @($observation.WorkerEffects.PSObject.Properties)
    $claimingWorkers = $claimProperties.Count
    $effectWorkers = $effectProperties.Count
    $claimsMatchEffects = $true

    foreach ($claim in $claimProperties) {
        $effect = $observation.WorkerEffects.PSObject.Properties[$claim.Name]

        if ($null -eq $effect -or $effect.Value -ne $claim.Value) {
            $claimsMatchEffects = $false
            break
        }
    }

    $durationSeconds = [Math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
    $endToEndMessagesPerSecond = [Math]::Round($Backlog / $durationSeconds, 2)
    $passed =
        $observation.BusinessOperations -eq $Backlog -and
        $observation.OutboxMessages -eq $Backlog -and
        $observation.ProcessedMessages -eq $Backlog -and
        $observation.FailedMessages -eq 0 -and
        $observation.FailedAttempts -eq 0 -and
        $observation.Effects -eq $Backlog -and
        $observation.DuplicateEffects -eq 0 -and
        $claimingWorkers -eq $WorkerCount -and
        $effectWorkers -eq $WorkerCount -and
        $claimsMatchEffects

    $result = [ordered]@{
        Scenario = "TE-W02"
        WorkerCount = $WorkerCount
        ClaimingWorkers = $claimingWorkers
        EffectWorkers = $effectWorkers
        ClaimsMatchEffects = $claimsMatchEffects
        Backlog = $Backlog
        EndToEndDurationMilliseconds = $stopwatch.ElapsedMilliseconds
        EndToEndMessagesPerSecond = $endToEndMessagesPerSecond
        Observation = $observation
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $variantDirectory "result.json")
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
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\workers\$runId\TE-W02"

$env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodOperations;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

Invoke-Native "docker" @("compose", "-f", $composeFile, "up", "-d", "sqlserver")
Wait-ForSqlServer
Invoke-Native "dotnet" @("build", $project, "-c", "Release", "--nologo")

$results = foreach ($workerCount in @(2, 4, 8)) {
    Invoke-WorkerScalingVariant `
        -WorkerCount $workerCount `
        -Backlog $Backlog `
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
    DatabaseEngine = "SQL Server 2022 Docker"
    Scenario = "TE-W02"
    Results = $results
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table WorkerCount, ClaimingWorkers, EffectWorkers, Backlog, EndToEndDurationMilliseconds, EndToEndMessagesPerSecond, AcceptancePassed

if ($results.AcceptancePassed -contains $false) {
    throw "Competing-worker acceptance failed. Evidence: $artifactDirectory"
}

Write-Host "Competing-worker acceptance completed. Evidence: $artifactDirectory"
