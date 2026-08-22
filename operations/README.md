# Operational baseline

This process-level laboratory verifies TinyEvents through the real SQL Server and PostgreSQL EF Core providers and hosted worker.

For one copyable command per implemented scenario, see the [scenario catalog](../docs/scenario-catalog.md).

Run both baseline scenarios:

```powershell
.\operations\Run-OperationalBaseline.ps1
.\operations\Run-OperationalBaseline.ps1 -StorageProvider PostgreSql
```

Run transactional publishing scenarios:

```powershell
.\operations\Run-TransactionScenarios.ps1
.\operations\Run-TransactionScenarios.ps1 -StorageProvider PostgreSql
```

Run the competing-worker matrix:

```powershell
.\operations\Run-WorkerScaling.ps1
```

Run active-lease and dead-worker recovery scenarios:

```powershell
.\operations\Run-WorkerRecovery.ps1
```

Run database failure and recovery scenarios:

```powershell
.\operations\Run-DatabaseRecovery.ps1
.\operations\Run-DatabaseRecovery.ps1 -Scenario TE-D01 -StorageProvider PostgreSql
```

Run sustained publishing independently from workers:

```powershell
.\operations\Run-PublishingLoad.ps1
.\operations\Run-PublishingLoad.ps1 -StorageProvider PostgreSql
```

Run worker scaling against a prebuilt backlog:

```powershell
.\operations\Run-WorkerDrainLoad.ps1
.\operations\Run-WorkerDrainLoad.ps1 -StorageProvider PostgreSql
```

Run sustained successful, retrying, terminal, and slow work together:

```powershell
.\operations\Run-MixedLoad.ps1
.\operations\Run-MixedLoad.ps1 -StorageProvider PostgreSql
```

Recover a live backlog without stopping the publisher:

```powershell
.\operations\Run-BacklogRecoveryLoad.ps1
.\operations\Run-BacklogRecoveryLoad.ps1 -StorageProvider PostgreSql
```

Measure the completed pending-payload portion of the in-progress `TE-L05` storage contract:

```powershell
.\operations\Run-StorageMeasurements.ps1
.\operations\Run-StorageMeasurements.ps1 -StorageProvider PostgreSql
```

Run one independently named scenario either through the suite selector or its own file:

```powershell
.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W05
.\operations\scenarios\TE-W05-effect-before-death.ps1
```

The runner starts the sibling TinyEvents SQL Server container, builds a backlog while workers are stopped, starts an independently addressable worker process, waits for the backlog to drain, and stores evidence under `artifacts/operations/<run-id>/`.

| Scenario | Observable contract |
| --- | --- |
| `TE-T01` | Business rows and outbox messages commit together, then every committed event is processed. |
| `TE-T02` | Rolling back after a real save removes both business state and its outbox message. |
| `TE-T03` | TE-T01 commits several events together and TE-T02 rolls several back together, proving both all-or-nothing outcomes without a duplicate scenario. |
| `TE-T04` | TE-D06 proves four concurrent publishers commit 100 unique operations without loss, partial outbox state, or duplicate effects. |
| `TE-T05` | Process death discards saved but uncommitted work, while a completed commit remains durable before and after publisher acknowledgement. |
| `TE-W01` | One hosted worker drains a known backlog without loss or duplicate effects. |
| `TE-W02` | 2, 4, and 8 hosted-worker processes compete without loss or duplicate effects. |
| `TE-W03` | A competing worker cannot steal a claim before its SQL lease expires. |
| `TE-W04` | A second worker reclaims and completes a message after its owning process dies and the SQL lease expires. |
| `TE-W05` | If a worker dies after its consumer effect but before outbox completion, another worker invokes the consumer again after lease expiry. |
| `TE-W07` | A consumer running longer than its claim overlaps with a competing redelivery and exposes a duplicate invocation. |
| `TE-W08` | Graceful shutdown exits cleanly both while idle and during active consumer work, without misclassifying cancellation as failure. |
| `TE-W09` | A scheduled retry remains durable across a complete worker restart and cannot execute before `NextAttemptAtUtc`. |
| `TE-W10` | A transiently failing message respects both durable retry boundaries, recovers on its third attempt, and does not block unrelated work. |
| `TE-W11` | A permanently failing message exhausts exactly three attempts, retains its terminal error, and does not kill or block the worker. |
| `TE-W12` | A failure in a later consumer retries the complete event and may invoke an already successful consumer again. |
| `TE-W13` | Two processes sharing one configured worker ID defeat process-level lease fencing after a reclaim. |
| `TE-D01` | A worker started while its database is unavailable bounds repeated failure logs and recovers without restarting. |
| `TE-D02` | A healthy polling worker survives a database outage and processes work both before and after recovery. |
| `TE-D03` | The database disappears during active consumer work; the same process reclaims the expired lease after recovery. |
| `TE-D04` | The database disappears after the consumer effect; redelivery exposes the expected at-least-once duplicate. |
| `TE-D05` | Mixed success, transient, permanent, and slow work reaches exact terminal outcomes across a database restart. |
| `TE-D06` | Two workers recover after their bounded connection pools are exhausted while concurrent publishers build a backlog. |
| `TE-L01` | Workers remain stopped while 200, 400, and 800 real publishing requests per second record committed throughput, latency, errors, and exact durable outbox growth. |
| `TE-L02` | Publishers remain stopped while 1, 2, 4, and 8 workers drain identical 10,000-message backlogs and record throughput, speedup, efficiency, participation, and exact durable outcomes. |
| `TE-L03` | One publisher and four workers sustain a known success, transient, permanent, and slow mix while proving unrelated progress, exact retry pressure, terminal outcomes, and bounded connections. |
| `TE-L04` | Four workers reduce a 1,000-message accumulated backlog to no more than one second of incoming traffic while the 200-request-per-second publisher remains active. |

