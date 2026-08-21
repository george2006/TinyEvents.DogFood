# Operational baseline

This process-level laboratory verifies TinyEvents through the real SQL Server EF Core provider and hosted worker.

Run both baseline scenarios:

```powershell
.\operations\Run-OperationalBaseline.ps1
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
| `TE-D01` | A worker started while SQL Server is unavailable bounds repeated failure logs and recovers without restarting. |

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

`TE-D01` stops the existing SQL Server container after persisting one pending message, then starts the worker. The worker remains alive, reports initial and selected repeated failures instead of logging every poll, and automatically drains the preserved message after the same database returns.

Processed outbox rows are intentionally retained during current hardening. Cleanup design remains blocked on `TE-L05`, which will measure bytes per status and define retention and deletion budgets before production behavior is added.

The operational executable also exposes `reset`, `publish`, `inspect`, `worker`, and dogfood-only `worker-for` commands for later destructive scenarios. It references the sibling TinyEvents source projects until hardened packages are published.
