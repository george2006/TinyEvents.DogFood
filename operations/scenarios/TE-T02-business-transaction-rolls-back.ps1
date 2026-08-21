function Invoke-TET02BusinessTransactionRollsBack {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-T02"
    $operationCount = 10
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess `
        $Assembly `
        @("reset") `
        $scenarioDirectory `
        "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @("publish-then-rollback", "TE-T02", $operationCount) `
        $scenarioDirectory `
        "publish-then-rollback"

    $observation = Get-Observation $Assembly
    Save-Observation $observation $scenarioDirectory "after-rollback"

    $transactionWasRolledBack =
        $observation.BusinessOperations -eq 0 -and
        $observation.OutboxMessages -eq 0
    $noConsumerStateExists =
        $observation.PendingMessages -eq 0 -and
        $observation.ProcessingMessages -eq 0 -and
        $observation.ProcessedMessages -eq 0 -and
        $observation.FailedMessages -eq 0 -and
        $observation.FailedAttempts -eq 0 -and
        $observation.Effects -eq 0
    $passed = $transactionWasRolledBack -and $noConsumerStateExists

    $result = [ordered]@{
        Scenario = "TE-T02"
        AttemptedOperations = $operationCount
        TransactionWasRolledBack = $transactionWasRolledBack
        NoConsumerStateExists = $noConsumerStateExists
        Observation = $observation
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-TransactionScenarios.ps1"
    & $runner -Scenario "TE-T02"
}
