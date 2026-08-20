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
        [int]$BeforeEffectDelayMilliseconds,
        [int]$AfterEffectDelayMilliseconds,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @(
            $Assembly,
            "worker",
            $WorkerId,
            [string]$BeforeEffectDelayMilliseconds,
            [string]$AfterEffectDelayMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Start-TimedWorker {
    param(
        [string]$Assembly,
        [string]$WorkerId,
        [int]$RunDurationMilliseconds,
        [int]$BeforeEffectDelayMilliseconds,
        [int]$AfterEffectDelayMilliseconds,
        [string]$ArtifactDirectory
    )

    $standardOutput = Join-Path $ArtifactDirectory "$WorkerId.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$WorkerId.stderr.log"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "dotnet"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $startInfo.Arguments =
        "`"$Assembly`" worker-for `"$WorkerId`" " +
        "$RunDurationMilliseconds " +
        "$BeforeEffectDelayMilliseconds " +
        "$AfterEffectDelayMilliseconds"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Worker '$WorkerId' could not be started."
    }

    return [pscustomobject]@{
        Process = $process
        OutputPath = $standardOutput
        ErrorPath = $standardError
        OutputTask = $process.StandardOutput.ReadToEndAsync()
        ErrorTask = $process.StandardError.ReadToEndAsync()
    }
}

function Stop-Worker {
    param([System.Diagnostics.Process]$Worker)

    if ($null -ne $Worker -and -not $Worker.HasExited) {
        Stop-Process -Id $Worker.Id
        $Worker.WaitForExit()
    }
}

