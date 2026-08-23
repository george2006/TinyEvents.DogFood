function Invoke-TEL06ConcurrentCleanup {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L06-B"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $messageCount = 401
    $batchSize = 37
    $processCount = 4
    $cutoffUtc = [DateTimeOffset]::Parse("2026-08-23T12:00:00Z")
    $cutoffArgument = $cutoffUtc.ToString("O")

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @(
            "prepare-cleanup-population",
            [string]$messageCount,
            $cutoffArgument) `
        $scenarioDirectory `
        "prepare"

    $before = Get-Observation -Assembly $Assembly
    Save-Observation $before $scenarioDirectory "before-cleanup"

    $remainingMessages = $before.OutboxMessages
    $waveNumber = 0
    $allBatchResults = [System.Collections.Generic.List[object]]::new()
    $waveResults = [System.Collections.Generic.List[object]]::new()

    while ($remainingMessages -gt 0) {
        $waveNumber++
        $startAtUtc = [DateTimeOffset]::UtcNow.AddSeconds(2).ToString("O")
        $processes = @()

        for ($processNumber = 1; $processNumber -le $processCount; $processNumber++) {
            $name = "wave-$waveNumber-cleaner-$processNumber"
            $processes += Start-LoggedDotNetProcess `
                $Assembly `
                @(
                    "cleanup-once",
                    $cutoffArgument,
                    [string]$batchSize,
                    $startAtUtc) `
                $scenarioDirectory `
                $name
        }

        foreach ($process in $processes) {
            Complete-LoggedProcess $process 30000
        }

        $batchResults = @(
            $processes | ForEach-Object {
                Read-LoggedJsonResult $_.OutputPath
            })
        $deletedThisWave =
            ($batchResults | Measure-Object -Property DeletedCount -Sum).Sum
        $latestStartUtc =
            $batchResults |
            ForEach-Object { [DateTimeOffset]$_.StartedAtUtc } |
            Sort-Object -Descending |
            Select-Object -First 1
        $earliestCompletionUtc =
            $batchResults |
            ForEach-Object { [DateTimeOffset]$_.CompletedAtUtc } |
            Sort-Object |
            Select-Object -First 1
        $requestsOverlapped = $latestStartUtc -lt $earliestCompletionUtc
        $contributingProcessCount =
            @($batchResults |
                Where-Object { $_.DeletedCount -gt 0 }).Count

        foreach ($batchResult in $batchResults) {
            $allBatchResults.Add($batchResult)
        }

        $afterWave = Get-Observation -Assembly $Assembly
        Save-Observation `
            $afterWave `
            $scenarioDirectory `
            "after-wave-$waveNumber"
        $durableDecrease = $remainingMessages - $afterWave.OutboxMessages

        $waveResults.Add([pscustomobject]@{
            Wave = $waveNumber
            RemainingBefore = $remainingMessages
            ReportedDeleted = $deletedThisWave
            DurableDecrease = $durableDecrease
            RemainingAfter = $afterWave.OutboxMessages
            RequestsOverlapped = $requestsOverlapped
            ContributingProcessCount = $contributingProcessCount
            BatchResults = $batchResults
        })

        if ($deletedThisWave -le 0) {
            throw "Concurrent cleanup stopped making progress with $remainingMessages messages remaining."
        }

        $remainingMessages = $afterWave.OutboxMessages
    }

    $after = Get-Observation -Assembly $Assembly
    Save-Observation $after $scenarioDirectory "after-cleanup"

    $reportedDeletedTotal =
        ($allBatchResults | Measure-Object -Property DeletedCount -Sum).Sum
    $everyBatchWasBounded =
        @($allBatchResults |
            Where-Object {
                $_.DeletedCount -lt 0 -or
                $_.DeletedCount -gt $batchSize
            }).Count -eq 0
    $everyWaveMatchedDurableState =
        @($waveResults |
            Where-Object {
                $_.ReportedDeleted -ne $_.DurableDecrease
            }).Count -eq 0
    $everyWaveWasConcurrent =
        @($waveResults |
            Where-Object { !$_.RequestsOverlapped }).Count -eq 0
    $everyWaveHadMultipleContributors =
        @($waveResults |
            Where-Object {
                $_.ContributingProcessCount -lt 2
            }).Count -eq 0
    $exactPopulationWasDeleted =
        $before.BusinessOperations -eq $messageCount -and
        $before.OutboxMessages -eq $messageCount -and
        $before.ProcessedMessages -eq $messageCount -and
        $reportedDeletedTotal -eq $messageCount -and
        $after.BusinessOperations -eq $messageCount -and
        $after.OutboxMessages -eq 0 -and
        $after.PendingMessages -eq 0 -and
        $after.ProcessingMessages -eq 0 -and
        $after.ProcessedMessages -eq 0 -and
        $after.FailedMessages -eq 0
    $multipleWavesWereRequired = $waveResults.Count -gt 1
    $passed =
        $everyBatchWasBounded -and
        $everyWaveMatchedDurableState -and
        $everyWaveWasConcurrent -and
        $everyWaveHadMultipleContributors -and
        $exactPopulationWasDeleted -and
        $multipleWavesWereRequired

    $result = [ordered]@{
        Scenario = "TE-L06-B"
        MessageCount = $messageCount
        BatchSize = $batchSize
        ProcessCount = $processCount
        WaveCount = $waveResults.Count
        ReportedDeletedTotal = $reportedDeletedTotal
        EveryBatchWasBounded = $everyBatchWasBounded
        EveryWaveMatchedDurableState = $everyWaveMatchedDurableState
        EveryWaveWasConcurrent = $everyWaveWasConcurrent
        EveryWaveHadMultipleContributors = $everyWaveHadMultipleContributors
        ExactPopulationWasDeleted = $exactPopulationWasDeleted
        MultipleWavesWereRequired = $multipleWavesWereRequired
        Waves = $waveResults
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-CleanupScenarios.ps1"
    & $runner
}
