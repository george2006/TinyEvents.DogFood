# TinyEvents Beta Hardening Execution Guide

This file is the working checkpoint for completing the TinyEvents beta. The
[roadmap](roadmap.md) remains the acceptance contract; this guide records the
order of work so a new session can resume without reconstructing decisions.

## Current Checkpoint

Current as of August 23, 2026:

- TinyEvents `main` at `52e6889` contains bounded processed-message cleanup for
  SQL Server and PostgreSQL, including ADO.NET and EF Core providers;
- Dogfood `main` at `1acb8d2` contains the `TE-L05-C` and complete
  `TE-L06-A` through `TE-L06-C2` scenarios and their measured evidence;
- Dogfood branch `hardening/cleanup-under-load` is the clean starting point for
  the remaining cleanup hardening work;
- the cleanup capability is not present in the latest published NuGet packages;
- TinyEvents documentation commit `c629baf` labels the current retention,
  batch, and interval values as candidates, repeats their next-release status,
  and exposes migration `002_AddProcessedCleanupIndex` from every provider
  package README;
- `TE-L05-A`, `TE-L05-B`, and `TE-L05-C` provide repeatable storage and
  retained-history evidence against both providers;
- cleanup defaults have not yet passed dogfood acceptance;
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
- the beta is not ready until cleanup, soak, provider, package, and final audit
  gates close.

The `FIX-1` characterization test demonstrated that disabled cleanup with a
custom provider failed dependency-injection build validation. Commit `35d3156`
defers `TinyOutboxCleanup` construction through an explicit service factory.
Disabled cleanup no longer requires `ITinyOutboxCleanupStore`; enabled cleanup
retains its existing startup validation. The worker test suite passes.

The post-merge documentation audit found no missing cleanup guide in
TinyEvents. Its root README, documentation index, worker guide, architecture,
migration guide, and dedicated retention guide describe the implemented
capability. Before `TE-L06-D`, TinyEvents documentation must still label the
current one-hour retention, 1,000-row batch, and one-second interval as
candidate defaults pending `TE-L06-D/E`. The worker guide should repeat the
next-release status for direct readers, and the four provider package READMEs
should reference migration `002_AddProcessedCleanupIndex`. Existing alpha.3
package release notes remain unchanged until release preparation.

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
| `TE-L06-D` | Dogfood | Next | Compare the same active workload with cleanup disabled and with the candidate policy enabled at 200, 400, and 800 messages per second. |
| `TE-L06-E` | Dogfood | Pending | Accept or change retention, batch, and interval defaults and publish the measured storage budget. |
| `TE-L07` | Dogfood | Pending | Run a timed soak with repeated worker and database disruption. |
| `PROVIDER-1` | Both | Pending | Close only provider guarantees not already demonstrated by shared evidence. |
| `PACKAGE-1` | Both | Pending | Pack the candidate and run supported consumers without project references. |
| `BETA-GATE` | Both | Pending | Run the clean-checkout gate, review public limitations, and make the explicit beta/no-beta decision. |

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

## Resume Instruction

In a new session, read this file and [the roadmap](roadmap.md), inspect both
repository branches and working trees, and continue `TE-L06-D` on Dogfood
branch `hardening/cleanup-under-load`. Implement the persisted contract without
adding a new product mode or duplicating existing process orchestration. Do not
modify a dirty checkout, repeat completed evidence without a reason, or advance
to a pull request before reviewing the complete branch diff.
