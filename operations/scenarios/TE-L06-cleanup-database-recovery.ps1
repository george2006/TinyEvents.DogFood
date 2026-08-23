function Test-TEL06DeletionFollowedRecovery {
    param([string]$CleanupLog)

    $content = Get-Content -LiteralPath $CleanupLog -Raw
    $recoveryIndex = $content.LastIndexOf(
        "TinyEvents cleanup recovered after",
        [StringComparison]::Ordinal)

    if ($recoveryIndex -lt 0) {
        return $false
    }

    $deletionAfterRecoveryIndex = $content.IndexOf(
        "TinyEvents deleted",
        $recoveryIndex,
        [StringComparison]::Ordinal)
    return $deletionAfterRecoveryIndex -gt $recoveryIndex
}

function Invoke-TEL06CleanupDatabaseRecovery {
    param(
        [string]$Assembly,
        [pscustomobject]$Database,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L06-C2"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $messageCount = 1000
    $processedRetentionSeconds = 60
    $batchSize = 37
    $intervalMilliseconds = 500
    $fixtureCutoffUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString("O")
    $workerId = "TE-L06-C2-cleanup"
    $cleanupLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
    $databaseRestored = $false
    $cleanupProcess = $null

    try {
        Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
        Invoke-LoggedProcess `
            $Assembly `
            @(
                "prepare-cleanup-population",
                [string]$messageCount,
                $fixtureCutoffUtc) `
            $scenarioDirectory `
            "prepare"

        $before = Get-Observation -Assembly $Assembly
        Save-Observation $before $scenarioDirectory "before-cleanup"

        $cleanupProcess = Start-CleanupWorker `
            $Assembly `
            $workerId `
            $processedRetentionSeconds `
            $batchSize `
            $intervalMilliseconds `
            $scenarioDirectory
        $partial = Wait-ForTEL06PartialCleanup `
            $Assembly `
            $cleanupProcess `
            $messageCount
        Save-Observation $partial $scenarioDirectory "before-outage"

        Stop-DogfoodDatabase $Database

        Wait-ForLogText `
            $cleanupProcess `
            $cleanupLog `
            "TinyEvents cleanup has failed 5 consecutive iterations" `
            "Cleanup database-recovery process" `
            90
        $processSurvivedOutage = !$cleanupProcess.HasExited

        Start-DogfoodDatabase $Database
        $databaseRestored = $true

        Wait-ForLogText `
            $cleanupProcess `
            $cleanupLog `
            "TinyEvents cleanup recovered after" `
            "Cleanup database-recovery process" `
            90
        $completed = Wait-ForTEL06CleanupCompletion `
            $Assembly `
            $cleanupProcess `
            $messageCount
        Save-Observation $completed $scenarioDirectory "after-recovery"
        $sameProcessCompletedAfterRecovery = !$cleanupProcess.HasExited
    }
    finally {
        if (!$databaseRestored) {
            Start-DogfoodDatabase $Database
        }

        Stop-Worker $cleanupProcess
    }

    $failureWasObserved = Select-String `
        -LiteralPath $cleanupLog `
        -SimpleMatch "TinyEvents cleanup has failed 5 consecutive iterations" `
        -Quiet
    $recoveryWasObserved = Select-String `
        -LiteralPath $cleanupLog `
        -SimpleMatch "TinyEvents cleanup recovered after" `
        -Quiet
    $deletionFollowedRecovery = Test-TEL06DeletionFollowedRecovery $cleanupLog
    $initialPopulationWasCorrect =
        $before.BusinessOperations -eq $messageCount -and
        $before.OutboxMessages -eq $messageCount -and
        $before.ProcessedMessages -eq $messageCount
    $outageInterruptedCleanup =
        $partial.OutboxMessages -gt 0 -and
        $partial.OutboxMessages -lt $messageCount
    $sameProcessCompletedTheRemainder =
        $sameProcessCompletedAfterRecovery -and
        $completed.BusinessOperations -eq $messageCount -and
        $completed.OutboxMessages -eq 0 -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq 0 -and
        $completed.FailedMessages -eq 0
    $passed =
        $initialPopulationWasCorrect -and
        $outageInterruptedCleanup -and
        $failureWasObserved -and
        $processSurvivedOutage -and
        $recoveryWasObserved -and
        $deletionFollowedRecovery -and
        $sameProcessCompletedTheRemainder

    $result = [ordered]@{
        Scenario = "TE-L06-C2"
        MessageCount = $messageCount
        BatchSize = $batchSize
        ProcessId = $cleanupProcess.Id
        RemainingBeforeOutage = $partial.OutboxMessages
        FailureWasObserved = $failureWasObserved
        ProcessSurvivedOutage = $processSurvivedOutage
        RecoveryWasObserved = $recoveryWasObserved
        DeletionFollowedRecovery = $deletionFollowedRecovery
        SameProcessCompletedTheRemainder = $sameProcessCompletedTheRemainder
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 6 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-CleanupScenarios.ps1"
    & $runner
}
