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

`TE-W02` reports end-to-end capacity from the start of publication until the final effect is observed. It is not an isolated worker-drain benchmark. Dedicated load scenarios will separate publishing rate, prebuilt-backlog drain rate, and database pressure.

`TE-W03` through `TE-W05` use the database clock and persisted `ClaimExpiresAtUtc` as the lease authority. The runner injects consumer timing only in the dogfood host, terminates an exact worker process during execution, and retains observations from before and after the lease boundary.

`TE-W05` deliberately records every consumer invocation instead of making the dogfood effect idempotent. Its expected result is two durable invocations for one operation: one before the owner dies and one after redelivery. This is the observable at-least-once boundary; production consumers remain responsible for idempotent side effects where duplicates are unsafe.

`TE-W04` also provides the complete TE-W06 evidence: replacement capacity starts while the dead owner's lease remains valid, cannot steal it, and resumes processing only after the SQL boundary. A duplicate runner would not add another observable contract.

`TE-W07` proves the V1 no-heartbeat boundary. When consumer duration exceeds `ClaimTimeout`, another worker may reclaim and complete the message while the first invocation is still running. The original worker later records a duplicate effect, detects that it lost the completion lease, emits a structured warning, and remains alive.

`TE-W08` uses normal host cancellation rather than terminating the process. Idle shutdown exits with code zero and changes no durable state. Cancellation during consumer execution also exits with code zero, leaves the claimed message recoverable without incrementing its failure count, and allows another worker to complete it once the lease expires.

Processed outbox rows are intentionally retained during current hardening. Cleanup design remains blocked on `TE-L05`, which will measure bytes per status and define retention and deletion budgets before production behavior is added.

The operational executable also exposes `reset`, `publish`, `inspect`, `worker`, and dogfood-only `worker-for` commands for later destructive scenarios. It references the sibling TinyEvents source projects until hardened packages are published.
