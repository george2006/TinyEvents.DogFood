function Start-TED06Publisher {
    param(
        [string]$Assembly,
        [string]$ScenarioId,
        [int]$MessageCount,
        [int]$PublisherNumber,
        [string]$ArtifactDirectory
    )

    $publisherName = "publisher-$PublisherNumber"
    $standardOutput = Join-Path $ArtifactDirectory "$publisherName.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$publisherName.stderr.log"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "dotnet"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments =
        "`"$Assembly`" publish `"$ScenarioId`" $MessageCount"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (!$process.Start()) {
        throw "Publisher '$publisherName' could not be started."
    }

    return [pscustomobject]@{
        Name = $publisherName
        Process = $process
        OutputPath = $standardOutput
        ErrorPath = $standardError
        OutputTask = $process.StandardOutput.ReadToEndAsync()
        ErrorTask = $process.StandardError.ReadToEndAsync()
    }
}

function Wait-ForTED06Publishers {
    param([pscustomobject[]]$Publishers)

    foreach ($publisher in $Publishers) {
        $process = $publisher.Process

        if (!$process.WaitForExit(30000)) {
            throw "Publisher '$($publisher.Name)' did not finish within thirty seconds."
        }

        $process.WaitForExit()
        $process.Refresh()
        $standardOutput = $publisher.OutputTask.GetAwaiter().GetResult()
        $standardError = $publisher.ErrorTask.GetAwaiter().GetResult()
        $standardOutput | Set-Content $publisher.OutputPath
        $standardError | Set-Content $publisher.ErrorPath

        if ($process.ExitCode -ne 0) {
            throw "Publisher '$($publisher.Name)' failed with exit code $($process.ExitCode)."
        }
    }
}

