# Schema and Deployment Dogfood

This laboratory executes destructive schema and deployment scenarios against real application processes and Docker-hosted databases.

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
