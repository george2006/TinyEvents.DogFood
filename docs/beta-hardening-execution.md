# TinyEvents Beta Hardening Execution Guide

This file is the working checkpoint for completing the TinyEvents beta. The
[roadmap](roadmap.md) remains the acceptance contract; this guide records the
order of work so a new session can resume without reconstructing decisions.

## Current Checkpoint

Current as of August 23, 2026:

- TinyEvents `main` at `52e6889` contains bounded processed-message cleanup for
  SQL Server and PostgreSQL, including ADO.NET and EF Core providers;
- Dogfood `main` at `967f63f` contains the complete `TE-L05` through `TE-L07`
  scenarios, decisions, and measured evidence;
- Dogfood branch `hardening/provider-parity` contains the completed worker
  parity gate and awaits integration;
- the cleanup capability is not present in the latest published NuGet packages;
- TinyEvents documentation commit `936794c` accepts the one-hour retention,
  1,000-row batch, and one-second interval, publishes their measured storage
  budget, and retains their next-release status;
- `TE-L05-A`, `TE-L05-B`, and `TE-L05-C` provide repeatable storage and
  retained-history evidence against both providers;
- cleanup defaults have passed the complete `TE-L06` dogfood acceptance;
- `TE-L06-A` passes against SQL Server and PostgreSQL from committed Dogfood
  revision `9639b04` and TinyEvents revision `35d3156`. Both providers delete
  only the eligible processed row and preserve the cutoff, recent, pending,
  processing, and failed rows;
- `TE-L06-B` passes against SQL Server and PostgreSQL from committed Dogfood
  revision `6078b56` and TinyEvents revision `35d3156`. Four independent
  processes delete 401 eligible rows in three bounded, overlapping waves with
  exact agreement between reported deletions and durable row decreases;
- `TE-L06-C1` passes against SQL Server and PostgreSQL from committed Dogfood
  revision `940f395` and TinyEvents `main` revision `52e6889`. Cleanup stops
  with a durable remainder after abrupt process termination, and a replacement
  process completes that remainder without deleting business rows;
- `TE-L06-C2` passes against SQL Server and PostgreSQL from committed Dogfood
  revision `7113f60` and TinyEvents `main` revision `52e6889`. The same cleanup
  process reports failure, survives the database outage, reports recovery,
  deletes another batch, and completes the durable remainder;
- `TE-L06-D` passes against SQL Server and PostgreSQL from Dogfood revision
  `fe447e8` and TinyEvents revision `c629baf`. Every baseline and candidate
  variant committed and processed its complete active workload without loss,
  duplicate, failed attempt, or worker starvation while candidate cleanup made
  concurrent durable progress;
- `TE-W03` through `TE-W13` pass unchanged against PostgreSQL from Dogfood
  revision `89e771b` and TinyEvents revision `936794c`;
- the beta is not ready until package and final audit gates close.

The `FIX-1` characterization test demonstrated that disabled cleanup with a
custom provider failed dependency-injection build validation. Commit `35d3156`
defers `TinyOutboxCleanup` construction through an explicit service factory.
Disabled cleanup no longer requires `ITinyOutboxCleanupStore`; enabled cleanup
retains its existing startup validation. The worker test suite passes.

The post-merge documentation audit is closed by TinyEvents commits `c629baf`
and `936794c`. Its root README, worker guide, retention guide, and four provider
package READMEs distinguish the next-release capability from the published
alpha, expose migration `002_AddProcessedCleanupIndex`, and publish the accepted
defaults and measured budget. Existing alpha.3 package release notes remain
unchanged until release preparation.

## Slice Rules

Each slice must:

1. change one observable behavior or one coherent documentation boundary;
2. state the expected files before implementation;
3. use real product code in behavioral evidence;
4. run the smallest relevant verification suite;
5. receive a principal-level diff review before commit;
6. stop when an unexpected architectural decision appears;
7. keep TinyEvents product changes and Dogfood evidence in separate branches
   and pull requests.

No pull request is created or merged without explicit review approval.

## Execution Order

