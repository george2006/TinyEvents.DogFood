function Invoke-TEL01PublishingRate {
    param(
        [string]$Assembly,
        [int]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [string]$ArtifactDirectory
    )

    $variantDirectory = Join-Path `
        $ArtifactDirectory `
        "$TargetRequestsPerSecond-requests-per-second"
    New-Item -ItemType Directory -Force -Path $variantDirectory | Out-Null

    Invoke-LoggedProcess `
        $Assembly `
        @("reset") `
        $variantDirectory `
        "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @(
            "publish-load",
            "TE-L01-$TargetRequestsPerSecond",
            [string]$TargetRequestsPerSecond,
            [string]$DurationSeconds) `
        $variantDirectory `
        "publish-load"

    $loadResult = Get-PublishingLoadResult `
        (Join-Path $variantDirectory "publish-load.stdout.log")
    $observation = Get-Observation $Assembly
    Save-Observation $observation $variantDirectory "after-publishing"

    $expectedRequests = $TargetRequestsPerSecond * $DurationSeconds
    $durableCountsAreExact =
        $observation.BusinessOperations -eq $expectedRequests -and
        $observation.OutboxMessages -eq $expectedRequests -and
        $observation.PendingMessages -eq $expectedRequests -and
        $observation.ProcessingMessages -eq 0 -and
        $observation.ProcessedMessages -eq 0 -and
        $observation.FailedMessages -eq 0 -and
        $observation.Effects -eq 0
    $allRequestsCommitted =
        $loadResult.AttemptedRequests -eq $expectedRequests -and
        $loadResult.CommittedRequests -eq $expectedRequests -and
        $loadResult.FailedRequests -eq 0
    $achievedTargetPercentage = [Math]::Round(
        100 * $loadResult.CommittedRequestsPerSecond / $TargetRequestsPerSecond,
        2)
    $targetWasSustained = $achievedTargetPercentage -ge 95
    $passed = $allRequestsCommitted -and $durableCountsAreExact

    $result = [ordered]@{
        TargetRequestsPerSecond = $TargetRequestsPerSecond
        DurationSeconds = $DurationSeconds
        AchievedTargetPercentage = $achievedTargetPercentage
        TargetWasSustained = $targetWasSustained
        Load = $loadResult
        Observation = $observation
        AllRequestsCommitted = $allRequestsCommitted
        DurableCountsAreExact = $durableCountsAreExact
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $variantDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-TEL01SustainedPublishing {
    param(
        [string]$Assembly,
        [int[]]$TargetRequestsPerSecond,
        [int]$DurationSeconds,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L01"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $rates = foreach ($targetRate in $TargetRequestsPerSecond) {
        Invoke-TEL01PublishingRate `
            $Assembly `
            $targetRate `
            $DurationSeconds `
            $scenarioDirectory
    }

    $result = [ordered]@{
        Scenario = "TE-L01"
        Rates = @($rates)
        AcceptancePassed = $rates.AcceptancePassed -notcontains $false
    }

    $result |
        ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-PublishingLoad.ps1"
    & $runner
}
