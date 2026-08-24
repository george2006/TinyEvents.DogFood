# TinyEvents Beta Gate Result — August 24, 2026

This record preserves the source-controlled summary of the first complete
TinyEvents beta gate. Detailed logs and scenario JSON remain local under
`artifacts/`; they are intentionally ignored because they contain machine-
specific paths, process logs, and database evidence.

## Verdict

The composed local gate passed.

| Evidence | Result |
| --- | --- |
| Gate status | Passed |
| Mandatory suites | 36 of 36 passed |
| TinyEvents product tests | 543 passed, 0 failed, 0 skipped |
| Started | 2026-08-24 11:26:34 UTC |
| Completed | 2026-08-24 12:24:35 UTC |
| Duration | 3,481.05 seconds (58 minutes 1 second) |
| Dogfood revision | `69bef4c5f78de2a8167183aa745c28cb1b3486b3` |
| TinyEvents revision | `e479a836e176990a3a4e9a8d4d3359dbb23a1509` |
| Local result | `artifacts/beta-gate/20260824-132634/result.json` |
| Result SHA-256 | `AF82A9B606AAC140D9632633B5EDB847955E0B60CF4701015462F27DECBD0DEA` |

Both sibling repositories had clean working trees when the runner started. The
package-consumer suite then packed all six candidate packages, restored them
through an isolated NuGet cache, built without project references, and executed
the supported provider paths. A future CI run from fresh clones may strengthen
release provenance, but it is not an unproven TinyEvents behavior.

## Suite Coverage

| Area | Executions | Result |
| --- | ---: | :---: |
| TinyEvents product tests | 1 | Passed |
| Identity contracts | 1 | Passed |
| Operational baseline | 2 — SQL Server and PostgreSQL | Passed |
| Transaction boundaries | 2 — SQL Server and PostgreSQL | Passed |
| Worker scaling | 1 — SQL Server | Passed |
| Worker recovery | 2 — SQL Server and PostgreSQL | Passed |
| Database recovery | 2 — SQL Server and PostgreSQL | Passed |
| Sustained publishing | 2 — SQL Server and PostgreSQL | Passed |
| Prebuilt backlog drain | 2 — SQL Server and PostgreSQL | Passed |
| Mixed load | 2 — SQL Server and PostgreSQL | Passed |
| Live backlog recovery | 2 — SQL Server and PostgreSQL | Passed |
| Pending-payload storage | 2 — SQL Server and PostgreSQL | Passed |
| Outbox-state storage | 2 — SQL Server and PostgreSQL | Passed |
| Retained-history behavior | 2 — SQL Server and PostgreSQL | Passed |
| Cleanup correctness and recovery | 2 — SQL Server and PostgreSQL | Passed |
| Cleanup under active load | 2 — SQL Server and PostgreSQL | Passed |
| Repeated disruption soak | 2 — SQL Server and PostgreSQL | Passed |
| Schema behavior | 2 — SQL Server and PostgreSQL | Passed |
| Published-alpha upgrade | 1 | Passed |
| Rolling upgrade | 1 | Passed |
| Isolated package consumer | 1 | Passed |

The product-test execution covered seven test assemblies:

| Assembly | Passed |
| --- | ---: |
| `TinyEvents.Tests` | 93 |
| `TinyEvents.Worker.Tests` | 40 |
| `TinyEvents.SourceGen.Tests` | 11 |
| `TinyEvents.PostgreSql.EntityFrameworkCore.Tests` | 67 |
| `TinyEvents.PostgreSql.AdoNet.Tests` | 140 |
| `TinyEvents.SqlServer.AdoNet.Tests` | 155 |
| `TinyEvents.SqlServer.EntityFrameworkCore.Tests` | 37 |

## Capacity and Recovery Observations

These measurements describe this machine and this run. They demonstrate the
acceptance contracts; they are not universal throughput promises.

### Publishing with workers stopped

All attempted requests committed durably.

| Target requests/s | SQL Server target achieved | PostgreSQL target achieved |
| ---: | ---: | ---: |
| 200 | 99.89% | 99.90% |
| 400 | 99.91% | 100.00% |
| 800 | 97.49% | 99.90% |

### Drain of a prebuilt 10,000-message backlog

| Workers | SQL Server messages/s | PostgreSQL messages/s |
| ---: | ---: | ---: |
| 1 | 157.72 | 255.48 |
| 2 | 291.38 | 442.06 |
| 4 | 514.93 | 761.08 |
| 8 | 748.98 | 1,020.84 |

### Live backlog recovery

With publishing continuing at 200 requests/s and four workers participating:

- SQL Server reduced 1,135 outstanding messages to the 200-message threshold
  in 5.83 seconds.
- PostgreSQL reduced 1,051 outstanding messages to the same threshold in 3.53
  seconds.

Every committed operation settled without a failed attempt or duplicate effect.

### Retained terminal history

At 100,000 retained processed rows, measured drain throughput remained at
85.13% of the empty-history SQL Server baseline and 101.57% of the PostgreSQL
baseline. The PostgreSQL value is measurement variation, not evidence that
retained history improves performance.

### Cleanup under active load

At 200 and 400 requests/s, both providers completed the workload while cleanup
made durable progress. At the requested 800 requests/s:

- SQL Server measured 704.86 requests/s with cleanup and 572.28 ms publisher
  p95 while deleting all 50,000 eligible historical rows. This is visible
  local saturation, not a hidden pass condition.
- PostgreSQL measured 799.79 requests/s with cleanup and 5.18 ms publisher p95
  while deleting 44,000 eligible rows during the active interval.

Both variants ultimately committed and processed their complete active
workloads. Cleanup correctness does not claim identical provider capacity.

## Repeated Disruption Soak

Each provider ran for 120 seconds at a target of 200 requests/s with four
processing-and-cleanup workers, two claimed-worker deaths, two five-second
database outages, active cleanup, and final durable reconciliation.

| Observation | SQL Server | PostgreSQL |
| --- | ---: | ---: |
| Acknowledged commits | 17,533 | 21,902 |
| Durable commits | 17,537 | 21,902 |
| Ambiguous commits | 4 | 0 |
| Distinct effects | 16,659 | 20,808 |
| At-least-once duplicate effects | 5 | 2 |
| Failed request attempts during disruption | 6,467 | 2,098 |
| Worker deaths | 2 | 2 |
| Database outages | 2 | 2 |
| Acceptance | Passed | Passed |

The four SQL Server commits beyond the acknowledged count demonstrate the
documented ambiguous-acknowledgement boundary. The duplicate effects are
expected evidence of the documented at-least-once delivery model at deliberate
process-death boundaries; they are not reported as exactly-once behavior.

Every durable permanent-failure message reached `Failed` without producing its
success effect. Every durable successful, transient, and slow message reached
its expected terminal state. Neither provider retained pending or processing
work after reconciliation.

## Beta Hardening Decision

This run closes TinyEvents beta hardening. The same command exercised the
complete product-test, behavioral, provider, load, storage, cleanup, disruption,
upgrade, and package-consumer matrix without a skipped mandatory suite.

It does not by itself:

- turn local capacity measurements into production guarantees;
- change TinyEvents from at-least-once to exactly-once delivery;
- publish the beta packages by itself.

No behavioral hardening item remains open for the beta. Versioning, release
notes, tagging, and package publication remain normal release operations.
