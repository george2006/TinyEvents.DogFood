function New-TEL05StatePopulation {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [string]$ScenarioId,
        [string]$ArtifactDirectory
    )

    Invoke-LoggedProcess $Assembly @("reset") $ArtifactDirectory "reset"
    $empty = Get-StorageObservation $Assembly
    Save-StorageObservation $empty $ArtifactDirectory "empty"
    Invoke-LoggedProcess `
        $Assembly `
        @(
            "publish-with-content",
            $ScenarioId,
            [string]$RowCount,
            [string]$ContentCharacterCount) `
        $ArtifactDirectory `
        "publish"
    return $empty
}

function Wait-ForTEL05State {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [string]$State,
        [int]$ExpectedCount
    )

    $deadline = (Get-Date).AddMinutes(5)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Storage measurement worker $($exitedWorker.Id) exited before reaching $State."
        }

        $observation = Get-Observation $Assembly
        $stateWasReached = switch ($State) {
            "Processing" {
                $claimIsStillActive =
                    $null -ne $observation.EarliestClaimExpiresAtUtc -and
                    [DateTimeOffset]$observation.EarliestClaimExpiresAtUtc -gt
                    [DateTimeOffset]$observation.DatabaseUtcNow

                $observation.PendingMessages -eq 0 -and
                $observation.ProcessingMessages -eq $ExpectedCount -and
                $observation.ProcessedMessages -eq 0 -and
                $observation.FailedMessages -eq 0 -and
                $observation.Effects -eq 0 -and
                $claimIsStillActive
            }
            "Processed" {
                $observation.PendingMessages -eq 0 -and
                $observation.ProcessingMessages -eq 0 -and
                $observation.ProcessedMessages -eq $ExpectedCount -and
                $observation.FailedMessages -eq 0 -and
                $observation.Effects -eq $ExpectedCount
            }
            "Failed" {
                $observation.PendingMessages -eq 0 -and
                $observation.ProcessingMessages -eq 0 -and
                $observation.ProcessedMessages -eq 0 -and
                $observation.FailedMessages -eq $ExpectedCount -and
                $observation.FailedAttempts -eq ($ExpectedCount * 3) -and
                $observation.Effects -eq 0
            }
            default {
                throw "Unsupported storage state '$State'."
            }
        }

        if ($stateWasReached) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Storage population did not reach $ExpectedCount $State rows within five minutes."
}

function New-TEL05StateMeasurement {
    param(
        [string]$State,
        [int]$RowCount,
        [pscustomobject]$Empty,
        [pscustomobject]$Populated,
        [pscustomobject]$StateObservation,
        [bool]$StateWasCreated
    )

    $tableAllocatedBytes =
        $Populated.TableAllocatedBytes -
        $Empty.TableAllocatedBytes
    $indexAllocatedBytes =
        $Populated.IndexAllocatedBytes -
        $Empty.IndexAllocatedBytes
    $totalAllocatedBytes =
        $Populated.TotalAllocatedBytes -
        $Empty.TotalAllocatedBytes
    $physicalSizesAreConsistent =
        $totalAllocatedBytes -eq
        ($tableAllocatedBytes + $indexAllocatedBytes)
    $passed =
        $StateWasCreated -and
        $Empty.RowCount -eq 0 -and
        $Populated.RowCount -eq $RowCount -and
        $Populated.PayloadBytes -gt 0 -and
        $tableAllocatedBytes -gt 0 -and
        $indexAllocatedBytes -gt 0 -and
        $totalAllocatedBytes -gt 0 -and
        $physicalSizesAreConsistent

    return [pscustomobject][ordered]@{
        State = $State
        RowCount = $RowCount
        PayloadBytesPerRow = [Math]::Round(
            $Populated.PayloadBytes / $RowCount,
            2)
        TableAllocatedBytesPerRow = [Math]::Round(
            $tableAllocatedBytes / $RowCount,
            2)
        IndexAllocatedBytesPerRow = [Math]::Round(
            $indexAllocatedBytes / $RowCount,
            2)
        TotalAllocatedBytesPerRow = [Math]::Round(
            $totalAllocatedBytes / $RowCount,
            2)
        EmptyObservation = $Empty
        PopulatedObservation = $Populated
        StateObservation = $StateObservation
        AcceptancePassed = $passed
    }
}

