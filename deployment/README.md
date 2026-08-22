# Schema and Deployment Dogfood

This laboratory executes destructive schema and deployment scenarios against real application processes and Docker-hosted databases.

For commands across every implemented area, see the [scenario catalog](../docs/scenario-catalog.md).

Run the current suite from the repository root:

```powershell
.\deployment\Run-SchemaScenarios.ps1
```

Select PostgreSQL without changing the scenario or its acceptance rules:

```powershell
.\deployment\Run-SchemaScenarios.ps1 -StorageProvider PostgreSql
```

Run one independently addressable scenario with `-Scenario TE-S01`.

| Scenario | Behavior |
|---|---|
| `TE-S01` | Eight application processes migrate one fresh SQL Server or PostgreSQL database concurrently and produce one exact committed history. |

TE-S01 first recreates the dogfood database without the TinyEvents schema. Eight independently hosted migrators then start together. Every process must complete successfully, while the final database contains the outbox and exactly one `001_CreateTinyOutbox` history row with its durable checksum and application timestamp.

The unchanged scenario passed against SQL Server and PostgreSQL on 2026-08-21.

Evidence is retained under `artifacts/schema/<run-id>/`.

## Published Alpha Upgrade

Run the complete SQL Server and PostgreSQL upgrade contract with:

```powershell
.\deployment\Run-PublishedAlphaUpgrade.ps1
```

By default, the runner expects a clean TinyEvents `main` checkout beside this repository. Pass `-CandidateRoot <path>` when the clean checkout lives elsewhere. The runner refuses a candidate that is not on `main` or has uncommitted files.

`TE-S02-A` restores the package-consuming host from nuget.org with an isolated package cache, compiles it against published `0.1.0-alpha.3`, and uses the package's public publisher, store, and migration APIs to create:

- one pending message;
- one processing message whose lease is reclaimable;
- one terminally failed message with one recorded attempt;
- one exact durable event type and migration history row;
- no consumer effects before the candidate starts.

`TE-S02-B` then builds and packs the release train from clean `main`, restores the same host only from those local candidate packages, migrates the SQL Server database, and runs the real outbox processor once. `TE-S02-C` applies the unchanged contract to PostgreSQL. Acceptance requires the pending row and expired processing row to become processed with one effect each, while the terminally failed row, attempt count, and error remain unchanged. Each provider's migration history must still contain exactly one row.

The runner stores alpha-state and result files per provider, plus the overall `result.json` and `manifest.json`, under `artifacts/deployment/<run-id>/TE-S02/`. It reports `TeS02Complete = true` only when both providers satisfy the complete upgrade contract in the same run.
