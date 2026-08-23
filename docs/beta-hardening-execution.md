# TinyEvents Beta Hardening Execution Guide

This file is the working checkpoint for completing the TinyEvents beta. The
[roadmap](roadmap.md) remains the acceptance contract; this guide records the
order of work so a new session can resume without reconstructing decisions.

## Current Checkpoint

Current as of August 23, 2026:

- TinyEvents `main` at `04389d8` contains bounded processed-message cleanup for
  SQL Server and PostgreSQL, including ADO.NET and EF Core providers;
- Dogfood branch `hardening/retained-history` contains the `TE-L05-C` scenario
  and its measured evidence, but has not been merged into Dogfood `main`;
- the cleanup capability is not present in the latest published NuGet packages;
- `TE-L05-A`, `TE-L05-B`, and `TE-L05-C` provide repeatable storage and
  retained-history evidence against both providers;
- cleanup defaults and runtime behavior have not yet passed dogfood acceptance;
- the beta is not ready until cleanup, soak, provider, package, and final audit
  gates close.

The `FIX-1` characterization test demonstrated that disabled cleanup with a
custom provider failed dependency-injection build validation. Commit `35d3156`
defers `TinyOutboxCleanup` construction through an explicit service factory.
Disabled cleanup no longer requires `ITinyOutboxCleanupStore`; enabled cleanup
retains its existing startup validation. The worker test suite passes.

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
| `TE-L06-A` | Dogfood | Next | Prove cutoff exclusivity and preservation of pending, processing, failed, and boundary rows through both real providers. |
| `TE-L06-B` | Dogfood | Pending | Prove bounded deletion and safe progress with concurrent cleanup processes. |
| `TE-L06-C` | Dogfood | Pending | Prove cleanup resumes after process termination and database interruption. |
| `TE-L06-D` | Dogfood | Pending | Run cleanup during active publishing and processing at 200, 400, and 800 messages per second and measure interference. |
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

## Resume Instruction

In a new session, read this file and [the roadmap](roadmap.md), inspect both
repository branches and working trees, and continue the first incomplete slice.
Do not modify a dirty checkout, repeat completed evidence without a reason, or
advance to a pull request before reviewing the complete branch diff.
