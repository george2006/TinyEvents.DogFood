# TinyEvents Identity Dogfood

This process-level laboratory verifies the beta event-identity contract through the real SQL Server outbox and hosted worker.

For commands across every implemented area, see the [scenario catalog](../docs/scenario-catalog.md).

Run every identity scenario:

```powershell
.\identity\Run-IdentityScenarios.ps1
```

Run one scenario independently:

```powershell
.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C04
```

The runner starts the sibling TinyEvents repository SQL Server container and recreates only the explicitly named `TinyEventsDogfoodIdentity` database. It starts a separate worker process, waits for durable terminal state, stops that process, and stores the SQL observation and process logs under `artifacts/identity/<run-id>/`.

## Current Characterization

| Scenario | Contract shape | Current result |
| --- | --- | --- |
| TE-C01 | Shared top-level contract | Processed with one durable effect |
| TE-C02 | Nested contract | Processed through the canonical runtime type name |
| TE-C03 | Closed generic contract | Rejected at build with `TEV002` |
| TE-C04 | Namespace rename with the same type name | Processed through an explicit previous name |
| TE-C05 | Same full name moved between assemblies | Processed with one durable effect |
| TE-C06 | V1 payload read by a V2 contract with an optional member | Processed with one durable effect; the absent member is observed as `not-provided` |

Every result in this table is an acceptance outcome. A rejected generic contract is successful only when compilation fails with the expected actionable diagnostic.
