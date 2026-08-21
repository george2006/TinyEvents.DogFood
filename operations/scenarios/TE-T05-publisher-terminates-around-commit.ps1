function Start-TET05Publisher {
    param(
        [string]$Assembly,
        [string]$ScenarioId,
        [int]$BeforeCommitDelayMilliseconds,
        [int]$AfterCommitDelayMilliseconds,
        [string]$ArtifactDirectory,
        [string]$EvidenceName
    )

    $standardOutput = Join-Path $ArtifactDirectory "$EvidenceName.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$EvidenceName.stderr.log"

    return Start-Process `
        -FilePath "dotnet" `
        -ArgumentList @(
            $Assembly,
            "publish-with-timing",
            $ScenarioId,
            [string]$BeforeCommitDelayMilliseconds,
            [string]$AfterCommitDelayMilliseconds) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -PassThru
}

function Stop-TET05Publisher {
    param([System.Diagnostics.Process]$Publisher)

    if (!$Publisher.HasExited) {
        Stop-Process -Id $Publisher.Id
        $Publisher.WaitForExit()
    }
}

function Test-TET05EmptyState {
    param([pscustomobject]$Observation)

    return (
        $Observation.BusinessOperations -eq 0 -and
        $Observation.OutboxMessages -eq 0)
}

function Test-TET05CommittedState {
    param([pscustomobject]$Observation)

    return (
        $Observation.BusinessOperations -eq 1 -and
        $Observation.OutboxMessages -eq 1 -and
        $Observation.PendingMessages -eq 1)
}

function Invoke-TET05PublisherTerminatesAroundCommit {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-T05"
    $boundaryDelayMilliseconds = 10000
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset-before-commit"
    $beforeCommitPublisher = Start-TET05Publisher `
        $Assembly `
        "TE-T05-before-commit" `
        $boundaryDelayMilliseconds `
        0 `
        $scenarioDirectory `
        "before-commit"

    try {
        Wait-ForLogText `
            $beforeCommitPublisher `
            (Join-Path $scenarioDirectory "before-commit.stdout.log") `
            "Publisher waiting before commit." `
            "Publisher waiting before commit"
    }
    finally {
        Stop-TET05Publisher $beforeCommitPublisher
    }

    $terminatedBeforeCommit = Get-Observation $Assembly
    Save-Observation $terminatedBeforeCommit $scenarioDirectory "terminated-before-commit"

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset-after-commit"
    $afterCommitPublisher = Start-TET05Publisher `
        $Assembly `
        "TE-T05-after-commit" `
        0 `
        $boundaryDelayMilliseconds `
        $scenarioDirectory `
        "after-commit"

    try {
        Wait-ForLogText `
            $afterCommitPublisher `
            (Join-Path $scenarioDirectory "after-commit.stdout.log") `
            "Publisher commit completed." `
            "Publisher waiting after commit"
    }
    finally {
        Stop-TET05Publisher $afterCommitPublisher
    }

    $terminatedAfterCommit = Get-Observation $Assembly
    Save-Observation $terminatedAfterCommit $scenarioDirectory "terminated-after-commit"

    Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset-acknowledged"
    Invoke-LoggedProcess `
        $Assembly `
        @("publish", "TE-T05-acknowledged", "1") `
        $scenarioDirectory `
        "acknowledged"
    $acknowledgedCommit = Get-Observation $Assembly
    Save-Observation $acknowledgedCommit $scenarioDirectory "acknowledged-commit"

    $uncommittedWorkWasDiscarded =
        Test-TET05EmptyState $terminatedBeforeCommit
    $commitSurvivedProcessTermination =
        Test-TET05CommittedState $terminatedAfterCommit
    $acknowledgedCommitIsDurable =
        Test-TET05CommittedState $acknowledgedCommit
    $passed =
        $uncommittedWorkWasDiscarded -and
        $commitSurvivedProcessTermination -and
        $acknowledgedCommitIsDurable

    $result = [ordered]@{
        Scenario = "TE-T05"
        UncommittedWorkWasDiscarded = $uncommittedWorkWasDiscarded
        CommitSurvivedProcessTermination = $commitSurvivedProcessTermination
        AcknowledgedCommitIsDurable = $acknowledgedCommitIsDurable
        TerminatedBeforeCommit = $terminatedBeforeCommit
        TerminatedAfterCommit = $terminatedAfterCommit
        AcknowledgedCommit = $acknowledgedCommit
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-TransactionScenarios.ps1"
    & $runner -Scenario "TE-T05"
}