`TE-W02` reports end-to-end capacity from the start of publication until the final effect is observed. It is not an isolated worker-drain benchmark. Dedicated load scenarios will separate publishing rate, prebuilt-backlog drain rate, and database pressure.

`TE-W03` through `TE-W05` use the database clock and persisted `ClaimExpiresAtUtc` as the lease authority. The runner injects consumer timing only in the dogfood host, terminates an exact worker process during execution, and retains observations from before and after the lease boundary.

`TE-W05` deliberately records every consumer invocation instead of making the dogfood effect idempotent. Its expected result is two durable invocations for one operation: one before the owner dies and one after redelivery. This is the observable at-least-once boundary; production consumers remain responsible for idempotent side effects where duplicates are unsafe.

`TE-W04` also provides the complete TE-W06 evidence: replacement capacity starts while the dead owner's lease remains valid, cannot steal it, and resumes processing only after the SQL boundary. A duplicate runner would not add another observable contract.

`TE-W07` proves the V1 no-heartbeat boundary. When consumer duration exceeds `ClaimTimeout`, another worker may reclaim and complete the message while the first invocation is still running. The original worker later records a duplicate effect, detects that it lost the completion lease, emits a structured warning, and remains alive.

The same boundary applies to the cumulative duration of a claimed batch. Workers process claimed messages sequentially, so `ClaimTimeout` must cover the worst-case time needed to consume and complete the entire configured `BatchSize`, not only one handler invocation. A 10,000-row storage-preparation run with four workers, `BatchSize = 50`, and the deliberately short five-second dogfood lease completed every message but recorded 45 duplicate effects after later rows in some batches expired. V1 keeps the explicit at-least-once contract: operators can increase `ClaimTimeout` or reduce `BatchSize`; heartbeat renewal and progressive claims remain post-V1 work.

`TE-W08` uses normal host cancellation rather than terminating the process. Idle shutdown exits with code zero and changes no durable state. Cancellation during consumer execution also exits with code zero, leaves the claimed message recoverable without incrementing its failure count, and allows another worker to complete it once the lease expires.

`TE-W09` fails the first consumer invocation deliberately, stops all workers during the durable retry delay, and starts a replacement before eligibility. SQL time proves the replacement does not invoke the consumer early and completes the second invocation after `NextAttemptAtUtc` with one final effect and no duplicate.

`TE-W10` rejects one message twice and lets a second, unrelated message complete during the first retry delay. SQL-recorded invocation times prove attempts two and three begin no earlier than their persisted `NextAttemptAtUtc` boundaries. The same worker survives both failures and completes both messages without duplicate effects.

`TE-W11` rejects one message on every invocation while an unrelated message completes. The first two failures schedule durable retries; the third reaches the configured maximum, clears retry eligibility, and retains the exact terminal error. The worker remains alive throughout.

`TE-W12` gives one event two consumers. The recording consumer completes before the rejecting consumer fails once. Retrying the whole outbox message invokes both again, producing two durable effects for one operation. The scenario characterizes whole-event at-least-once delivery; it does not make consumer ordering a public contract.

