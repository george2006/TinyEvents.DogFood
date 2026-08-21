function Invoke-TEW03ActiveClaim {
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
        $passed = $wasProtectedBeforeExpiry -and (Test-WorkerOwnsResult $completed $ownerId)
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

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-WorkerRecovery.ps1"
    & $runner -Scenario "TE-W03"
}
