# TinyEvents Dogfood Scenario Catalog

This catalog contains the behavior demonstrated by the repository today. Planned scenarios are intentionally excluded.

See the [beta hardening roadmap](roadmap.md) for incomplete work and the final release boundary.

Run every command from the `TinyEvents.Dogfood` repository root.

## How to Read the Catalog

For a scenario marked **SQL Server and PostgreSQL**, the displayed command runs SQL Server. Run the same evidence against PostgreSQL by adding:

```powershell
-StorageProvider PostgreSql
```

For example:

```powershell
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D04
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D04 -StorageProvider PostgreSql
```

A runner prints `AcceptancePassed = True` and exits successfully only when the complete observable contract passes. See [Running scenarios](running-scenarios.md) for prerequisites, safety information, provider configuration, and troubleshooting.

Some scenario IDs intentionally reuse stronger evidence from another executable scenario. They are labeled **Covered by** instead of pretending that a duplicate script adds confidence.

## Identity and Compatibility

Provider: **SQL Server**

Evidence: `artifacts/identity/<run-id>/`

| ID | Run | Expected evidence |
| --- | --- | --- |
| `TE-C01` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C01` | A shared top-level contract is processed and records one durable effect. |
| `TE-C02` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C02` | A nested contract is processed through its canonical runtime type name. |
| `TE-C03` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C03` | Compilation is rejected with the expected `TEV002` diagnostic for a closed generic event. The runner treats this expected rejection as success. |
| `TE-C04` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C04` | A namespace rename processes an in-flight message through an explicit previous name. |
| `TE-C05` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C05` | Moving a contract between assemblies preserves processing when its full type name remains unchanged. |
| `TE-C06` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C06` | A V1 payload is consumed by the V2 contract, records one durable effect, and observes its absent optional member as `not-provided`. |
| `TE-C07` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C07` | An event type absent from the worker reaches `Failed` with one attempt and an actionable error. A valid event later in the same batch reaches `Processed` and records one durable effect. |
| `TE-C08` | `.\identity\Run-IdentityScenarios.ps1 -Scenario TE-C08` | Malformed JSON for a registered event reaches `Failed` with one attempt and durable JSON error evidence. A valid event later in the same batch reaches `Processed` and records one durable effect. |

See [Identity dogfood](../identity/README.md) for the identity contract and current characterization.

## Transactional Publishing

Provider: **SQL Server and PostgreSQL**

| ID | Run or coverage | Expected evidence |
| --- | --- | --- |
| `TE-T01` | `.\operations\Run-OperationalBaseline.ps1` | Ten business rows and ten outbox messages commit together and are later processed. This runner also executes `TE-W01`. |
| `TE-T02` | `.\operations\Run-TransactionScenarios.ps1 -Scenario TE-T02` | Ten business rows and ten outbox messages are saved inside one transaction; rollback leaves both durable counts at zero. |
| `TE-T03` | **Covered by:** run `TE-T01`, then `TE-T02`. | The commit side preserves all ten operations; the rollback side preserves none. Together they prove the several-event all-or-nothing contract. |
| `TE-T04` | **Covered by:** `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D06` | Four concurrent publishers acknowledge 100 operations. Durable state contains 100 business rows, 100 outbox rows, 100 distinct effects, and no duplicates. |
| `TE-T05` | `.\operations\Run-TransactionScenarios.ps1 -Scenario TE-T05` | Process death discards saved but uncommitted work. A completed commit survives immediate process death, and an acknowledged commit remains durable. |

Evidence locations:

- `TE-T01`: `artifacts/operations/<run-id>/TE-T01/`;
- `TE-T02` and `TE-T05`: `artifacts/transactions/<run-id>/<scenario-id>/`;
- `TE-T04`: `artifacts/database/<run-id>/TE-D06/`.

## Workers, Claims, Retries, and Shutdown

`TE-W01` is proven against **SQL Server and PostgreSQL**. The remaining worker scenarios currently have executable SQL Server evidence.

| ID | Run or coverage | Expected evidence |
| --- | --- | --- |
| `TE-W01` | `.\operations\Run-OperationalBaseline.ps1` | One hosted worker drains a known backlog without loss, failed messages, or duplicate effects. This runner also executes `TE-T01`. |
| `TE-W02` | `.\operations\Run-WorkerScaling.ps1 -Backlog 1000` | Two, four, and eight worker processes compete for distinct rows. Every message is processed once and every worker participates. |
| `TE-W03` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W03` | A competing worker cannot steal a claim before the database-authoritative lease expires. |
| `TE-W04` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W04` | After the owner dies, replacement capacity waits for lease expiry, reclaims the message, and completes it once. |
| `TE-W05` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W05` | Death after a durable consumer effect but before outbox completion causes the expected redelivery and one duplicate effect. |
| `TE-W06` | **Covered by:** `TE-W04`. | Replacement capacity starts before lease expiry, cannot steal the live claim, and resumes after the exact database boundary. |
| `TE-W07` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W07` | A consumer exceeding `ClaimTimeout` overlaps a competing redelivery, exposes a duplicate invocation, and leaves both workers alive. |
| `TE-W08` idle | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W08-idle` | An idle hosted worker stops with exit code zero and does not change durable state. |
| `TE-W08` active | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W08-active` | Cancellation during consumer execution exits cleanly, does not record a processing failure, and leaves the claim recoverable after expiry. |
| `TE-W09` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W09` | A scheduled retry survives complete worker loss and cannot run before its persisted `NextAttemptAtUtc`. |
| `TE-W10` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W10` | A transient failure respects two durable retry boundaries, succeeds on attempt three, and does not block unrelated work. |
| `TE-W11` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W11` | A permanent failure stops after exactly three attempts, retains its terminal error, and does not kill the worker. |
| `TE-W12` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W12` | Failure in a later consumer retries the complete event and invokes an already successful consumer again. |
| `TE-W13` | `.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W13` | Two processes sharing one configured worker ID demonstrate why configured IDs must be unique in V1. |

Evidence locations:

- `TE-W01`: `artifacts/operations/<run-id>/TE-W01/`;
- `TE-W02`: `artifacts/workers/<run-id>/TE-W02/`;
- `TE-W03` through `TE-W13`: `artifacts/workers/<run-id>/recovery/<scenario-id>/`.

## Database Failure and Recovery

Provider: **SQL Server and PostgreSQL**

Evidence: `artifacts/database/<run-id>/<scenario-id>/`

| ID | Run | Expected evidence |
| --- | --- | --- |
| `TE-D01` | `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D01` | A worker starts while the database is unavailable, bounds repeated failure logs, survives, and processes preserved work after recovery. |
| `TE-D02` | `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D02` | One unchanged worker processes work before and after a polling-time database outage without loss or duplicates. |
| `TE-D03` | `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D03` | The database disappears after claim acquisition but before the consumer effect. The same process later reclaims and completes once. |
| `TE-D04` | `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D04` | The database disappears after the consumer effect but before completion. Redelivery produces exactly one expected duplicate effect. |
| `TE-D05` | `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D05` | Success, transient, permanent, and slow messages reach exact terminal outcomes across a database restart. |
| `TE-D06` | `.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D06` | Two workers survive exhausting their own two-connection pools while four publishers create 100 messages, then recover and drain without loss. |

## Schema and Deployment

Provider: **SQL Server and PostgreSQL**

Evidence: `artifacts/schema/<run-id>/<scenario-id>/` and `artifacts/deployment/<run-id>/TE-S02/`

| ID | Run | Expected evidence |
| --- | --- | --- |
| `TE-S01` | `.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S01` | Eight application processes migrate one fresh database concurrently. One applies `001_CreateTinyOutbox`, seven observe the current schema, and durable history contains one row. |
| `TE-S02` | `.\deployment\Run-PublishedAlphaUpgrade.ps1` | Published `0.1.0-alpha.3` packages create pending, reclaimable-processing, and failed state. Clean-main candidate packages migrate SQL Server and PostgreSQL, process supported work exactly once in the lab, preserve the terminal failure, and retain one migration row per provider. |
| `TE-S03` | `.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S03` | A database-controlled DDL interruption proves the migrator owns its provider lock before the application process is terminated. The database releases the abandoned lock, retains only a resumable atomic state, and a later process completes one exact migration. |
| `TE-S04` | `.\deployment\Run-SchemaScenarios.ps1 -Scenario TE-S04` | A missing schema is created. Current migration history without its physical outbox and a conflicting migration checksum are both rejected with actionable diagnostics. |

See [Schema and deployment dogfood](../deployment/README.md) for the migration scenario details.

## Run the Current Evidence Suites

The following commands reproduce all currently implemented evidence. Run PostgreSQL variants after the SQL Server commands where shown.

```powershell
.\identity\Run-IdentityScenarios.ps1
.\operations\Run-OperationalBaseline.ps1
.\operations\Run-OperationalBaseline.ps1 -StorageProvider PostgreSql
.\operations\Run-TransactionScenarios.ps1
.\operations\Run-TransactionScenarios.ps1 -StorageProvider PostgreSql
.\operations\Run-WorkerScaling.ps1
.\operations\Run-WorkerRecovery.ps1
.\operations\Run-DatabaseRecovery.ps1
.\operations\Run-DatabaseRecovery.ps1 -StorageProvider PostgreSql
.\deployment\Run-SchemaScenarios.ps1
.\deployment\Run-SchemaScenarios.ps1 -StorageProvider PostgreSql
.\deployment\Run-PublishedAlphaUpgrade.ps1
```

These commands are intentionally separate. A future release gate may coordinate them, but the individual runners remain the source of truth for setup, failure injection, assertions, and evidence.
