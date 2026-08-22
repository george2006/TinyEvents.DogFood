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

## Published Alpha Upgrade — Work in Progress

TE-S02 is intentionally split into reviewable checkpoints. Run its completed alpha-state checkpoint with:

```powershell
.\deployment\Run-PublishedAlphaUpgrade.ps1
```

`TE-S02-A` restores the package-consuming host from nuget.org with an isolated package cache, compiles it against published `0.1.0-alpha.3`, and uses the package's public publisher, store, and migration APIs to create:

- one pending message;
- one processing message whose lease is reclaimable;
- one terminally failed message with one recorded attempt;
- one exact durable event type and migration history row;
- no consumer effects before the candidate starts.

The runner stores `result.json` and `manifest.json` under `artifacts/deployment/<run-id>/TE-S02/`. The result deliberately reports `TeS02Complete = false`. TE-S02 remains pending until a locally packed candidate from clean `main` migrates and drains the supported alpha state, and the same contract passes against PostgreSQL.
