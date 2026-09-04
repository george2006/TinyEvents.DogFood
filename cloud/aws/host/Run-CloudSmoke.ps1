[CmdletBinding()]
param(
    [string]$DogfoodRoot = "/opt/tinyevents-lab/sources/TinyEvents.Dogfood",
    [string]$ArtifactRoot = "/opt/tinyevents-lab/artifacts",
    [ValidateRange(1, 10000)][int]$MessageCount = 100
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$env:TINYEVENTS_DOGFOOD_STORAGE = "postgresql"
$env:TINYEVENTS_DOGFOOD_POSTGRESQL = "Host=localhost;Port=54323;Database=TinyEventsDogfoodOperations;Username=postgres;Password=postgres;Maximum Pool Size=16;Timeout=2;"

$assembly = Join-Path $DogfoodRoot "operations/TinyEvents.Dogfood.Operations/bin/Release/net8.0/TinyEvents.Dogfood.Operations.dll"
if (!(Test-Path -LiteralPath $assembly)) {
    throw "Dogfood assembly '$assembly' was not found."
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runDirectory = Join-Path $ArtifactRoot "smoke-$runId"
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null

function Invoke-Dogfood {
    param([string[]]$Arguments)

    $output = & dotnet $assembly @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Dogfood command '$($Arguments -join ' ')' failed."
    }

    return $output
}

$startedAtUtc = [DateTimeOffset]::UtcNow
Invoke-Dogfood @("reset") | Out-Null
Invoke-Dogfood @("publish", "TE-CLOUD-SMOKE", [string]$MessageCount) | Out-Null
$before = Invoke-Dogfood @("inspect") | ConvertFrom-Json

$workerOutput = Join-Path $runDirectory "worker.stdout.log"
$workerError = Join-Path $runDirectory "worker.stderr.log"
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = "dotnet"
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Arguments =
    "`"$assembly`" worker TE-CLOUD-SMOKE-worker-1 0 0"
$worker = [Diagnostics.Process]::new()
$worker.StartInfo = $startInfo

if (!$worker.Start()) {
    throw "Smoke worker could not be started."
}

$outputTask = $worker.StandardOutput.ReadToEndAsync()
$errorTask = $worker.StandardError.ReadToEndAsync()

try {
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(3)
    do {
        if ($worker.HasExited) {
            throw "Smoke worker exited before the backlog drained."
        }

        $outstanding = Invoke-Dogfood @("has-outstanding-messages") | ConvertFrom-Json
        if (!$outstanding) {
            break
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    if ($outstanding) {
        throw "Smoke backlog did not drain within three minutes."
    }

    $after = Invoke-Dogfood @("inspect") | ConvertFrom-Json
}
finally {
    if (!$worker.HasExited) {
        $killTreeMethod = $worker.GetType().GetMethods() |
            Where-Object {
                $_.Name -eq "Kill" -and
                $_.GetParameters().Count -eq 1
            } |
            Select-Object -First 1

        if ($null -ne $killTreeMethod) {
            $worker.Kill($true)
        }
        else {
            $worker.Kill()
        }
    }

    $worker.WaitForExit()
    $outputTask.GetAwaiter().GetResult() | Set-Content -LiteralPath $workerOutput
    $errorTask.GetAwaiter().GetResult() | Set-Content -LiteralPath $workerError
    $worker.Dispose()
}

$passed =
    $before.PendingMessages -eq $MessageCount -and
    $after.BusinessOperations -eq $MessageCount -and
    $after.OutboxMessages -eq $MessageCount -and
    $after.PendingMessages -eq 0 -and
    $after.ProcessingMessages -eq 0 -and
    $after.ProcessedMessages -eq $MessageCount -and
    $after.FailedMessages -eq 0 -and
    $after.FailedAttempts -eq 0 -and
    $after.Effects -eq $MessageCount -and
    $after.DuplicateEffects -eq 0

$result = [ordered]@{
    Scenario = "TE-CLOUD-SMOKE"
    StartedAtUtc = $startedAtUtc.ToString("O")
    CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString("O")
    StorageProvider = "PostgreSql"
    MessageCount = $MessageCount
    Before = $before
    After = $after
    AcceptancePassed = $passed
}
$resultPath = Join-Path $runDirectory "result.json"
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath

if (!$passed) {
    throw "Cloud smoke acceptance failed. Evidence: $resultPath"
}

Write-Output $resultPath
