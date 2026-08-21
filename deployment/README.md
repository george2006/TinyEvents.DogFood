# Schema and Deployment Dogfood

This laboratory executes destructive schema and deployment scenarios against real application processes and Docker-hosted databases.

Run the current suite from the repository root:

```powershell
.\deployment\Run-SchemaScenarios.ps1
```

Run one independently addressable scenario with `-Scenario TE-S01`.

| Scenario | Behavior |
|---|---|
| `TE-S01` | Eight application processes migrate one fresh SQL Server database concurrently and produce one exact committed history. |

TE-S01 first recreates the dogfood database without the TinyEvents schema. Eight independently hosted migrators then start together. Every process must complete successfully, while the final database contains the outbox and exactly one `001_CreateTinyOutbox` history row with its durable checksum and application timestamp.

Evidence is retained under `artifacts/schema/<run-id>/`.
