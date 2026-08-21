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

function Start-SqlServer {
    param([string]$ComposeFile)

    Invoke-Native "docker" @(
        "compose",
        "-f",
        $ComposeFile,
        "up",
        "-d",
        "sqlserver")
    Wait-ForSqlServer
}

function Stop-SqlServer {
    param([string]$ComposeFile)

    Invoke-Native "docker" @(
        "compose",
        "-f",
        $ComposeFile,
        "stop",
        "sqlserver")
}
