# Operational baseline

This process-level laboratory verifies TinyEvents through the real SQL Server and PostgreSQL EF Core providers and hosted worker.

Run both baseline scenarios:

```powershell
.\operations\Run-OperationalBaseline.ps1
.\operations\Run-OperationalBaseline.ps1 -StorageProvider PostgreSql
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

Run one independently named scenario either through the suite selector or its own file:

```powershell
.\operations\Run-WorkerRecovery.ps1 -Scenario TE-W05
.\operations\scenarios\TE-W05-effect-before-death.ps1
```

The runner starts the sibling TinyEvents SQL Server container, builds a backlog while workers are stopped, starts an independently addressable worker process, waits for the backlog to drain, and stores evidence under `artifacts/operations/<run-id>/`.

| Scenario | Observable contract |
| --- | --- |
| `TE-T01` | Business rows and outbox messages commit together, then every committed event is processed. |
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
| `TE-D02` | A healthy polling worker survives a SQL Server outage and processes work both before and after recovery. |
| `TE-D03` | SQL Server disappears during active consumer work; the same process reclaims the expired lease after recovery. |
| `TE-D04` | SQL Server disappears after the consumer effect; redelivery exposes the expected at-least-once duplicate. |
| `TE-D05` | Mixed success, transient, permanent, and slow work reaches exact terminal outcomes across a SQL Server restart. |
| `TE-D06` | Two workers recover after their bounded connection pools are exhausted while concurrent publishers build a backlog. |

`TE-W02` reports end-to-end capacity from the start of publication until the final effect is observed. It is not an isolated worker-drain benchmark. Dedicated load scenarios will separate publishing rate, prebuilt-backlog drain rate, and database pressure.

`TE-W03` through `TE-W05` use the database clock and persisted `ClaimExpiresAtUtc` as the lease authority. The runner injects consumer timing only in the dogfood host, terminates an exact worker process during execution, and retains observations from before and after the lease boundary.

`TE-W05` deliberately records every consumer invocation instead of making the dogfood effect idempotent. Its expected result is two durable invocations for one operation: one before the owner dies and one after redelivery. This is the observable at-least-once boundary; production consumers remain responsible for idempotent side effects where duplicates are unsafe.

`TE-W04` also provides the complete TE-W06 evidence: replacement capacity starts while the dead owner's lease remains valid, cannot steal it, and resumes processing only after the SQL boundary. A duplicate runner would not add another observable contract.

`TE-W07` proves the V1 no-heartbeat boundary. When consumer duration exceeds `ClaimTimeout`, another worker may reclaim and complete the message while the first invocation is still running. The original worker later records a duplicate effect, detects that it lost the completion lease, emits a structured warning, and remains alive.

`TE-W08` uses normal host cancellation rather than terminating the process. Idle shutdown exits with code zero and changes no durable state. Cancellation during consumer execution also exits with code zero, leaves the claimed message recoverable without incrementing its failure count, and allows another worker to complete it once the lease expires.

`TE-W09` fails the first consumer invocation deliberately, stops all workers during the durable retry delay, and starts a replacement before eligibility. SQL time proves the replacement does not invoke the consumer early and completes the second invocation after `NextAttemptAtUtc` with one final effect and no duplicate.

`TE-W10` rejects one message twice and lets a second, unrelated message complete during the first retry delay. SQL-recorded invocation times prove attempts two and three begin no earlier than their persisted `NextAttemptAtUtc` boundaries. The same worker survives both failures and completes both messages without duplicate effects.

`TE-W11` rejects one message on every invocation while an unrelated message completes. The first two failures schedule durable retries; the third reaches the configured maximum, clears retry eligibility, and retains the exact terminal error. The worker remains alive throughout.

`TE-W12` gives one event two consumers. The recording consumer completes before the rejecting consumer fails once. Retrying the whole outbox message invokes both again, producing two durable effects for one operation. The scenario characterizes whole-event at-least-once delivery; it does not make consumer ordering a public contract.

`TE-W13` starts two deliberately slow processes with the same configured worker ID. After the second process reclaims the expired lease, the original process can still mark the row processed because durable ownership contains only their shared ID. Default generated worker IDs are process-unique; V1 therefore treats uniqueness of explicitly configured IDs as an operator responsibility rather than adding a durable worker registry.

`TE-D01` runs unchanged against SQL Server and PostgreSQL. It stops the selected database container after persisting one pending message, then starts the worker. The worker remains alive, reports initial and selected repeated failures instead of logging every poll, and automatically drains the preserved message after the same database returns.

`TE-D02` first proves that one worker can process a message, then removes SQL Server while that same process continues polling. After automatic recovery, a second message is published and processed by the unchanged worker without loss, duplication, or failed message attempts.

`TE-D03` removes SQL Server after a slow consumer has acquired its claim but before it writes its effect. Neither the effect nor the processing failure can be persisted during the outage. After SQL returns, the same worker reclaims the expired lease, records one effect, completes the message, and reports recovery.

`TE-D04` removes SQL Server after the durable consumer effect and before the outbox completion update. The worker survives the failed update, reclaims the expired lease after SQL returns, and completes through redelivery. SQL evidence retains both consumer invocations and one duplicate effect, which is the expected at-least-once boundary.

`TE-D05` holds a slow invocation after its durable effect while success, transient-failure, and permanent-failure messages share the backlog. SQL Server disappears at that exact point. The same worker recovers and drains every eligible message, preserves exact retry and terminal-failure counts, and exposes the slow message's expected duplicate effect.

`TE-D06` gives every process a maximum SQL connection pool of two. Each of two workers temporarily occupies both of its own connections while four concurrent publishers commit 100 messages. Both workers must report the real pool timeout, remain alive, announce recovery after their connections are released, participate in the drain, and finish without loss, failed attempts, or duplicate effects.

The PostgreSQL executable baseline uses the same publisher, consumers, hosted worker, observations, and behavioral assertions as SQL Server. PostgreSQL reset, migration, successful processing, transient retry, and durable inspection are proven. The named destructive runners remain SQL Server-only until their container and connection-pressure controls become provider-aware.

Processed outbox rows are intentionally retained during current hardening. Cleanup design remains blocked on `TE-L05`, which will measure bytes per status and define retention and deletion budgets before production behavior is added.

The operational executable also exposes `reset`, `publish`, `inspect`, `worker`, and dogfood-only `worker-for` commands for later destructive scenarios. It references the sibling TinyEvents source projects until hardened packages are published.
