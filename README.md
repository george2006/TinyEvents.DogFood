# TinyEvents Dogfood

An executable reliability laboratory for [TinyEvents](https://github.com/george2006/TinyEvents).

This repository does not replace unit or integration tests. It runs real application processes against real SQL Server and PostgreSQL databases, introduces failures from outside the library, and decides success from durable state and process behavior.

> **Status:** Active beta hardening. Every scenario listed as implemented has executable evidence. The complete V1 release gate is still in progress.

This is the dogfood laboratory we are using to earn beta readiness. It is intentionally a work in progress: completed scenarios contain reproducible evidence, while roadmap items remain unproven and are not product guarantees.

The current laboratory demonstrates:

- atomic business-state and outbox persistence;
- competing workers and database-authoritative claims;
- recovery after worker death, lease expiry, and database outages;
- honest at-least-once redelivery boundaries;
- bounded retry and permanent-failure behavior;
- concurrent migration safety;
- equivalent destructive scenarios against SQL Server and PostgreSQL.

## Evidence at a Glance

| Area | Implemented contracts | SQL Server | PostgreSQL | Explore |
| --- | --- | :---: | :---: | --- |
| Identity and compatibility | `TE-C01`–`TE-C06` | ✅ | — | [Identity evidence](identity/README.md) |
| Transactional publishing | `TE-T01`–`TE-T05` | ✅ | ✅ | [Transaction commands](docs/scenario-catalog.md#transactional-publishing) |
| Workers, claims, and retries | `TE-W01`–`TE-W13` | ✅ | `TE-W01` | [Worker commands](docs/scenario-catalog.md#workers-claims-retries-and-shutdown) |
| Database failure and recovery | `TE-D01`–`TE-D06` | ✅ | ✅ | [Recovery commands](docs/scenario-catalog.md#database-failure-and-recovery) |
| Concurrent schema migration | `TE-S01` | ✅ | ✅ | [Schema command](docs/scenario-catalog.md#schema-and-deployment) |

Some contract IDs intentionally share stronger executable evidence instead of duplicating a scenario. The [scenario catalog](docs/scenario-catalog.md) identifies every shared proof explicitly.

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

You do not need to set database environment variables when using the documented runners. Each runner selects its local Docker database and configures its child processes from the `-StorageProvider` argument.

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
- [Scenario catalog](docs/scenario-catalog.md)
- [Beta hardening roadmap](docs/roadmap.md)
- [Identity and compatibility](identity/README.md)
- [Transactions, workers, and database recovery](operations/README.md)
- [Schema and deployment](deployment/README.md)
- [Beta hardening plan and findings](docs/beta-hardening-lab.md)

## Repository Relationship

The dogfood application references the sibling TinyEvents source projects directly while the beta contract is being hardened. Package-consumer acceptance will use locally packed NuGet artifacts before release.

Completed evidence and planned work are documented separately. The catalog describes only behavior demonstrated today; the hardening plan remains explicitly incomplete until the final release gate passes.

## License

TinyEvents Dogfood is licensed under the [MIT License](LICENSE).
