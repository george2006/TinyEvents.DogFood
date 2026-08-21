# TinyEvents Dogfood

An executable reliability laboratory for TinyEvents.

This repository does not replace unit or integration tests. It runs real application processes against real SQL Server and PostgreSQL databases, introduces failures from outside the library, and decides success from durable state and process behavior.

The current laboratory demonstrates:

- atomic business-state and outbox persistence;
- competing workers and database-authoritative claims;
- recovery after worker death, lease expiry, and database outages;
- honest at-least-once redelivery boundaries;
- bounded retry and permanent-failure behavior;
- concurrent migration safety;
- equivalent destructive scenarios against SQL Server and PostgreSQL.

## Quick Start

### Prerequisites

- .NET 8 SDK;
- Docker with Compose support;
- Windows PowerShell 5.1 or PowerShell 7;
- the `TinyEvents` and `TinyEvents.Dogfood` repositories in the same parent directory.

Verify the required tools:

```powershell
dotnet --version
docker compose version
docker info
```

`docker info` must complete successfully before you run a scenario. Start Docker Desktop if it does not.

```text
repos/
  TinyEvents/
  TinyEvents.Dogfood/
```

### Run a Scenario

1. Open PowerShell in the `TinyEvents.Dogfood` repository root.
2. Run the publisher commit-boundary scenario against SQL Server:

```powershell
.\operations\Run-TransactionScenarios.ps1 -Scenario TE-T05
```

3. Run the same scenario against PostgreSQL:

```powershell
.\operations\Run-TransactionScenarios.ps1 -Scenario TE-T05 -StorageProvider PostgreSql
```

Each command starts the required Docker database, builds the real dogfood application, executes the scenario, prints its acceptance result, and writes durable evidence under `artifacts/`.

Expected output:

```text
Scenario AcceptancePassed
-------- ----------------
TE-T05               True
```

`True` and a successful process exit mean every behavioral assertion passed. A violated contract terminates the runner with an error and preserves the evidence needed to investigate it.

## Navigate the Laboratory

- [Run the scenarios](docs/running-scenarios.md)
- [Identity and compatibility](identity/README.md)
- [Transactions, workers, and database recovery](operations/README.md)
- [Schema and deployment](deployment/README.md)
- [Beta hardening plan and findings](docs/beta-hardening-lab.md)

## Repository Relationship

The dogfood application references the sibling TinyEvents source projects directly while the beta contract is being hardened. Package-consumer acceptance will use locally packed NuGet artifacts before release.

This repository is currently private. If it becomes public, verified behavior must remain clearly separated from planned or incomplete work.
