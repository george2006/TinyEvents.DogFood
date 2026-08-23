# TinyEvents Beta Hardening Roadmap

This roadmap lists the evidence still required before TinyEvents can be considered beta-ready. It does not repeat completed work.

Current as of August 23, 2026:

- 48 named behavioral contracts have executable evidence;
- contract compatibility, invalid-message isolation, transaction, worker, database-recovery, and concurrent-migration fundamentals have executable evidence;
- SQL Server and PostgreSQL pass the complete database-recovery suite;
- the final package and retention gates remain open.

See the [scenario catalog](scenario-catalog.md) for completed evidence and
copyable commands. The [beta execution guide](beta-hardening-execution.md)
records the current checkpoint and review-sized implementation order.

## 2. Schema and Application Deployment

- [x] `TE-S02` — Create representative in-flight state with the published `0.1.0-alpha.3` packages, upgrade to the beta candidate, migrate, and process supported messages.
  - [x] `TE-S02-A` — Restore only from nuget.org and create one pending, one reclaimable processing, and one failed message with published `0.1.0-alpha.3` packages.
  - [x] `TE-S02-B` — Pack the candidate from clean `main`, migrate the alpha database, drain supported work, and preserve the failed row.
  - [x] `TE-S02-C` — Run the unchanged upgrade contract against PostgreSQL.
- [x] `TE-S03` — Terminate a migration process and prove a later process can safely resume.
- [x] `TE-S04` — Characterize missing, partially created, and checksum-conflicting schemas with actionable diagnostics.
- [x] `TE-S05` — Run old and new application versions concurrently while messages remain in flight.

This phase is complete when a real application can upgrade without losing supported work or silently accepting an incompatible schema.

## 3. Load, Backlog, and Storage

- [x] `TE-L01` — Measure sustained publishing at 200, 400, and 800 committed requests per second, independently from consumer throughput, with identical durable assertions for SQL Server and PostgreSQL.
- [x] `TE-L02` — Measure a prebuilt 10,000-message backlog with 1, 2, 4, and 8 worker processes independently from publisher throughput, with identical durable assertions for SQL Server and PostgreSQL.
- [x] `TE-L03` — Sustain successful, transient, permanent, and slow processing together while proving unrelated progress, exact retries, terminal outcomes, and bounded connection usage.
- [x] `TE-L04` — Recover a controlled live backlog to no more than one second of incoming traffic while publishing continues, measuring recovery time and worker participation with identical durable assertions for SQL Server and PostgreSQL.
- [x] `TE-L05` — Measure bytes per pending, processing, processed, and failed row with representative payloads.
  - [x] `TE-L05-A` — Measure empty, 1 KB, and 16 KB pending payload curves from isolated empty-database baselines against SQL Server and PostgreSQL.
  - [x] `TE-L05-B` — Measure processing, processed, and failed states through real worker behavior.
  - [x] `TE-L05-C` — Measure claim and completion behavior as retained terminal history grows.
- [ ] `TE-L06` — Validate processed retention, explicit V1 failed-row preservation, cleanup batch size, and the documented storage budget against `TE-L05` evidence.
  - [x] `TE-L06-A` — Prove the exclusive cleanup cutoff and preservation of recent processed, pending, processing, and failed rows against SQL Server and PostgreSQL.
  - [x] `TE-L06-B` — Prove bounded batches and exact durable convergence while four independent cleanup processes compete against SQL Server and PostgreSQL.
  - [x] `TE-L06-C1` — Prove a replacement cleanup process resumes from the durable remainder after the original process is terminated during partial progress.
  - [x] `TE-L06-C2` — Prove one cleanup process survives database interruption and resumes after database recovery.
- [ ] `TE-L07` — Run a soak test with repeated worker and database disruption.

Existing evidence is reused where it proves the same behavior. A partial result is not marked complete until the missing measurement is executable and repeatable.

## 4. V1 Retention and Cleanup

