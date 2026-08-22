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

Run one independently addressable scenario with `-Scenario <scenario-id>`.

| Scenario | Behavior |
|---|---|
| `TE-S01` | Eight application processes migrate one fresh SQL Server or PostgreSQL database concurrently and produce one exact committed history. |
| `TE-S03` | A migration process dies while blocked inside database DDL, then a replacement safely resumes from the durable atomic boundary. |
| `TE-S04` | Missing and incompatible schemas produce the documented recovery or actionable rejection behavior. |
| `TE-S05` | Published alpha and clean-main application processes concurrently drain one shared backlog without loss or duplicate effects. |

TE-S01 first recreates the dogfood database without the TinyEvents schema. Eight independently hosted migrators then start together. Every process must complete successfully, while the final database contains the outbox and exactly one `001_CreateTinyOutbox` history row with its durable checksum and application timestamp.

The unchanged scenario passed against SQL Server and PostgreSQL on 2026-08-21.

Evidence is retained under `artifacts/schema/<run-id>/`.

## Interrupted Migration Recovery

Run the process-death scenario against either provider:

```powershell
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S03
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S03 -StorageProvider PostgreSql
```

`TE-S03` installs a temporary database-side DDL interruption, starts the real TinyEvents migrator, and waits until the database proves that one migrator is blocked inside DDL while holding the provider migration lock. Only then does the runner terminate the application process.

The scenario waits for the database to release the abandoned session lock before inspecting durable state. The interrupted transaction may leave no schema, an empty migration-history table, or a completely committed migration; all are safe atomic boundaries. An outbox without its matching history entry, or a history entry without its outbox, fails acceptance. After removing the external interruption, a second process must finish with one exact `001_CreateTinyOutbox` history row.

The DDL trigger/event trigger belongs only to the dogfood fault injector. It is removed in a `finally` block and is not part of TinyEvents production code.

## Missing or Incompatible Schema

Run the schema-compatibility scenario against either provider:

```powershell
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S04
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S04 -StorageProvider PostgreSql
```

`TE-S04` starts from three independently prepared durable states. A completely missing TinyEvents schema must migrate successfully. A current migration-history row whose physical outbox table is missing must fail without claiming the schema is current. A history row with a conflicting checksum must also fail. Both incompatible states must identify the problem and relevant migration or table in stderr.

The scenario passed unchanged against SQL Server and PostgreSQL on 2026-08-22 using TinyEvents `main` commit `4612c24`.

## Rolling Application Upgrade

Run both published-alpha and rolling-upgrade evidence with a clean TinyEvents `main` checkout:

```powershell
.\deployment\Run-RollingUpgrade.ps1 -CandidateRoot ..\TinyEvents
```

`TE-S05` first runs TE-S02 to create package-only assemblies for published `0.1.0-alpha.3` and the clean-main candidate. It then creates a separate 100-message alpha backlog for each provider and starts one alpha process and one candidate process concurrently against the same database.

Acceptance is decided from durable state: all 100 messages must be processed, both worker identities must appear, every message must have one distinct operation effect, no message may remain pending or processing, no failure may exist, and migration history must contain one row. Process stdout identifies execution details but is not acceptance authority.

The unchanged contract passed against SQL Server and PostgreSQL on 2026-08-22 using candidate commit `4612c24`.

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