function Wait-ForTED06Drain {
    param(
        [string]$Assembly,
        [System.Diagnostics.Process[]]$Workers,
        [int]$ExpectedMessageCount
    )

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $exitedWorker = $Workers |
            Where-Object { $_.HasExited } |
            Select-Object -First 1

        if ($null -ne $exitedWorker) {
            throw "Worker process $($exitedWorker.Id) exited before draining the connection-pressure backlog. Exit code: $($exitedWorker.ExitCode)."
        }

        $observation = Get-Observation -Assembly $Assembly

        if ($observation.PendingMessages -eq 0 -and
            $observation.ProcessingMessages -eq 0 -and
            $observation.ProcessedMessages -eq $ExpectedMessageCount) {
            return $observation
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Workers did not drain $ExpectedMessageCount messages within two minutes."
}

function Test-TED06WorkerParticipation {
    param(
        [pscustomobject]$Observation,
        [string[]]$WorkerIds
    )

    if (@($Observation.WorkerClaims.PSObject.Properties).Count -ne $WorkerIds.Count -or
        @($Observation.WorkerEffects.PSObject.Properties).Count -ne $WorkerIds.Count) {
        return $false
    }

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

    return $true
}

function Invoke-TED06BoundedConnectionPressure {
    param(
        [string]$Assembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-D06"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $maxPoolSize = 2
    $heldConnectionsPerWorker = 2
    $pressureDurationMilliseconds = 8000
    $publisherCount = 4
    $messagesPerPublisher = 25
    $expectedMessageCount = $publisherCount * $messagesPerPublisher
    $originalConnectionString = $env:TINYEVENTS_DOGFOOD_SQLSERVER
    $env:TINYEVENTS_DOGFOOD_SQLSERVER =
        "$originalConnectionString;Max Pool Size=$maxPoolSize;Connect Timeout=1;"
    $workers = @()

    try {
        Invoke-LoggedProcess $Assembly @("reset") $scenarioDirectory "reset"

        $workerIds = @("TE-D06-worker-1", "TE-D06-worker-2")
        $workers = @(
            foreach ($workerId in $workerIds) {
                Start-WorkerUnderPressure `
                    $Assembly `
                    $workerId `
                    $heldConnectionsPerWorker `
                    $pressureDurationMilliseconds `
                    $scenarioDirectory
            }
        )

        foreach ($index in 0..($workers.Count - 1)) {
            $workerLog = Join-Path $scenarioDirectory "$($workerIds[$index]).stdout.log"
            Wait-ForLogText `
                $workers[$index] `
                $workerLog `
                "Connection pool pressure acquired $heldConnectionsPerWorker connections." `
                "Connection-pressure worker"
            Wait-ForLogText `
                $workers[$index] `
                $workerLog `
                "processing iteration failed" `
                "Connection-pressure worker"
        }

        $publishers = @(
            foreach ($publisherNumber in 1..$publisherCount) {
                Start-TED06Publisher `
                    $Assembly `
                    "TE-D06" `
                    $messagesPerPublisher `
                    $publisherNumber `
                    $scenarioDirectory
            }
        )
        Wait-ForTED06Publishers $publishers

        $published = Get-Observation -Assembly $Assembly
        Save-Observation $published $scenarioDirectory "published-under-pressure"

        $completed = Wait-ForTED06Drain `
            $Assembly `
            $workers `
            $expectedMessageCount
        Save-Observation $completed $scenarioDirectory "completed"

        foreach ($index in 0..($workers.Count - 1)) {
            $workerLog = Join-Path $scenarioDirectory "$($workerIds[$index]).stdout.log"
            Wait-ForLogText `
                $workers[$index] `
                $workerLog `
                "Connection pool pressure released." `
                "Connection-pressure worker"
            Wait-ForLogText `
                $workers[$index] `
                $workerLog `
                "TinyEvents worker recovered after" `
                "Connection-pressure worker"
        }

        $workersSurvived =
            @($workers | Where-Object { !$_.HasExited }).Count -eq $workerIds.Count
    }
    finally {
        foreach ($worker in $workers) {
            Stop-Worker $worker
        }

        $env:TINYEVENTS_DOGFOOD_SQLSERVER = $originalConnectionString
    }

    $failureCountsByWorker = [ordered]@{}

    foreach ($workerId in $workerIds) {
        $workerLog = Join-Path $scenarioDirectory "$workerId.stdout.log"
        $failureCountsByWorker[$workerId] = Get-WorkerFailureLogCounts $workerLog
    }

    $bothWorkersObservedPoolExhaustion =
        ($failureCountsByWorker[$workerIds[0]] -contains 1) -and
        ($failureCountsByWorker[$workerIds[1]] -contains 1)
    $bothWorkersParticipated = Test-TED06WorkerParticipation $completed $workerIds
    $passed =
        $workersSurvived -and
        $bothWorkersObservedPoolExhaustion -and
        $bothWorkersParticipated -and
        $completed.BusinessOperations -eq $expectedMessageCount -and
        $completed.OutboxMessages -eq $expectedMessageCount -and
        $completed.PendingMessages -eq 0 -and
        $completed.ProcessingMessages -eq 0 -and
        $completed.ProcessedMessages -eq $expectedMessageCount -and
        $completed.FailedMessages -eq 0 -and
        $completed.FailedAttempts -eq 0 -and
        $completed.Effects -eq $expectedMessageCount -and
        $completed.DuplicateEffects -eq 0

    $result = [ordered]@{
        Scenario = "TE-D06"
        PublisherProcesses = $publisherCount
        WorkerProcesses = $workerIds.Count
        MaxPoolSizePerProcess = $maxPoolSize
        HeldConnectionsPerWorker = $heldConnectionsPerWorker
        BothWorkersObservedPoolExhaustion = $bothWorkersObservedPoolExhaustion
        BothWorkersParticipated = $bothWorkersParticipated
        WorkersSurvived = $workersSurvived
        LoggedFailureCountsByWorker = $failureCountsByWorker
        ObservationDuringPressure = $published
        ObservationAfterRecovery = $completed
        AcceptancePassed = $passed
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) "Run-DatabaseRecovery.ps1"
    & $runner -Scenario "TE-D06"
}
