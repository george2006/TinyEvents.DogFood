function Invoke-TEW13DuplicateWorkerIdentity {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-W13"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess $Assembly @("publish", "TE-W13", "1") $scenarioDirectory "publish"

    $sharedWorkerId = "TE-W13-shared-worker"
    $originalWorker = Start-Worker `
        $Assembly `
        $sharedWorkerId `
        10000 `
        0 `
        $scenarioDirectory `
        "TE-W13-original"
    $competingWorker = $null

    try {
        $originalClaim = Wait-ForClaim $Assembly $originalWorker $sharedWorkerId
        Save-Observation $originalClaim $scenarioDirectory "original-claim"

        $originalClaimExpiry = [DateTimeOffset]$originalClaim.EarliestClaimExpiresAtUtc
        $competingWorker = Start-Worker `
            $Assembly `
            $sharedWorkerId `
            10000 `
            0 `
            $scenarioDirectory `
            "TE-W13-competitor"

        $reassigned = Wait-ForDuplicateIdentityReclaim `
            $Assembly `
            $originalWorker `
            $competingWorker `
            $originalClaimExpiry
        Save-Observation $reassigned $scenarioDirectory "reassigned-claim"

        $staleCompletion = Wait-ForStaleOwnerCompletion `
            $Assembly `
            $originalWorker `
            $competingWorker
        Save-Observation $staleCompletion $scenarioDirectory "stale-owner-completed"

        $completed = Wait-ForDuplicateCompletion `
            $Assembly `
            $competingWorker `
            $sharedWorkerId
        Save-Observation $completed $scenarioDirectory "both-consumers-completed"

        $originalWorkerSurvived = -not $originalWorker.HasExited
        $competingWorkerSurvived = -not $competingWorker.HasExited
        $staleOwnerCompletionWasAccepted =
            $staleCompletion.ProcessedMessages -eq 1 -and
            $staleCompletion.Effects -eq 1
        $passed =
            $staleOwnerCompletionWasAccepted -and
            $originalWorkerSurvived -and
            $competingWorkerSurvived -and
            (Test-DuplicateIdentityResult `
                $completed `
                $sharedWorkerId `
                $originalWorker.Id `
                $competingWorker.Id)
    }
    finally {
        Stop-Worker $competingWorker
        Stop-Worker $originalWorker
    }

    $result = [ordered]@{
        Scenario = "TE-W13"
        SharedWorkerId = $sharedWorkerId
        OriginalProcessId = $originalWorker.Id
        CompetingProcessId = $competingWorker.Id
        OriginalClaimExpiry = $originalClaimExpiry.ToString("O")
        ReassignedClaimExpiry = $reassigned.EarliestClaimExpiresAtUtc
        StaleOwnerCompletionWasAccepted = $staleOwnerCompletionWasAccepted
        OriginalWorkerSurvived = $originalWorkerSurvived
        CompetingWorkerSurvived = $competingWorkerSurvived
        Observation = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W13"
}
