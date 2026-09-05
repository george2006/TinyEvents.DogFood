# TinyEvents Dogfood

An executable reliability laboratory for [TinyEvents](https://github.com/george2006/TinyEvents).

This repository does not replace unit or integration tests. It runs real application processes against real SQL Server and PostgreSQL databases, introduces failures from outside the library, and decides success from durable state and process behavior.

> **Status:** Beta hardening complete. The August 24, 2026 gate passed all 36 mandatory suites and all 543 product tests.

This is the dogfood laboratory used to earn TinyEvents beta readiness. Completed
scenarios contain reproducible evidence; future roadmap items are not product
guarantees.

The current laboratory demonstrates:

- atomic business-state and outbox persistence;
- competing workers and database-authoritative claims;
- recovery after worker death, lease expiry, and database outages;
- honest at-least-once redelivery boundaries;
- bounded retry and permanent-failure behavior;
- concurrent migration safety;
- isolated publishing capacity with exact durable outbox growth;
- equivalent destructive scenarios against SQL Server and PostgreSQL;
- measured backlog recovery while publishing remains active.

## Evidence at a Glance

| Area | Implemented contracts | SQL Server | PostgreSQL | Explore |
| --- | --- | :---: | :---: | --- |
| Identity and compatibility | `TE-C01`–`TE-C08` | ✅ | — | [Identity evidence](identity/README.md) |
| Transactional publishing | `TE-T01`–`TE-T05` | ✅ | ✅ | [Transaction commands](docs/scenario-catalog.md#transactional-publishing) |
| Workers, claims, and retries | `TE-W01`–`TE-W13` | ✅ | ✅ | [Worker commands](docs/scenario-catalog.md#workers-claims-retries-and-shutdown) |
| Database failure and recovery | `TE-D01`–`TE-D06` | ✅ | ✅ | [Recovery commands](docs/scenario-catalog.md#database-failure-and-recovery) |
| Schema and deployment | `TE-S01`–`TE-S05` | ✅ | ✅ | [Schema commands](docs/scenario-catalog.md#schema-and-deployment) |
| Load and storage | `TE-L01`–`TE-L07` | ✅ | ✅ | [Load commands](docs/scenario-catalog.md#load-backlog-and-storage) |

Some contract IDs intentionally share stronger executable evidence instead of duplicating a scenario. The [scenario catalog](docs/scenario-catalog.md) identifies every shared proof explicitly.

The [complete gate record](docs/beta-gate-result-2026-08-24.md) preserves the
tested revisions, suite matrix, representative measurements, accepted
at-least-once evidence, and remaining release boundary.

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
- [Evidence roadmap](docs/roadmap.md)
- [Complete beta gate result](docs/beta-gate-result-2026-08-24.md)
- [V1 product findings and operational boundaries](docs/v1-product-findings.md)
- [Beta findings index](docs/findings-index.md)
- [Identity and compatibility](identity/README.md)
- [Transactions, workers, and database recovery](operations/README.md)
- [Schema and deployment](deployment/README.md)
- [Hardening contract and engineering record](docs/beta-hardening-lab.md)
- [Run tests on AWS](cloud/aws/README.md)

## Repository Relationship

The destructive scenarios reference the sibling TinyEvents source projects
directly while the beta contract is being hardened. The separate package smoke
packs all six supported packages, restores them through an isolated NuGet cache,
and runs the SQL Server and PostgreSQL EF Core and ADO.NET paths without project
references.

Completed evidence and future work are documented separately. The catalog
describes only demonstrated behavior; the roadmap does not turn future ideas
into current guarantees.

## License

TinyEvents Dogfood is licensed under the [MIT License](LICENSE).