Retention cleanup is the final planned TinyEvents V1 feature. Its production
implementation is merged into TinyEvents `main`; beta readiness remains blocked on the
dogfood evidence below.

The merged implementation has this deliberately narrow
contract:

- delete only `Processed` rows with `ProcessedAtUtc < cutoffUtc`;
- preserve rows exactly on the cutoff boundary;
- preserve `Pending`, `Processing`, and `Failed` rows;
- delete one atomic, bounded batch per cleanup interval;
- allow independent application instances to clean concurrently through
  provider row locking rather than a cleanup leader or lease;
- default to one-hour processed retention, a 1,000-row batch, and a one-second
  interval until dogfood evidence accepts or changes those values.

The next executable evidence must cover concurrent cleaners, process and
database interruption, active publication and processing, and sustained
200/400/800-message-per-second input. A default is not accepted merely because
the implementation compiles.

- [ ] Validate the candidate retention defaults from `TE-L05` and `TE-L06`; change them if executable evidence rejects them.
- [x] Demonstrate that cleanup deletes eligible processed rows in bounded batches.
- [x] Demonstrate that cleanup never deletes pending or actively claimed messages.
- [x] Prove cleanup can resume after process or database failure.
- [ ] Prove cleanup does not starve publishers or workers.
- [ ] Re-run load and recovery evidence with cleanup enabled.

## 5. Provider Evidence

- [ ] Compare the remaining SQL Server-only worker scenarios with existing PostgreSQL integration and database-recovery evidence.
- [ ] Add PostgreSQL destructive executions only where provider-specific behavior remains unproven.
- [ ] Keep the same observable assertions for both providers; do not create a weaker PostgreSQL contract.
- [ ] Complete package-consumer smoke tests for every supported EF Core and ADO.NET provider path.

The objective is equal product guarantees, not a duplicated script count.

## 6. Package and Release Gate

- [ ] Pack the beta candidate locally and run consumers against NuGet packages instead of project references.
- [ ] Verify public API compatibility from the last published alpha.
- [ ] Verify package metadata, license, symbols, and Source Link.
- [ ] Provide one documented command that executes every mandatory acceptance suite.
- [ ] Run the gate from a clean checkout and archive its manifests and results.
- [ ] Publish the accepted at-least-once limitations and operator responsibilities using [V1 product findings](v1-product-findings.md) as the reviewed source.
- [ ] Complete a final principal-engineer review and make an explicit beta or no-beta decision.

## Beta Completion Boundary

The beta is ready only when:

- no mandatory scenario has an unexplained failure or skip;
- no acknowledged business commit loses its outbox message;
- claims, retries, and recovery follow database-authoritative boundaries;
- duplicates match the documented at-least-once model;
- supported provider paths have equivalent guarantees;
- storage growth and retention are measured and bounded;
- the complete gate passes from a clean checkout using packaged artifacts.

## Explicitly Deferred Beyond V1

The following ideas remain documented but are not required for V1:

- a durable worker registry, heartbeat, or lease-fencing token;
- automatic renewal or progressive acquisition for batches whose cumulative processing time approaches `ClaimTimeout`;
- batched completion updates without measured evidence that they are needed;
- additional orchestration abstractions that do not close an observable scenario.

### Runtime resource hardening

After the V1 functional and storage gates close, add reproducible resource
profiles for:

- CPU saturation and throughput degradation under sustained publish, consume,
  retry, and cleanup load;
- managed allocations, heap growth, garbage-collection frequency, pause time,
  large-object-heap pressure, and recovery after backlog drain;
- process working-set and connection-pool stability during long soak tests;
- GPU utilization only if a future TinyEvents component introduces a real GPU
  workload. TinyEvents does not use GPU resources today, so a GPU benchmark now
  would not demonstrate a product property.

Resource gates must record the runtime, provider, database, payload profile,
worker count, and machine limits. Results are evidence for the tested
environment, not universal capacity promises.

Deferral is intentional. A demonstrated product problem must justify reopening these designs.