| Slice | Repository | Status | Outcome |
| --- | --- | --- | --- |
| `DOC-1` | Dogfood | Complete | Align documentation with merged cleanup and record this execution checkpoint. |
| `FIX-1` | TinyEvents | Complete | Preserve enabled-cleanup startup validation while allowing disabled cleanup with custom providers. |
| `TE-L06-A` | Dogfood | Complete | Prove the exclusive cutoff and preservation rules through the real cleanup store against both providers. |
| `TE-L06-B` | Dogfood | Complete | Prove bounded deletion and exact durable progress with concurrent cleanup processes against both providers. |
| `TE-L06-C1` | Dogfood | Complete | Prove a replacement process resumes cleanup after abrupt process termination. |
| `TE-L06-C2` | Dogfood | Complete | Prove the same cleanup process resumes after database interruption. |
| `DOC-2A` | Dogfood | Complete | Record the post-merge checkpoint and documentation audit findings. |
| `DOC-2B` | TinyEvents | Complete | Mark cleanup defaults as candidates and complete next-release and migration references without changing alpha.3 release notes. |
| `TE-L06-D` | Dogfood | Complete | Compare the same active workload with cleanup disabled and with the candidate policy enabled at 200, 400, and 800 messages per second. |
| `TE-L06-E` | Both | Complete | Accept retention, batch, and interval defaults and publish the measured storage budget. |
| `TE-L07` | Dogfood | Complete | Reconcile a timed mixed-load soak through repeated worker death, database outage, and active cleanup against both providers. |
| `PROVIDER-1` | Both | Complete | Run the unchanged process-level worker recovery contract against PostgreSQL after reusing its existing storage and recovery evidence. |
| `PACKAGE-1` | Both | Complete | Pack the candidate and run supported consumers without project references. |
| `BETA-GATE` | Both | Next | Run the clean-checkout gate, review public limitations, and make the explicit beta/no-beta decision. |

## Evidence We Reuse

Completed identity, transaction, worker, database-recovery, schema, upgrade,
publishing, backlog, mixed-load, and retained-history scenarios are not rerun
merely to create activity. A later slice reruns them only when cleanup or
packaging changes the behavior they proved.

`TE-L05` measured local storage and throughput characteristics. Those numbers
inform `TE-L06`; they are not universal capacity guarantees and do not by
themselves approve the candidate cleanup defaults.

## TE-L06-D Contract

Each target rate runs two isolated variants against freshly reset storage:

1. a baseline with cleanup disabled;
2. the candidate policy with cleanup enabled on every worker process, using
   one-hour processed retention, 1,000-row batches, and a one-second interval.

Both variants begin with the same 50,000-row eligible processed history created
through the real publisher and the existing dogfood-only cleanup fixture. A
real publisher then issues one application transaction per request for ten
seconds. It starts before four real worker processes so active publication,
processing, and candidate cleanup demonstrably overlap. Enabling cleanup on
every worker represents the natural horizontally scaled hosted-worker setup;
`TE-L06-B` already proves their concurrent delete coordination.

Every process uses a maximum connection-pool size of 16 for both providers. The
budget prevents one publisher process from consuming PostgreSQL's complete
100-connection server limit before the four workers can participate. The value
matches the existing mixed-load scenario and is recorded in the run manifest;
the experiment does not raise the database server limit to hide pressure.

The scenario records requested and committed rate, commit latency percentiles,
settlement duration, worker participation, eligible rows deleted, cleanup rate,
and the relative change between baseline and cleanup. It uses the lightweight
outstanding-work probe while waiting and reads the complete durable observation
only at boundaries. Cleanup logs establish that deletion happened while the
publisher was still active without repeatedly scanning the evidence tables.

Acceptance requires every request to commit, every active message to produce
one distinct effect, no failed or duplicate effect, no pending or processing
remainder, participation from every worker, complete retention of the eligible
history in the baseline, and positive cleanup progress during active load in
the candidate variant. The scenario does not invent a universal performance
threshold. `TE-L06-E` uses the measured interference from both database engines
to accept or change the candidate defaults and publish the storage budget.

## TE-L06-D Result

The accepted SQL Server run is stored under
`artifacts/cleanup-load/20260823-202303`; PostgreSQL is under
`artifacts/cleanup-load/20260823-202704`. Both use a 16-connection maximum per
process, four workers, 50,000 eligible rows per variant, and committed Dogfood
revision `fe447e8`.