`TE-W13` starts two deliberately slow processes with the same configured worker ID. After the second process reclaims the expired lease, the original process can still mark the row processed because durable ownership contains only their shared ID. Default generated worker IDs are process-unique; V1 therefore treats uniqueness of explicitly configured IDs as an operator responsibility rather than adding a durable worker registry.

`TE-D01` runs unchanged against SQL Server and PostgreSQL. It stops the selected database container after persisting one pending message, then starts the worker. The worker remains alive, reports initial and selected repeated failures instead of logging every poll, and automatically drains the preserved message after the same database returns.

`TE-D02` runs unchanged against SQL Server and PostgreSQL. It first proves that one worker can process a message, then removes the selected database while that same process continues polling. After automatic recovery, a second message is published and processed by the unchanged worker without loss, duplication, or failed message attempts.

`TE-D03` runs unchanged against SQL Server and PostgreSQL. It removes the selected database after a slow consumer has acquired its claim but before it writes its effect. Neither the effect nor the processing failure can be persisted during the outage. After the database returns, the same worker reclaims the expired lease, records one effect, completes the message, and reports recovery.

`TE-D04` runs unchanged against SQL Server and PostgreSQL. It removes the selected database after the durable consumer effect and before the outbox completion update. The worker survives the failed update, reclaims the expired lease after the database returns, and completes through redelivery. Durable evidence retains both consumer invocations and one duplicate effect, which is the expected at-least-once boundary.

`TE-D05` runs unchanged against SQL Server and PostgreSQL. It holds a slow invocation after its durable effect while success, transient-failure, and permanent-failure messages share the backlog. The selected database disappears at that exact point. The same worker recovers and drains every eligible message, preserves exact retry and terminal-failure counts, and exposes the slow message's expected duplicate effect.

`TE-D06` runs unchanged against SQL Server and PostgreSQL. It gives every process a maximum connection pool of two for the selected provider. Each of two workers temporarily occupies both of its own connections while four concurrent publishers commit 100 messages. Both workers must report the real pool timeout, remain alive, announce recovery after their connections are released, participate in the drain, and finish without loss, failed attempts, or duplicate effects.

`TE-L01` runs unchanged against SQL Server and PostgreSQL. Every publishing request receives its own dependency-injection scope and database commit while no worker is running. Each rate starts from an empty database, records latency only for committed requests, and compares the command result with durable business and outbox row counts. Reaching 95% of a requested rate is reported separately from behavioral acceptance so machine capacity is not mistaken for a TinyEvents guarantee.

`TE-L02` runs unchanged against SQL Server and PostgreSQL. Every worker-count variant starts from a separately created backlog while no publisher is active. Drain timing includes worker-process startup and at most one 100-millisecond observation interval. Throughput and scaling efficiency remain machine-local evidence; acceptance requires every worker to participate and every message to complete with one durable effect, no failed attempt, and no duplicate.

`TE-L03` runs unchanged against SQL Server and PostgreSQL. One process publishes 80% successful, 10% transient, 5% permanent, and 5% slow work at a combined target of 200 requests per second while four independent worker processes consume it. Every process is limited to a 16-connection pool. An intermediate durable observation must show retry pressure and successful work advancing together. Final acceptance requires 1,900 processed messages, 100 deliberately failed messages, 700 failed attempts, 900 recorded failure-plan invocations, 1,900 effects, and no duplicate.

`TE-L04` runs unchanged against SQL Server and PostgreSQL. One process publishes 4,000 operations at 200 requests per second. Workers remain stopped until at least 1,000 messages are pending, then four independent workers must process at least that initial backlog and reduce outstanding work to no more than one second of current input while the publisher is still running. Final acceptance requires all 4,000 messages to complete once, every worker to participate, and no failed attempt or duplicate effect. Recovery timing includes worker startup and up to one 100-millisecond observation interval.

The PostgreSQL executable baseline, `TE-D01` through `TE-D06`, and `TE-L01` through `TE-L04` use the same publisher, consumers, observations, and behavioral assertions as SQL Server. PostgreSQL reset, migration, successful processing, transient retry, durable inspection, physical database recovery, bounded connection-pressure recovery, isolated publishing load, prebuilt-backlog drain, sustained mixed load, and live backlog recovery are proven without provider-specific scenario copies.

Processed outbox rows are intentionally retained during current hardening. Cleanup design remains blocked on `TE-L05`, which will measure bytes per status and define retention and deletion budgets before production behavior is added.

The operational executable also exposes `reset`, `publish`, `inspect`, `worker`, and dogfood-only `worker-for` commands for later destructive scenarios. It references the sibling TinyEvents source projects until hardened packages are published.
