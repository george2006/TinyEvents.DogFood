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
                ConnectionStringVariable = "TINYEVENTS_DOGFOOD_SQLSERVER"
                PoolSizeSetting = "Max Pool Size"
                ConnectionTimeoutSetting = "Connect Timeout"
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
                ConnectionStringVariable = "TINYEVENTS_DOGFOOD_POSTGRESQL"
                PoolSizeSetting = "Maximum Pool Size"
                ConnectionTimeoutSetting = "Timeout"
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

function Get-DogfoodDatabaseConnectionCount {
    param([pscustomobject]$Database)

    $output = switch ($Database.ComposeService) {
        "sqlserver" {
            docker exec `
                $Database.ContainerName `
                /opt/mssql-tools18/bin/sqlcmd `
                -C `
                -S localhost `
                -U sa `
                -P "TinyEvents_2026!" `
                -d TinyEventsDogfoodOperations `
                -h -1 `
                -W `
                -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1 AND database_id = DB_ID();"
        }

        "postgresql" {
            docker exec `
                $Database.ContainerName `
                psql `
                -U postgres `
                -d TinyEventsDogfoodOperations `
                -tAc "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = current_database();"
        }

        default {
            throw "Database connection observation does not support '$($Database.ComposeService)'."
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Could not observe active connections for $($Database.Description)."
    }

    $connectionCount = 0
    $hasConnectionCount = [int]::TryParse(
        $output.Trim(),
        [ref]$connectionCount)

    if (!$hasConnectionCount) {
        throw "Database connection observation returned '$output'."
    }

    return $connectionCount
}
