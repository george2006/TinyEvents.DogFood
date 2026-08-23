function Wait-ForTEL06PartialCleanup {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$CleanupProcess,
        [int]$InitialMessageCount
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($CleanupProcess.HasExited) {
            throw "Cleanup process exited before making partial progress."
        }

        $observation = Get-Observation -Assembly $Assembly
        $cleanupIsPartial =
            $observation.OutboxMessages -gt 0 -and
            $observation.OutboxMessages -lt $InitialMessageCount

        if ($cleanupIsPartial) {
            return $observation
        }

        Start-Sleep -Milliseconds 50
    }

    throw "Cleanup did not make partial progress within twenty seconds."
}

function Wait-ForTEL06CleanupCompletion {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process]$CleanupProcess,
        [int]$ExpectedBusinessOperationCount
    )

    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if ($CleanupProcess.HasExited) {
            throw "Replacement cleanup process exited before completing cleanup."
        }

        $observation = Get-Observation -Assembly $Assembly
        $cleanupCompleted =
            $observation.BusinessOperations -eq $ExpectedBusinessOperationCount -and
            $observation.OutboxMessages -eq 0

        if ($cleanupCompleted) {
            return $observation
        }

        Start-Sleep -Milliseconds 50
    }

    throw "Replacement cleanup did not complete within thirty seconds."
}

function Invoke-TEL06CleanupProcessRecovery {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L06-C1"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $messageCount = 1000
    $processedRetentionSeconds = 60
    $batchSize = 37
    $intervalMilliseconds = 250
    $fixtureCutoffUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString("O")
    $original = $null
    $replacement = $null

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

        $original = Start-LoggedDotNetProcess `
            $Assembly `
            @(
                "cleanup-worker",
                "TE-L06-C1-original",
                [string]$processedRetentionSeconds,
                [string]$batchSize,
                [string]$intervalMilliseconds) `
            $scenarioDirectory `
            "original-cleanup"
        $partial = Wait-ForTEL06PartialCleanup `
            $Assembly `
            $original.Process `
            $messageCount
        Save-Observation $partial $scenarioDirectory "partial-cleanup"

        $originalExitCode = Stop-LoggedProcess $original
        $original = $null
        $afterTermination = Get-Observation -Assembly $Assembly
        Save-Observation `
            $afterTermination `
            $scenarioDirectory `
            "after-termination"

        Start-Sleep -Milliseconds ($intervalMilliseconds * 3)
        $whileStopped = Get-Observation -Assembly $Assembly
        Save-Observation $whileStopped $scenarioDirectory "while-stopped"

        $replacement = Start-LoggedDotNetProcess `
            $Assembly `
            @(
                "cleanup-worker",
                "TE-L06-C1-replacement",
                [string]$processedRetentionSeconds,
                [string]$batchSize,
                [string]$intervalMilliseconds) `
            $scenarioDirectory `
            "replacement-cleanup"
        $completed = Wait-ForTEL06CleanupCompletion `
            $Assembly `
            $replacement.Process `
            $messageCount
        Save-Observation $completed $scenarioDirectory "completed"
        $replacementExitCode = Stop-LoggedProcess $replacement
        $replacement = $null

        $initialPopulationWasCorrect =
            $before.BusinessOperations -eq $messageCount -and
            $before.OutboxMessages -eq $messageCount -and
            $before.ProcessedMessages -eq $messageCount
        $originalProcessWasTerminated = $originalExitCode -ne 0
        $originalMadePartialProgress =
            $partial.OutboxMessages -gt 0 -and
            $partial.OutboxMessages -lt $messageCount
        $workRemainedAfterTermination =
            $afterTermination.OutboxMessages -gt 0 -and
            $afterTermination.OutboxMessages -le $partial.OutboxMessages
        $stateWasStableWithoutAProcess =
            $whileStopped.OutboxMessages -eq $afterTermination.OutboxMessages
        $replacementCompletedRemainingWork =
            $completed.BusinessOperations -eq $messageCount -and
            $completed.OutboxMessages -eq 0 -and
            $completed.PendingMessages -eq 0 -and
            $completed.ProcessingMessages -eq 0 -and
            $completed.ProcessedMessages -eq 0 -and
            $completed.FailedMessages -eq 0
        $passed =
            $initialPopulationWasCorrect -and
            $originalProcessWasTerminated -and
            $originalMadePartialProgress -and
            $workRemainedAfterTermination -and
            $stateWasStableWithoutAProcess -and
            $replacementCompletedRemainingWork

        $result = [ordered]@{
            Scenario = "TE-L06-C1"
            MessageCount = $messageCount
            BatchSize = $batchSize
            OriginalExitCode = $originalExitCode
            ReplacementExitCode = $replacementExitCode
            RemainingAtPartialObservation = $partial.OutboxMessages
            RemainingAfterTermination = $afterTermination.OutboxMessages
            RemainingWhileStopped = $whileStopped.OutboxMessages
            InitialPopulationWasCorrect = $initialPopulationWasCorrect
            OriginalProcessWasTerminated = $originalProcessWasTerminated
            OriginalMadePartialProgress = $originalMadePartialProgress
            WorkRemainedAfterTermination = $workRemainedAfterTermination
            StateWasStableWithoutAProcess = $stateWasStableWithoutAProcess
            ReplacementCompletedRemainingWork = $replacementCompletedRemainingWork
            AcceptancePassed = $passed
        }

        $result |
            ConvertTo-Json -Depth 6 |
            Set-Content (Join-Path $scenarioDirectory "result.json")
        return [pscustomobject]$result
    }
    finally {
        if ($null -ne $original -and !$original.Process.HasExited) {
            Stop-LoggedProcess $original | Out-Null
        }

        if ($null -ne $replacement -and !$replacement.Process.HasExited) {
            Stop-LoggedProcess $replacement | Out-Null
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-CleanupScenarios.ps1"
    & $runner
}
