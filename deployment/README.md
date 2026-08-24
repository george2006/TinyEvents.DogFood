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

TE-S01 first recreates the dogfood database without the TinyEvents schema. Eight independently hosted migrators then start together. Every process must complete successfully, while the final database contains the outbox and the exact ordered current migration history, including durable checksums and application timestamps. One process applies every pending migration; the other seven observe the resulting current schema.

The scenario passed against SQL Server and PostgreSQL on 2026-08-24 with migrations `001_CreateTinyOutbox` and `002_AddProcessedCleanupIndex`.

Evidence is retained under `artifacts/schema/<run-id>/`.

## Interrupted Migration Recovery

Run the process-death scenario against either provider:

```powershell
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S03
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S03 -StorageProvider PostgreSql
```

`TE-S03` installs a temporary database-side DDL interruption, starts the real TinyEvents migrator, and waits until the database proves that one migrator is blocked inside DDL while holding the provider migration lock. Only then does the runner terminate the application process.

The scenario waits for the database to release the abandoned session lock before inspecting durable state. The interrupted transaction may leave no schema, an empty migration-history table, or a completely committed schema; all are safe atomic boundaries. An outbox without its matching history, or history without its outbox, fails acceptance. After removing the external interruption, a second process must finish with the exact ordered current migration history.

The DDL trigger/event trigger belongs only to the dogfood fault injector. It is removed in a `finally` block and is not part of TinyEvents production code.

## Missing or Incompatible Schema

Run the schema-compatibility scenario against either provider:

```powershell
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S04
.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S04 -StorageProvider PostgreSql
```

`TE-S04` starts from three independently prepared durable states. A completely missing TinyEvents schema must migrate successfully. Current migration history whose physical outbox table is missing must fail without claiming the schema is current. A migration with a conflicting checksum must also fail. Both incompatible states must identify the problem and relevant migration or table in stderr.

The scenario passed against SQL Server and PostgreSQL on 2026-08-24 using the two-migration schema at TinyEvents `main` commit `37c960d`.

## Rolling Application Upgrade

Run both published-alpha and rolling-upgrade evidence with a clean TinyEvents `main` checkout:

```powershell
.\deployment\Run-RollingUpgrade.ps1 -CandidateRoot ..\TinyEvents
```

`TE-S05` first runs TE-S02 to create package-only assemblies for published `0.1.0-alpha.3` and the clean-main candidate. It then creates a separate 100-message alpha backlog for each provider, starts the alpha worker, and waits for durable proof that it is processing before starting candidate. Candidate applies migration `002` while the already-running alpha worker remains active, matching a real rolling deployment rather than racing two cold starts.

Acceptance is decided from durable state: all 100 messages must be processed, both worker identities must appear, every message must have one distinct operation effect, no message may remain pending or processing, no failure may exist, and migration history must advance from one alpha row to the two-row current schema. Process stdout identifies execution details but is not acceptance authority.

An alpha process that cold-starts after candidate has applied a newer migration still fails fast because the old migrator cannot prove that a future schema is compatible. The demonstrated rolling contract therefore requires existing old instances to be running before the new version migrates. Restarted instances must use the new version.

The corrected rolling topology passed against SQL Server and PostgreSQL on 2026-08-24 using candidate TinyEvents `main` commit `1feb235`.

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

`TE-S02-B` then builds and packs the release train from clean `main`, restores the same host only from those local candidate packages, migrates the SQL Server database, and runs the real outbox processor once. `TE-S02-C` applies the unchanged contract to PostgreSQL. Acceptance requires the pending row and expired processing row to become processed with one effect each, while the terminally failed row, attempt count, and error remain unchanged. Published alpha starts with migration `001`; the candidate must advance each provider to the exact two-migration current schema including `002_AddProcessedCleanupIndex`.

The complete two-provider contract passed on 2026-08-24 against TinyEvents `main` commit `1feb235`.

The runner stores alpha-state and result files per provider, plus the overall `result.json` and `manifest.json`, under `artifacts/deployment/<run-id>/TE-S02/`. It reports `TeS02Complete = true` only when both providers satisfy the complete upgrade contract in the same run.