At 200 and 400 requested operations per second, both providers committed the
complete workload in baseline and candidate variants. Candidate throughput
remained within 0.2% of baseline. PostgreSQL also sustained 800 with comparable
throughput and p95 latency. SQL Server did not sustain the requested 800 in
either variant; candidate cleanup completed correctly but its publisher p95
rose to 420.13 ms and final settlement took 11.01 seconds after publishing.
That overloaded local point is retained as interference evidence rather than
promoted to a universal capacity or default-policy failure.

Candidate cleanup removed between 40,000 and 50,000 eligible rows per variant
while publication was still active. Observed cleanup rates ranged from 2,170
to 3,910 rows per second. Every active message produced one distinct effect,
every worker participated, and no run retained pending, processing, failed, or
duplicate work.

An initial PostgreSQL run without a per-process pool budget failed honestly
with `53300: too many clients already`: one publisher's default 100-connection
pool matched the complete server limit before four workers were considered.
The accepted runner uses the same explicit 16-connection budget already used
by the mixed-load scenario. It does not raise the PostgreSQL server limit.

## TE-L06-E Decision

TinyEvents commit `936794c` accepts one-hour processed retention, a 1,000-row
cleanup batch, and a one-second interval for the next release. One hour keeps a
useful operational inspection window. The nominal configuration permits up to
1,000 deleted rows per second per application instance, so one instance is not
configured below the highest tested input target. Lowering the batch or
lengthening the interval would make that property false. TE-L06-D found no
material throughput interference at 200 or 400 requests per second on either
provider. The SQL Server 800 point remains an explicit local catch-up warning,
not hidden evidence.

TE-L05-B measured a representative processed row containing 1 KB of
compression-resistant content at 4,515 bytes on SQL Server and 1,951 bytes on
PostgreSQL. The accepted one-hour planning budget is therefore:

| Sustained processed rate | Rows retained | SQL Server | PostgreSQL |
|---:|---:|---:|---:|
| 200 messages/s | 720,000 | 3.25 GB | 1.40 GB |
| 400 messages/s | 1,440,000 | 6.50 GB | 2.81 GB |
| 800 messages/s | 2,880,000 | 13.00 GB | 5.62 GB |

These are decimal-GB projections for the measured outbox table and indexes,
not a universal database-size ceiling. Payload shape, engine allocation,
pending work, and preserved failed rows remain workload-specific. The product
documentation gives operators the formula and directs them to lower retention
or cleanup pressure only from their own measured budget and capacity.

## TE-L07 Contract

TE-L07 is one bounded integration soak, not a new test framework. Its default
run lasts 120 seconds at 200 publishing requests per second with four worker
processes. The workload reuses TE-L03's 80% success, 10% transient, 5%
permanent, and 5% slow mix. Every worker hosts event processing and cleanup
together, using the accepted one-hour retention, 1,000-row batch, and one-second
interval. The run begins with 50,000 expired processed rows so cleanup has real
work while current messages are published and consumed.

During active publication the runner terminates two workers while they own
claimed work and starts a distinctly named replacement after each death. It
also stops and restores the real database twice for five seconds. A maximum
pool of 16 connections per process and a one-second connection timeout keep
outage pressure bounded. Failed publishing requests during an intentional
database outage are observable application failures, but a connection can
also fail after the database committed and before the publisher received
acknowledgement. Acceptance retains acknowledged and failed request results
while deriving durable per-scenario counts independently from business
storage.

The runner samples process working set and private memory, active database
connections, physical outbox storage, and durable backlog during the run.
These resource values are evidence, not arbitrary pass/fail ceilings. V1
acceptance instead requires:

- every committed request has one business row and one outbox row;
- every committed success, transient, and slow message reaches `Processed`;
- every committed permanent message reaches `Failed` with its bounded retry
  state;
- distinct effects cover every processed operation, while any duplicate
  effects are retained and reconcile exactly with the at-least-once model;
- both replacement workers participate and no process exits unexpectedly;
- both database outages produce observable failure and recovery without
  restarting the surviving workers;
- cleanup makes progress before and after disruption and removes the complete
  seeded expired history without deleting current or failed work;
- the final durable state has no pending or processing remainder.

