# Operational baseline

This process-level laboratory verifies TinyEvents through the real SQL Server EF Core provider and hosted worker.

Run both baseline scenarios:

```powershell
.\operations\Run-OperationalBaseline.ps1
```

The runner starts the sibling TinyEvents SQL Server container, builds a backlog while workers are stopped, starts an independently addressable worker process, waits for the backlog to drain, and stores evidence under `artifacts/operations/<run-id>/`.

| Scenario | Observable contract |
| --- | --- |
| `TE-T01` | Business rows and outbox messages commit together, then every committed event is processed. |
| `TE-W01` | One hosted worker drains a known backlog without loss or duplicate effects. |

The operational executable also exposes `reset`, `publish`, `inspect`, and `worker` commands for later destructive scenarios. It references the sibling TinyEvents source projects until hardened packages are published.
