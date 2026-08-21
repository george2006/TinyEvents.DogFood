function New-DogfoodDatabase {
    param(
        [string]$StorageProvider,
        [string]$ComposeFile
    )

    switch ($StorageProvider) {
        "SqlServer" {
            $env:TINYEVENTS_DOGFOOD_STORAGE = "sqlserver"
            $env:TINYEVENTS_DOGFOOD_SQLSERVER = "Server=localhost,14333;Database=TinyEventsDogfoodOperations;User Id=sa;Password=TinyEvents_2026!;Encrypt=False;TrustServerCertificate=True;"

            return [pscustomobject]@{
                ComposeFile = $ComposeFile
                ComposeService = "sqlserver"
                ContainerName = "tinyevents-sqlserver"
                Description = "SQL Server 2022 Docker"
            }
        }

        "PostgreSql" {
            $env:TINYEVENTS_DOGFOOD_STORAGE = "postgresql"
            $env:TINYEVENTS_DOGFOOD_POSTGRESQL = "Host=localhost;Port=54323;Database=TinyEventsDogfoodOperations;Username=postgres;Password=postgres;"

            return [pscustomobject]@{
                ComposeFile = $ComposeFile
                ComposeService = "postgresql"
                ContainerName = "tinyevents-postgresql"
                Description = "PostgreSQL 16 Docker"
            }
        }

        default {
            throw "Unknown dogfood storage provider '$StorageProvider'."
        }
    }
}

function Wait-ForDogfoodDatabase {
    param([pscustomobject]$Database)

    $deadline = (Get-Date).AddMinutes(2)

    while ((Get-Date) -lt $deadline) {
        $health = docker inspect `
            --format "{{.State.Health.Status}}" `
            $Database.ContainerName `
            2>$null

        if ($LASTEXITCODE -eq 0 -and $health -eq "healthy") {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "$($Database.Description) did not become healthy within two minutes."
}

function Start-DogfoodDatabase {
    param([pscustomobject]$Database)

    Invoke-Native "docker" @(
        "compose",
        "-f",
        $Database.ComposeFile,
        "up",
        "-d",
        $Database.ComposeService)
    Wait-ForDogfoodDatabase $Database
}

function Stop-DogfoodDatabase {
    param([pscustomobject]$Database)

    Invoke-Native "docker" @(
        "compose",
        "-f",
        $Database.ComposeFile,
        "stop",
        $Database.ComposeService)
}
