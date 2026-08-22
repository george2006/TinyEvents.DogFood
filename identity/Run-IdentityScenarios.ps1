param(
    [ValidateSet("All", "TE-C01", "TE-C02", "TE-C03", "TE-C04", "TE-C05", "TE-C06")]
    [string]$Scenario = "All"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Wait-ForSqlServer {
    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $health = docker inspect --format "{{.State.Health.Status}}" tinyevents-sqlserver 2>$null

        if ($LASTEXITCODE -eq 0 -and $health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "SQL Server did not become healthy within two minutes."
}

function Wait-ForTerminalObservation {
    param(
        [string]$ProducerAssembly,
        [System.Diagnostics.Process]$WorkerProcess
    )

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($WorkerProcess.HasExited) {
            throw "Identity worker exited before the scenario reached a terminal state. Exit code: $($WorkerProcess.ExitCode)."
        }

        $json = & dotnet $ProducerAssembly inspect

        if ($LASTEXITCODE -ne 0) {
            throw "Identity observation command failed."
        }

        $observation = $json | ConvertFrom-Json

        if ($observation.Status -in @("Processed", "Failed")) {
            return $observation
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Identity scenario did not reach a terminal state within 20 seconds."
}

function Invoke-IdentityScenario {
    param(
        [pscustomobject]$Definition,
        [string]$ProducerAssembly,
        [string]$WorkerAssembly,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory $Definition.Id
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    Invoke-Native "dotnet" @($ProducerAssembly, "reset")
    Invoke-Native "dotnet" @(
        $ProducerAssembly,
        "publish",
        $Definition.EventKind,
        $Definition.Id)

    $standardOutput = Join-Path $scenarioDirectory "worker.stdout.log"
    $standardError = Join-Path $scenarioDirectory "worker.stderr.log"
    $workerStart = @{
        FilePath = "dotnet"
        ArgumentList = @($WorkerAssembly)
        RedirectStandardOutput = $standardOutput
        RedirectStandardError = $standardError
        WindowStyle = "Hidden"
        PassThru = $true
    }
    $worker = Start-Process @workerStart

    try {
        $observation = Wait-ForTerminalObservation -ProducerAssembly $ProducerAssembly -WorkerProcess $worker
    }
    finally {
        if (-not $worker.HasExited) {
            Stop-Process -Id $worker.Id
            $worker.WaitForExit()
        }
    }

    $matchesStatus = $observation.Status -eq $Definition.ExpectedStatus
    $matchesEffects = $observation.EffectCount -eq $Definition.ExpectedEffects
    $matchesObservedValue = $observation.ObservedValue -eq $Definition.ExpectedObservedValue
    $passed = $matchesStatus -and $matchesEffects -and $matchesObservedValue

    $result = [ordered]@{
        Scenario = $Definition.Id
        Contract = $Definition.Contract
        ExpectedStatus = $Definition.ExpectedStatus
        ExpectedEffects = $Definition.ExpectedEffects
        ExpectedObservedValue = $Definition.ExpectedObservedValue
        Actual = $observation
        AcceptancePassed = $passed
        ProductSupport = $Definition.ProductSupport
    }

    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Invoke-GenericRejectionScenario {
    param(
        [pscustomobject]$Definition,
        [string]$GenericProbeProject,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory $Definition.Id
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null
    $standardOutput = Join-Path $scenarioDirectory "build.stdout.log"
    $standardError = Join-Path $scenarioDirectory "build.stderr.log"
    $buildStart = @{
        FilePath = "dotnet"
        ArgumentList = @("build", $GenericProbeProject, "-c", "Release")
        RedirectStandardOutput = $standardOutput
        RedirectStandardError = $standardError
        WindowStyle = "Hidden"
        Wait = $true
        PassThru = $true
    }
    $build = Start-Process @buildStart
    $buildExitCode = $build.ExitCode
    [string]$buildOutput = (Get-Content -LiteralPath $standardOutput -Raw) + (Get-Content -LiteralPath $standardError -Raw)
    $diagnosticObserved = $buildOutput.IndexOf("TEV002", [StringComparison]::Ordinal) -ge 0
    $passed = $buildExitCode -ne 0 -and $diagnosticObserved

    $actual = [ordered]@{
        Status = if ($passed) { "Rejected" } else { "Unexpected" }
        BuildExitCode = $buildExitCode
        Diagnostic = if ($diagnosticObserved) { "TEV002" } else { $null }
    }
    $result = [ordered]@{
        Scenario = $Definition.Id
        Contract = $Definition.Contract
        ExpectedStatus = $Definition.ExpectedStatus
        ExpectedEffects = $Definition.ExpectedEffects
        Actual = $actual
        AcceptancePassed = $passed
        ProductSupport = $Definition.ProductSupport
    }

    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

function Get-GitCommit {
    param([string]$Repository)

    $previousErrorPreference = $ErrorActionPreference
    $commit = $null
    $exitCode = 1

    try {
        $ErrorActionPreference = "SilentlyContinue"
        $commit = git -C $Repository rev-parse HEAD 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }

    if ($exitCode -ne 0) {
        return "uncommitted"
    }

    return $commit
}

$dogfoodRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tinyEventsRoot = Resolve-Path (Join-Path $dogfoodRoot "..\TinyEvents")
$composeFile = Join-Path $tinyEventsRoot "docker-compose.yml"
$producerProject = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Identity.Producer\TinyEvents.Dogfood.Identity.Producer.csproj"
$workerProject = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Identity.Worker\TinyEvents.Dogfood.Identity.Worker.csproj"
$genericProbeProject = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Identity.GenericProbe\TinyEvents.Dogfood.Identity.GenericProbe.csproj"
$producerAssembly = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Identity.Producer\bin\Release\net8.0\TinyEvents.Dogfood.Identity.Producer.dll"
$workerAssembly = Join-Path $PSScriptRoot "TinyEvents.Dogfood.Identity.Worker\bin\Release\net8.0\TinyEvents.Dogfood.Identity.Worker.dll"
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$startedAtUtc = [DateTimeOffset]::UtcNow
$artifactDirectory = Join-Path $dogfoodRoot "artifacts\identity\$runId"

$env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodIdentity;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

$definitions = @(
    [pscustomobject]@{ Id = "TE-C01"; EventKind = "normal"; Contract = "Shared top-level contract"; ExpectedStatus = "Processed"; ExpectedEffects = 1; ExpectedObservedValue = $null; ProductSupport = "Supported" },
    [pscustomobject]@{ Id = "TE-C02"; EventKind = "nested"; Contract = "Nested contract"; ExpectedStatus = "Processed"; ExpectedEffects = 1; ExpectedObservedValue = $null; ProductSupport = "Supported" },
    [pscustomobject]@{ Id = "TE-C03"; EventKind = $null; Contract = "Closed generic contract"; ExpectedStatus = "Rejected"; ExpectedEffects = 0; ExpectedObservedValue = $null; ProductSupport = "Rejected by design" },
    [pscustomobject]@{ Id = "TE-C04"; EventKind = "renamed"; Contract = "Namespace rename with same type name"; ExpectedStatus = "Processed"; ExpectedEffects = 1; ExpectedObservedValue = $null; ProductSupport = "Supported through explicit previous name" },
    [pscustomobject]@{ Id = "TE-C05"; EventKind = "moved"; Contract = "Same full name moved between assemblies"; ExpectedStatus = "Processed"; ExpectedEffects = 1; ExpectedObservedValue = $null; ProductSupport = "Supported" },
    [pscustomobject]@{ Id = "TE-C06"; EventKind = "additive"; Contract = "V1 payload consumed by V2 contract with optional member"; ExpectedStatus = "Processed"; ExpectedEffects = 1; ExpectedObservedValue = "not-provided"; ProductSupport = "Supported" }
)

if ($Scenario -ne "All") {
    $definitions = @($definitions | Where-Object { $_.Id -eq $Scenario })
}

New-Item -ItemType Directory -Force -Path $artifactDirectory | Out-Null

Invoke-Native "docker" @("compose", "-f", $composeFile, "up", "-d", "sqlserver")
Wait-ForSqlServer
Invoke-Native "dotnet" @("build", $producerProject, "-c", "Release")
Invoke-Native "dotnet" @("build", $workerProject, "-c", "Release")

$results = foreach ($definition in $definitions) {
    if ($definition.Id -eq "TE-C03") {
        $genericArguments = @{
            Definition = $definition
            GenericProbeProject = $genericProbeProject
            ArtifactDirectory = $artifactDirectory
        }
        Invoke-GenericRejectionScenario @genericArguments
        continue
    }

    $scenarioArguments = @{
        Definition = $definition
        ProducerAssembly = $producerAssembly
        WorkerAssembly = $workerAssembly
        ArtifactDirectory = $artifactDirectory
    }
    Invoke-IdentityScenario @scenarioArguments
}

$manifest = [ordered]@{
    RunId = $runId
    StartedAtUtc = $startedAtUtc
    CompletedAtUtc = [DateTimeOffset]::UtcNow
    StartedBy = $env:USERNAME
    Machine = $env:COMPUTERNAME
    DogfoodGitCommit = Get-GitCommit -Repository $dogfoodRoot
    TinyEventsGitCommit = Get-GitCommit -Repository $tinyEventsRoot
    DotNetSdk = (dotnet --version)
    DatabaseEngine = "SQL Server 2022 Docker"
    Scenarios = $results
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $artifactDirectory "manifest.json")
$results | Format-Table Scenario, Contract, ExpectedStatus, @{ Label = "ActualStatus"; Expression = { $_.Actual.Status } }, AcceptancePassed, ProductSupport

if ($results.AcceptancePassed -contains $false) {
    throw "One or more identity scenarios violated the beta acceptance contract. Evidence: $artifactDirectory"
}

Write-Host "Identity acceptance completed. Evidence: $artifactDirectory"
