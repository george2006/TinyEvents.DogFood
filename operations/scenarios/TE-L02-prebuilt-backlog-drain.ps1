function Wait-ForTEL02Drain {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [int]$ExpectedMessageCount
    )

    $deadline = (Get-Date).AddMinutes(5)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Worker process $($exitedWorker.Id) exited before the backlog drained. Exit code: $($exitedWorker.ExitCode)."
        }

        $observation = Get-Observation $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq $ExpectedMessageCount) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Workers did not drain $ExpectedMessageCount messages within five minutes."
}

function Test-TEL02WorkerParticipation {
    param(
        [pscustomobject]$Observation,
        [string[]]$WorkerIds
    )

    foreach ($workerId in $WorkerIds) {
        $claims = $Observation.WorkerClaims.PSObject.Properties[$workerId]
        $effects = $Observation.WorkerEffects.PSObject.Properties[$workerId]

        if ($null -eq $claims -or
            $null -eq $effects -or
            $claims.Value -le 0 -or
            $claims.Value -ne $effects.Value) {
            return $false
        }
    }

    return (
        @($Observation.WorkerClaims.PSObject.Properties).Count -eq $WorkerIds.Count -and
        @($Observation.WorkerEffects.PSObject.Properties).Count -eq $WorkerIds.Count)
}

function Invoke-TEL02WorkerCount {
    param(
        [string]$Assembly,
        [int]$WorkerCount,
        [int]$Backlog,
        [string]$ArtifactDirectory
    )

    $variantDirectory = Join-Path $ArtifactDirectory "$WorkerCount-workers"
    New-Item -ItemType Directory -Force -Path $variantDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $variantDirectory "reset"
    Invoke-LoggedProcess `
        $Assembly `
        @("publish", "TE-L02-$WorkerCount", [string]$Backlog) `
        $variantDirectory `
        "build-backlog"

    $before = Get-Observation $Assembly
    Save-Observation $before $variantDirectory "before-workers"

    $backlogIsReady =
        $before.BusinessOperations -eq $Backlog -and
        $before.OutboxMessages -eq $Backlog -and
        $before.PendingMessages -eq $Backlog -and
        $before.ProcessingMessages -eq 0 -and
        $before.ProcessedMessages -eq 0 -and
        $before.FailedMessages -eq 0 -and
        $before.Effects -eq 0

    if (!$backlogIsReady) {
        throw "TE-L02 could not build the expected $Backlog-message backlog."
    }

    $workerIds = @(
        for ($workerNumber = 1; $workerNumber -le $WorkerCount; $workerNumber++) {
            "TE-L02-$WorkerCount-worker-$workerNumber"
        })
    $workers = @()
    $drain = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $workers = @(
            foreach ($workerId in $workerIds) {
                Start-Worker $Assembly $workerId 0 0 $variantDirectory
            })
        $after = Wait-ForTEL02Drain $Assembly $workers $Backlog
        $drain.Stop()
        Save-Observation $after $variantDirectory "after-drain"
    }
    finally {
        $drain.Stop()

        foreach ($worker in $workers) {
            Stop-Worker $worker
        }
    }

    $allWorkersParticipated = Test-TEL02WorkerParticipation $after $workerIds
    $drainSeconds = [Math]::Max($drain.Elapsed.TotalSeconds, 0.001)
    $messagesPerSecond = [Math]::Round($Backlog / $drainSeconds, 2)
    $passed =
        $allWorkersParticipated -and
        $after.BusinessOperations -eq $Backlog -and
        $after.OutboxMessages -eq $Backlog -and
        $after.PendingMessages -eq 0 -and
        $after.ProcessingMessages -eq 0 -and
        $after.ProcessedMessages -eq $Backlog -and
        $after.FailedMessages -eq 0 -and
        $after.FailedAttempts -eq 0 -and
        $after.Effects -eq $Backlog -and
        $after.DuplicateEffects -eq 0

    $result = [ordered]@{
        WorkerCount = $WorkerCount
        Backlog = $Backlog
        DrainDurationMilliseconds = $drain.Elapsed.TotalMilliseconds
        DrainMessagesPerSecond = $messagesPerSecond
        AllWorkersParticipated = $allWorkersParticipated
        BeforeWorkers = $before
        AfterDrain = $after
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $variantDirectory "result.json")
    return [pscustomobject]$result
}

function Add-TEL02ScalingMeasurements {
    param([pscustomobject[]]$Variants)

    $baselineMessagesPerSecond = $Variants[0].DrainMessagesPerSecond

    foreach ($variant in $Variants) {
        $speedup = $variant.DrainMessagesPerSecond / $baselineMessagesPerSecond
        $scalingEfficiency = 100 * $speedup / $variant.WorkerCount
        $variant | Add-Member `
            -NotePropertyName "Speedup" `
            -NotePropertyValue ([Math]::Round($speedup, 2))
        $variant | Add-Member `
            -NotePropertyName "ScalingEfficiencyPercentage" `
            -NotePropertyValue ([Math]::Round($scalingEfficiency, 2))
    }
}

function Invoke-TEL02PrebuiltBacklogDrain {
    param(
        [string]$Assembly,
        [int[]]$WorkerCounts,
        [int]$Backlog,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L02"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $variants = @(
        foreach ($workerCount in $WorkerCounts) {
            Invoke-TEL02WorkerCount `
                $Assembly `
                $workerCount `
                $Backlog `
                $scenarioDirectory
        })
    Add-TEL02ScalingMeasurements $variants

    $result = [ordered]@{
        Scenario = "TE-L02"
        Variants = $variants
        AcceptancePassed = $variants.AcceptancePassed -notcontains $false
    }

    $result |
        ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-WorkerDrainLoad.ps1"
    & $runner
}
