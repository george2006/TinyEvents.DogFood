function Invoke-TEL06CleanupBoundary {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L06-A"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @("run-cleanup-boundary") `
        $scenarioDirectory `
        "cleanup-boundary"

    $commandResult = Read-LoggedJsonResult `
        (Join-Path $scenarioDirectory "cleanup-boundary.stdout.log")
    $after = $commandResult.AfterCleanup
    $cutoffUtc = [DateTimeOffset]$commandResult.CutoffUtc
    $boundaryProcessedAtUtc =
        [DateTimeOffset]$after.BoundaryProcessed.ProcessedAtUtc
    $recentProcessedAtUtc =
        [DateTimeOffset]$after.RecentProcessed.ProcessedAtUtc
    $messageIds = @(
        $after.EligibleProcessed.Id,
        $after.BoundaryProcessed.Id,
        $after.RecentProcessed.Id,
        $after.Pending.Id,
        $after.Processing.Id,
        $after.Failed.Id)

    $oneEligibleRowWasDeleted =
        $commandResult.DeletedCount -eq 1 -and
        !$after.EligibleProcessed.Exists
    $cutoffBoundaryWasPreserved =
        $after.BoundaryProcessed.Exists -and
        $after.BoundaryProcessed.Status -eq "Processed" -and
        $boundaryProcessedAtUtc -eq $cutoffUtc
    $recentProcessedRowWasPreserved =
        $after.RecentProcessed.Exists -and
        $after.RecentProcessed.Status -eq "Processed" -and
        $recentProcessedAtUtc -gt $cutoffUtc
    $nonProcessedStatesWerePreserved =
        $after.Pending.Exists -and
        $after.Pending.Status -eq "Pending" -and
        $null -eq $after.Pending.ProcessedAtUtc -and
        $after.Processing.Exists -and
        $after.Processing.Status -eq "Processing" -and
        $null -eq $after.Processing.ProcessedAtUtc -and
        $after.Failed.Exists -and
        $after.Failed.Status -eq "Failed" -and
        $null -eq $after.Failed.ProcessedAtUtc
    $rolesReferToDistinctMessages =
        @($messageIds | Sort-Object -Unique).Count -eq 6
    $passed =
        $oneEligibleRowWasDeleted -and
        $cutoffBoundaryWasPreserved -and
        $recentProcessedRowWasPreserved -and
        $nonProcessedStatesWerePreserved -and
        $rolesReferToDistinctMessages

    $result = [ordered]@{
        Scenario = "TE-L06-A"
        CutoffUtc = $commandResult.CutoffUtc
        DeletedCount = $commandResult.DeletedCount
        OneEligibleRowWasDeleted = $oneEligibleRowWasDeleted
        CutoffBoundaryWasPreserved = $cutoffBoundaryWasPreserved
        RecentProcessedRowWasPreserved = $recentProcessedRowWasPreserved
        NonProcessedStatesWerePreserved = $nonProcessedStatesWerePreserved
        RolesReferToDistinctMessages = $rolesReferToDistinctMessages
        Observation = $commandResult
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