function Invoke-TEL05PendingState {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [string]$ArtifactDirectory
    )

    $stateDirectory = Join-Path $ArtifactDirectory "pending"
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $empty = New-TEL05StatePopulation `
        $Assembly `
        $RowCount `
        $ContentCharacterCount `
        "TE-L05-pending" `
        $stateDirectory
    $stateObservation = Get-Observation $Assembly
    $populated = Get-StorageObservation $Assembly
    Save-Observation $stateObservation $stateDirectory "state"
    Save-StorageObservation $populated $stateDirectory "storage"
    $stateWasCreated =
        $stateObservation.PendingMessages -eq $RowCount -and
        $stateObservation.ProcessingMessages -eq 0 -and
        $stateObservation.ProcessedMessages -eq 0 -and
        $stateObservation.FailedMessages -eq 0
    return New-TEL05StateMeasurement `
        "Pending" `
        $RowCount `
        $empty `
        $populated `
        $stateObservation `
        $stateWasCreated
}

function Invoke-TEL05ProcessingState {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [string]$ArtifactDirectory
    )

    $stateDirectory = Join-Path $ArtifactDirectory "processing"
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $empty = New-TEL05StatePopulation `
        $Assembly `
        $RowCount `
        $ContentCharacterCount `
        "TE-L05-processing" `
        $stateDirectory
    $worker = Start-BatchWorker `
        $Assembly `
        "TE-L05-processing-worker" `
        $RowCount `
        30000 `
        0 `
        $stateDirectory

    try {
        $stateObservation = Wait-ForTEL05State `
            $Assembly `
            @($worker) `
            "Processing" `
            $RowCount
        $populated = Get-StorageObservation $Assembly
        Save-Observation $stateObservation $stateDirectory "state"
        Save-StorageObservation $populated $stateDirectory "storage"
    }
    finally {
        Stop-Worker $worker
    }

    return New-TEL05StateMeasurement `
        "Processing" `
        $RowCount `
        $empty `
        $populated `
        $stateObservation `
        $true
}

function Invoke-TEL05ProcessedState {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [int]$WorkerCount,
        [int]$WorkerBatchSize,
        [string]$ArtifactDirectory
    )

    $stateDirectory = Join-Path $ArtifactDirectory "processed"
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $empty = New-TEL05StatePopulation `
        $Assembly `
        $RowCount `
        $ContentCharacterCount `
        "TE-L05-processed" `
        $stateDirectory
    $workers = @()

    try {
        $workers = @(
            for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
                Start-BatchWorker `
                    $Assembly `
                    "TE-L05-processed-worker-$workerNumber" `
                    $WorkerBatchSize `
                    0 `
                    0 `
                    $stateDirectory
            })
        $stateObservation = Wait-ForTEL05State `
            $Assembly `
            $workers `
            "Processed" `
            $RowCount
        $populated = Get-StorageObservation $Assembly
        Save-Observation $stateObservation $stateDirectory "state"
        Save-StorageObservation $populated $stateDirectory "storage"
    }
    finally {
        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    return New-TEL05StateMeasurement `
        "Processed" `
        $RowCount `
        $empty `
        $populated `
        $stateObservation `
        $true
}

function Invoke-TEL05FailedState {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [int]$WorkerCount,
        [int]$WorkerBatchSize,
        [string]$ArtifactDirectory
    )

    $stateDirectory = Join-Path $ArtifactDirectory "failed"
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $scenarioId = "TE-L05-failed"
    $empty = New-TEL05StatePopulation `
        $Assembly `
        $RowCount `
        $ContentCharacterCount `
        $scenarioId `
        $stateDirectory
    $workers = @()

    try {
        $workers = @(
            for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
                Start-FailingWorker `
                    $Assembly `
                    "TE-L05-failed-worker-$workerNumber" `
                    $scenarioId `
                    3 `
                    $stateDirectory `
                    $WorkerBatchSize
            })
        $stateObservation = Wait-ForTEL05State `
            $Assembly `
            $workers `
            "Failed" `
            $RowCount
        $populated = Get-StorageObservation $Assembly
        Save-Observation $stateObservation $stateDirectory "state"
        Save-StorageObservation $populated $stateDirectory "storage"
    }
    finally {
        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    return New-TEL05StateMeasurement `
        "Failed" `
        $RowCount `
        $empty `
        $populated `
        $stateObservation `
        $true
}

function Invoke-TEL05StorageStateMeasurements {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [int]$WorkerCount,
        [int]$WorkerBatchSize,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L05-states"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null
    $states = @(
        Invoke-TEL05PendingState `
            $Assembly `
            $RowCount `
            $ContentCharacterCount `
            $scenarioDirectory
        Invoke-TEL05ProcessingState `
            $Assembly `
            $RowCount `
            $ContentCharacterCount `
            $scenarioDirectory
        Invoke-TEL05ProcessedState `
            $Assembly `
            $RowCount `
            $ContentCharacterCount `
            $WorkerCount `
            $WorkerBatchSize `
            $scenarioDirectory
        Invoke-TEL05FailedState `
            $Assembly `
            $RowCount `
            $ContentCharacterCount `
            $WorkerCount `
            $WorkerBatchSize `
            $scenarioDirectory)
    $result = [ordered]@{
        Scenario = "TE-L05"
        Measurement = "Outbox states"
        ContentCharacterCount = $ContentCharacterCount
        WorkerBatchSize = $WorkerBatchSize
        States = $states
        AcceptancePassed = $states.AcceptancePassed -notcontains $false
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-StorageStateMeasurements.ps1"
    & $runner
}