function Wait-ForWorkerExit {
    param(
        [pscustomobject]$WorkerHandle,
        [string]$WorkerId
    )

    $process = $WorkerHandle.Process

    if (-not $process.WaitForExit(15000)) {
        throw "Worker '$WorkerId' did not stop within fifteen seconds."
    }

    $process.WaitForExit()
    $process.Refresh()
    $standardOutput = $WorkerHandle.OutputTask.GetAwaiter().GetResult()
    $standardError = $WorkerHandle.ErrorTask.GetAwaiter().GetResult()
    $standardOutput | Set-Content $WorkerHandle.OutputPath
    $standardError | Set-Content $WorkerHandle.ErrorPath

    if ($process.ExitCode -ne 0) {
        throw "Worker '$WorkerId' stopped with exit code $($process.ExitCode)."
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

function Wait-ForEffectBeforeCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before persisting the consumer effect. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $claim = $observation.WorkerClaims.PSObject.Properties[$WorkerId]
        $effect = $observation.WorkerEffects.PSObject.Properties[$WorkerId]

        if ($observation.ProcessingMessages -eq 1 -and
            $observation.ProcessedMessages -eq 0 -and
            $observation.Effects -eq 1 -and
            $observation.DuplicateEffects -eq 0 -and
            $null -ne $claim -and
            $claim.Value -eq 1 -and
            $null -ne $effect -and
            $effect.Value -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not persist the consumer effect before completion within twenty seconds."
}

function Wait-ForDuplicateCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$Worker,
        [string]$WorkerId
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if ($Worker.HasExited) {
            throw "Worker '$WorkerId' exited before completing the redelivery. Exit code: $($Worker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.Effects -eq 2 -and
            $observation.DuplicateEffects -eq 1 -and
            $observation.ProcessingMessages -eq 0) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Worker '$WorkerId' did not complete the expected redelivery within thirty seconds."
}

function Wait-ForCompetingCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$OriginalWorker,
        [System.Diagnostics.Process]$CompetingWorker,
        [string]$OriginalWorkerId,
        [string]$CompetingWorkerId
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($OriginalWorker.HasExited) {
            throw "Original worker '$OriginalWorkerId' exited before its slow consumer completed. Exit code: $($OriginalWorker.ExitCode)."
        }

        if ($CompetingWorker.HasExited) {
            throw "Competing worker '$CompetingWorkerId' exited before completing the reclaimed message. Exit code: $($CompetingWorker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly
        $originalEffect = $observation.WorkerEffects.PSObject.Properties[$OriginalWorkerId]
        $competingClaim = $observation.WorkerClaims.PSObject.Properties[$CompetingWorkerId]
        $competingEffect = $observation.WorkerEffects.PSObject.Properties[$CompetingWorkerId]

        if ($observation.ProcessedMessages -eq 1 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.Effects -eq 1 -and
            $null -eq $originalEffect -and
            $null -ne $competingClaim -and
            $competingClaim.Value -eq 1 -and
            $null -ne $competingEffect -and
            $competingEffect.Value -eq 1) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Competing worker '$CompetingWorkerId' did not complete while '$OriginalWorkerId' remained active."
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
    $owner = Start-Worker $Assembly $ownerId 3000 0 $scenarioDirectory
    $competitor = $null

    try {
        $claimed = Wait-ForClaim $Assembly $owner $ownerId
        Save-Observation $claimed $scenarioDirectory "claimed"

        $competitor = Start-Worker $Assembly $competitorId 0 0 $scenarioDirectory
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
    $deadWorker = Start-Worker $Assembly $deadWorkerId 30000 0 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $deadWorker $deadWorkerId
        Save-Observation $claimed $scenarioDirectory "claimed-before-kill"
        Stop-Worker $deadWorker

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 0 $scenarioDirectory
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

function Invoke-EffectBeforeDeathScenario {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W05"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W05", "1") $scenarioDirectory "publish"

    $deadWorkerId = "TE-W05-dead-owner"
    $recoveryWorkerId = "TE-W05-recovery"
    $deadWorker = Start-Worker $Assembly $deadWorkerId 0 30000 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $effectPersisted = Wait-ForEffectBeforeCompletion $Assembly $deadWorker $deadWorkerId
        Save-Observation $effectPersisted $scenarioDirectory "effect-before-kill"
        Stop-Worker $deadWorker

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 0 $scenarioDirectory
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
            $beforeExpiry.ProcessedMessages -eq 0 -and
            $beforeExpiry.Effects -eq 1 -and
            $beforeExpiry.DuplicateEffects -eq 0 -and
            $null -eq $beforeExpiry.WorkerClaims.PSObject.Properties[$recoveryWorkerId]

        $completed = Wait-ForDuplicateCompletion $Assembly $recoveryWorker $recoveryWorkerId
        Save-Observation $completed $scenarioDirectory "redelivered"

        $deadWorkerEffect = $completed.WorkerEffects.PSObject.Properties[$deadWorkerId]
        $recoveryWorkerClaim = $completed.WorkerClaims.PSObject.Properties[$recoveryWorkerId]
        $recoveryWorkerEffect = $completed.WorkerEffects.PSObject.Properties[$recoveryWorkerId]
        $passed =
            $wasProtectedBeforeExpiry -and
            $completed.BusinessOperations -eq 1 -and
            $completed.OutboxMessages -eq 1 -and
            $completed.PendingMessages -eq 0 -and
            $completed.ProcessingMessages -eq 0 -and
            $completed.ProcessedMessages -eq 1 -and
            $completed.FailedMessages -eq 0 -and
            $completed.FailedAttempts -eq 0 -and
            $completed.Effects -eq 2 -and
            $completed.DuplicateEffects -eq 1 -and
            @($completed.WorkerEffects.PSObject.Properties).Count -eq 2 -and
            $null -ne $deadWorkerEffect -and
            $deadWorkerEffect.Value -eq 1 -and
            $null -ne $recoveryWorkerClaim -and
            $recoveryWorkerClaim.Value -eq 1 -and
            $null -ne $recoveryWorkerEffect -and
            $recoveryWorkerEffect.Value -eq 1
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $deadWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W05"
        DeadWorker = $deadWorkerId
        RecoveryWorker = $recoveryWorkerId
        ProtectedBeforeExpiry = $wasProtectedBeforeExpiry
        ConsumerInvocations = $completed.Effects
        DuplicateInvocations = $completed.DuplicateEffects
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-LongConsumerScenario {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W07"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W07", "1") $scenarioDirectory "publish"

    $slowWorkerId = "TE-W07-slow-owner"
    $competingWorkerId = "TE-W07-competitor"
    $slowWorker = Start-Worker $Assembly $slowWorkerId 10000 0 $scenarioDirectory
    $competingWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $slowWorker $slowWorkerId
        Save-Observation $claimed $scenarioDirectory "slow-consumer-claimed"

        $competingWorker = Start-Worker $Assembly $competingWorkerId 0 0 $scenarioDirectory
        $competingCompletion = Wait-ForCompetingCompletion `
            $Assembly `
            $slowWorker `
            $competingWorker `
            $slowWorkerId `
            $competingWorkerId
        Save-Observation $competingCompletion $scenarioDirectory "competitor-completed"

        $bothInvocationsCompleted = Wait-ForDuplicateCompletion $Assembly $slowWorker $slowWorkerId
        Start-Sleep -Milliseconds 500

        $slowWorkerSurvivedLeaseLoss = -not $slowWorker.HasExited
        Save-Observation $bothInvocationsCompleted $scenarioDirectory "slow-consumer-completed"

        $originalClaimExpiry = [DateTimeOffset]$claimed.EarliestClaimExpiresAtUtc
        $competingCompletionDatabaseTime = [DateTimeOffset]$competingCompletion.DatabaseUtcNow
        $leaseExpiredBeforeCompetingCompletion =
            $competingCompletionDatabaseTime -ge $originalClaimExpiry
        $slowWorkerEffect = $bothInvocationsCompleted.WorkerEffects.PSObject.Properties[$slowWorkerId]
        $competingWorkerClaim = $bothInvocationsCompleted.WorkerClaims.PSObject.Properties[$competingWorkerId]
        $competingWorkerEffect = $bothInvocationsCompleted.WorkerEffects.PSObject.Properties[$competingWorkerId]
        $passed =
            $leaseExpiredBeforeCompetingCompletion -and
            $slowWorkerSurvivedLeaseLoss -and
            $competingCompletion.ProcessedMessages -eq 1 -and
            $competingCompletion.Effects -eq 1 -and
            $null -eq $competingCompletion.WorkerEffects.PSObject.Properties[$slowWorkerId] -and
            $bothInvocationsCompleted.BusinessOperations -eq 1 -and
            $bothInvocationsCompleted.OutboxMessages -eq 1 -and
            $bothInvocationsCompleted.PendingMessages -eq 0 -and
            $bothInvocationsCompleted.ProcessingMessages -eq 0 -and
            $bothInvocationsCompleted.ProcessedMessages -eq 1 -and
            $bothInvocationsCompleted.FailedMessages -eq 0 -and
            $bothInvocationsCompleted.FailedAttempts -eq 0 -and
            $bothInvocationsCompleted.Effects -eq 2 -and
            $bothInvocationsCompleted.DuplicateEffects -eq 1 -and
            @($bothInvocationsCompleted.WorkerEffects.PSObject.Properties).Count -eq 2 -and
            $null -ne $slowWorkerEffect -and
            $slowWorkerEffect.Value -eq 1 -and
            $null -ne $competingWorkerClaim -and
            $competingWorkerClaim.Value -eq 1 -and
            $null -ne $competingWorkerEffect -and
            $competingWorkerEffect.Value -eq 1
    }
    finally {
        Stop-Worker $competingWorker
        Stop-Worker $slowWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W07"
        SlowWorker = $slowWorkerId
        CompetingWorker = $competingWorkerId
        ClaimTimeoutMilliseconds = 5000
        ConsumerDurationMilliseconds = 10000
        LeaseExpiredBeforeCompetingCompletion = $leaseExpiredBeforeCompetingCompletion
        CompetingWorkerCompletedFirst = $competingCompletion.Effects -eq 1
        SlowWorkerSurvivedLeaseLoss = $slowWorkerSurvivedLeaseLoss
        ConsumerInvocations = $bothInvocationsCompleted.Effects
        DuplicateInvocations = $bothInvocationsCompleted.DuplicateEffects
        Observation = $bothInvocationsCompleted
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-GracefulIdleShutdownScenario {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W08-idle"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"

    $workerId = "TE-W08-idle-worker"
    $workerHandle = Start-TimedWorker $Assembly $workerId 1000 0 0 $scenarioDirectory

    try {
        Wait-ForWorkerExit $workerHandle $workerId
        $observation = Get-Observation -Assembly $Assembly
        Save-Observation $observation $scenarioDirectory "after-shutdown"

        $workerLog = Get-Content (Join-Path $scenarioDirectory "$workerId.stdout.log") -Raw
        $reportedGracefulShutdown = $workerLog.Contains("Application is shutting down")
        $passed =
            $reportedGracefulShutdown -and
            $observation.BusinessOperations -eq 0 -and
            $observation.OutboxMessages -eq 0 -and
            $observation.Effects -eq 0 -and
            @($observation.WorkerClaims.PSObject.Properties).Count -eq 0 -and
            @($observation.WorkerEffects.PSObject.Properties).Count -eq 0
    }
    finally {
        Stop-Worker $workerHandle.Process
    }

    $result = [ordered]@{
        Scenario = "TE-W08-idle"
        ExitCode = $workerHandle.Process.ExitCode
        ReportedGracefulShutdown = $reportedGracefulShutdown
        Observation = $observation
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-GracefulActiveShutdownScenario {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W08-active"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W08", "1") $scenarioDirectory "publish"

    $stoppingWorkerId = "TE-W08-stopping-worker"
    $recoveryWorkerId = "TE-W08-recovery"
    $stoppingWorkerHandle = Start-TimedWorker $Assembly $stoppingWorkerId 3000 30000 0 $scenarioDirectory
    $recoveryWorker = $null

    try {
        $claimed = Wait-ForClaim $Assembly $stoppingWorkerHandle.Process $stoppingWorkerId
        Save-Observation $claimed $scenarioDirectory "claimed-before-shutdown"
        Wait-ForWorkerExit $stoppingWorkerHandle $stoppingWorkerId

        $afterShutdown = Get-Observation -Assembly $Assembly
        Save-Observation $afterShutdown $scenarioDirectory "after-shutdown"

        $claimExpiry = [DateTimeOffset]$afterShutdown.EarliestClaimExpiresAtUtc
        $databaseNow = [DateTimeOffset]$afterShutdown.DatabaseUtcNow
        $workerLog = Get-Content (Join-Path $scenarioDirectory "$stoppingWorkerId.stdout.log") -Raw
        $reportedGracefulShutdown = $workerLog.Contains("Application is shutting down")
        $cancellationLeftRecoverableClaim =
            $reportedGracefulShutdown -and
            $databaseNow -lt $claimExpiry -and
            $afterShutdown.ProcessingMessages -eq 1 -and
            $afterShutdown.ProcessedMessages -eq 0 -and
            $afterShutdown.FailedMessages -eq 0 -and
            $afterShutdown.FailedAttempts -eq 0 -and
            $afterShutdown.Effects -eq 0

        $recoveryWorker = Start-Worker $Assembly $recoveryWorkerId 0 0 $scenarioDirectory
        $recovered = Wait-ForCompletion $Assembly $recoveryWorker $recoveryWorkerId
        Save-Observation $recovered $scenarioDirectory "recovered"
        $passed =
            $cancellationLeftRecoverableClaim -and
            (Assert-WorkerOwnsResult $recovered $recoveryWorkerId)
    }
    finally {
        Stop-Worker $recoveryWorker
        Stop-Worker $stoppingWorkerHandle.Process
    }

    $result = [ordered]@{
        Scenario = "TE-W08-active"
        ExitCode = $stoppingWorkerHandle.Process.ExitCode
        ReportedGracefulShutdown = $reportedGracefulShutdown
        CancellationLeftRecoverableClaim = $cancellationLeftRecoverableClaim
        ObservationAfterShutdown = $afterShutdown
        ObservationAfterRecovery = $recovered
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
    Invoke-EffectBeforeDeathScenario $assembly $artifactDirectory
    Invoke-LongConsumerScenario $assembly $artifactDirectory
    Invoke-GracefulIdleShutdownScenario $assembly $artifactDirectory
    Invoke-GracefulActiveShutdownScenario $assembly $artifactDirectory
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
