# Running TinyEvents Dogfood Scenarios

This guide explains the common execution model. The suite-specific guides describe each observable contract and its result.

## Prerequisites

Run these commands from PowerShell:

```powershell
dotnet --version
docker compose version
docker info
```

You need the .NET 8 SDK and a running Docker engine. The first scenario may take longer because Docker must download the SQL Server or PostgreSQL image.

The repositories must be siblings:

```text
repos/
  TinyEvents/
  TinyEvents.Dogfood/
```

## Safety Boundary

The scenarios are destructive laboratory programs. They recreate databases, stop Docker database containers, terminate application processes, exhaust connection pools, and intentionally produce duplicate consumer invocations.

Run them only against the local Docker services defined by the sibling TinyEvents repository. Do not override the dogfood connection variables with production or shared-development databases.

The current database names are:

- `TinyEventsDogfoodOperations` for operational scenarios;
- `TinyEventsDogfoodIdentity` for identity scenarios.

## Provider Selection

You do not set connection environment variables before running the documented scripts. The top-level runner owns that setup for its local Docker database.

Provider-aware runners accept `-StorageProvider SqlServer` or `-StorageProvider PostgreSql`. SQL Server is the default, so both commands below are equivalent:

```powershell
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D03
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D03 -StorageProvider SqlServer
```

To run PostgreSQL, select it explicitly:

```powershell
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D03 -StorageProvider PostgreSql
```

The runner is the composition root. It:

1. selects the Docker service and local connection string;
2. sets `TINYEVENTS_DOGFOOD_STORAGE` and the selected provider's connection variable;
3. starts the required database container;
4. launches child `dotnet` processes.

Child processes inherit those environment variables. `DogfoodSettings` selects one storage-provider implementation and loads its settings. Individual scenario scripts therefore receive the executable and artifact paths, not database credentials.

The variables below are an internal boundary between a runner and the application processes it starts. They are documented for troubleshooting and direct application-host development, not as normal setup steps. Do not point them at production or shared-development databases.

The variables are:

| Purpose | Variable |
| --- | --- |
| Provider selection | `TINYEVENTS_DOGFOOD_STORAGE` |
| SQL Server connection | `TINYEVENTS_DOGFOOD_SQLSERVER` |
| PostgreSQL connection | `TINYEVENTS_DOGFOOD_POSTGRESQL` |

## Running a Suite or One Scenario

Run all scenarios owned by a runner by omitting `-Scenario` or passing `all`:

```powershell
.\operations\Run-DatabaseRecovery.ps1
```

Run one scenario by its stable ID:

```powershell
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D04
```

Most named scenario files can also be executed directly. Direct execution delegates to the owning runner so setup, assertions, and artifact creation remain identical:

```powershell
.\operations\scenarios\TE-D04-database-disappears-while-marking-processed.ps1
```

Direct scenario files use their runner's default provider. Use the owning runner with `-StorageProvider PostgreSql` when you want PostgreSQL.

## Available Runners

| Area | Runner | Provider support |
| --- | --- | --- |
| Event identity | `identity/Run-IdentityScenarios.ps1` | SQL Server |
| Commit and single-worker baseline | `operations/Run-OperationalBaseline.ps1` | SQL Server, PostgreSQL |
| Transaction boundaries | `operations/Run-TransactionScenarios.ps1` | SQL Server, PostgreSQL |
| Competing workers | `operations/Run-WorkerScaling.ps1` | SQL Server |
| Claims, death, retries, and shutdown | `operations/Run-WorkerRecovery.ps1` | SQL Server |
| Database failure and recovery | `operations/Run-DatabaseRecovery.ps1` | SQL Server, PostgreSQL |
| Sustained publishing load | `operations/Run-PublishingLoad.ps1` | SQL Server, PostgreSQL |
| Prebuilt backlog drain | `operations/Run-WorkerDrainLoad.ps1` | SQL Server, PostgreSQL |
| Sustained mixed load | `operations/Run-MixedLoad.ps1` | SQL Server, PostgreSQL |
| Live backlog recovery | `operations/Run-BacklogRecoveryLoad.ps1` | SQL Server, PostgreSQL |
| Pending payload storage (`TE-L05-A`) | `operations/Run-StorageMeasurements.ps1` | SQL Server, PostgreSQL |
| Outbox state storage (`TE-L05-B`) | `operations/Run-StorageStateMeasurements.ps1` | SQL Server, PostgreSQL |
| Schema and deployment | `deployment/Run-SchemaScenarios.ps1` | SQL Server, PostgreSQL |
| Published-alpha and rolling upgrades | `deployment/Run-RollingUpgrade.ps1` | SQL Server, PostgreSQL |

Provider support in this table describes executable evidence, not an unsupported TinyEvents product path. A scenario is enabled for a second provider only after the same behavioral assertions pass unchanged.

See the [scenario catalog](scenario-catalog.md) for the exact command and expected result of every implemented scenario.

## Evidence and Exit Codes

Every run creates a timestamped directory beneath `artifacts/`. Depending on the suite, it contains:

- a run manifest with repository commits, SDK, database engine, and timestamps;
- one `result.json` per scenario;
- durable observations captured at important boundaries;
- stdout and stderr from every child process;
- the final `AcceptancePassed` result.

The runner exits successfully only when every selected scenario satisfies its complete acceptance contract. A failure points to the artifact directory and leaves the captured evidence in place.

Artifacts are intentionally ignored by Git. They are evidence for a particular execution and machine, not source-controlled fixtures.

## After a Run

The database containers remain available so you can inspect them or run another scenario. Stop them from the `TinyEvents.Dogfood` repository root when you finish:

```powershell
docker compose -f ..\TinyEvents\docker-compose.yml stop sqlserver postgresql
```

## Troubleshooting

### PowerShell blocks script execution

Allow local scripts only for the current PowerShell process:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then run the scenario again from the repository root.

### Docker is unavailable

Run `docker info`. If it fails, start Docker Desktop and wait until the engine is ready.

### A scenario fails

Do not delete its artifacts. Read the error's evidence path, then inspect `result.json`, the saved observations, and the child-process stdout and stderr files in that directory.

## Current Source Layout

Until hardened packages are produced, the dogfood projects reference the sibling TinyEvents source tree. This makes every scenario exercise the exact local code under review.

Before release, a separate package-consumer gate will build NuGet packages locally and repeat the public installation path without project references.