SQL Server and PostgreSQL run the same scenario and assertions. A shorter run
may be used while developing the runner, but it cannot close TE-L07.

## TE-L07 Result

`Run-DisruptionSoak.ps1` passed the contract configuration against SQL Server
under `artifacts/soak/20260823-210500` and PostgreSQL under
`artifacts/soak/20260823-210753`. Both runs used Dogfood commit `a816be2`,
TinyEvents commit `936794c`, four workers, 50,000 expired rows, two claimed
worker deaths with replacements, and two real five-second database outages.

SQL Server acknowledged 17,530 publishes and contained 17,533 durable current
operations after recovery. The three additional rows are explicit ambiguous
commits: the database committed before the interrupted connection could return
an acknowledgement. PostgreSQL acknowledged and durably contained 21,873.
The final SQL Server state contained 16,657 processed and 876 deliberately
failed messages; PostgreSQL contained 20,780 processed and 1,093 deliberately
failed messages. Neither retained pending or processing work.

Each provider recorded three duplicate effects across the deliberate worker
death boundaries while retaining one distinct effect for every processed
operation. Each also observed one consumer failure that was durable in the
dogfood side-effect record but whose later outbox failure update was
interrupted by process death. The gap is explicitly bounded to at most one
active consumer execution per terminated process; it is not misreported as
lost work.

Both replacement workers participated, every seeded expired row was removed,
cleanup progressed across disruption, surviving processes recovered after
both database outages, and final durable reconciliation passed. Peak observed
database connections were 29 for each provider. The largest individual .NET
process working set sampled was 141,393,920 bytes on SQL Server and 144,773,120
bytes on PostgreSQL. Final outbox allocations were 33,595,392 and 24,625,152
bytes respectively. These resource measurements describe this machine and
workload; they are not product ceilings.

## PROVIDER-1 Result

PostgreSQL already had real ADO.NET and EF Core integration coverage for due
claims, active and expired leases, competing workers, completion ownership,
retry scheduling, terminal failures, migrations, and cleanup. Its destructive
database-recovery suite also already passed TE-D01 through TE-D06. Repeating
those proofs under new IDs would add script count rather than confidence.

The remaining gap was process-level worker behavior. The existing
`Run-WorkerRecovery.ps1` runner now selects SQL Server or PostgreSQL through
the laboratory's existing database component; every scenario and assertion is
shared. The unchanged PostgreSQL run under
`artifacts/workers/20260823-211438/recovery` passed TE-W03, TE-W04, TE-W05,
TE-W07, idle and active TE-W08, and TE-W09 through TE-W13 from Dogfood commit
`89e771b` and TinyEvents commit `936794c`. This closes active-claim protection,
worker-death recovery, effect-before-death redelivery, lease loss, shutdown,
durable retries, terminal failure, multi-consumer redelivery, and duplicate
configured worker identity with the same observable contract as SQL Server.

## PACKAGE-1 Result

`samples/TinyEvents.PackageSmoke/Test-PackageSmoke.ps1 -Run` built the release
train, packed all six supported packages, restored the package-only sample
through an isolated NuGet cache, and built it without project references. The
runtime then passed the SQL Server and PostgreSQL EF Core and ADO.NET paths.

The accepted run used TinyEvents commit `cf9a8bd` and local package version
`0.1.0-local.20260823212038`. Each provider path resolved exactly one public
processing worker alongside the cleanup worker registered by the package. This
caught and removed the sample's stale assumption that TinyEvents registered a
single hosted service; no product behavior changed.

TinyEvents commit `9ce2148` then made the same package command validate each
candidate assembly against its published `0.1.0-alpha.3` package through the
.NET SDK package-validation target. All six package surfaces passed without a
compatibility suppression.

TinyEvents commit `e5425bb` added the suite-consistent manifest boundary to the
same smoke. Every package now proves its identity, author, MIT expression,
project and repository URLs, repository type, declared and included README,
description, and tags before a package consumer is restored.

## Resume Instruction

In a new session, read this file and [the roadmap](roadmap.md), inspect both
repository branches and working trees. `PACKAGE-1` is complete. Continue with
`BETA-GATE`: compose and run the mandatory gate from a clean checkout before
making the beta decision.
