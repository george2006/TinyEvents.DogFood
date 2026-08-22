# TinyEvents Beta Hardening Roadmap

This roadmap lists the evidence still required before TinyEvents can be considered beta-ready. It does not repeat completed work.

Current as of August 22, 2026:

- 31 named behavioral contracts have executable evidence;
- transaction, worker, database-recovery, and concurrent-migration fundamentals have executable evidence;
- SQL Server and PostgreSQL pass the complete database-recovery suite;
- the final package and retention gates remain open.

See the [scenario catalog](scenario-catalog.md) for completed evidence and copyable commands.

## 1. Contract Compatibility and Invalid Messages

- [ ] `TE-C07` — Reach the documented terminal state for an unknown event type.
- [ ] `TE-C08` — Reach the documented terminal state for malformed JSON or an incompatible payload.
- [ ] Prove that unknown or malformed messages do not stop later valid messages from being processed.

This phase is complete when deployments can evolve supported contracts and poison messages have an explicit, repeatable outcome.

## 2. Schema and Application Deployment

- [ ] `TE-S02` — Create representative in-flight state with the published `0.1.0-alpha.3` packages, upgrade to the beta candidate, migrate, and process supported messages.
- [ ] `TE-S03` — Terminate a migration process and prove a later process can safely resume.
- [ ] `TE-S04` — Characterize missing, partially created, and checksum-conflicting schemas with actionable diagnostics.
- [ ] `TE-S05` — Run old and new application versions concurrently while messages remain in flight.

This phase is complete when a real application can upgrade without losing supported work or silently accepting an incompatible schema.

## 3. Load, Backlog, and Storage

- [ ] `TE-L01` — Measure sustained publishing at explicit target rates.
- [ ] `TE-L02` — Separate publisher throughput, prebuilt-backlog drain rate, and database pressure. `TE-W02` already provides the first end-to-end scaling curve.
- [ ] `TE-L03` — Sustain mixed successful, transient, permanent, and slow processing. `TE-D05` already proves the recovery semantics on a bounded workload.
- [ ] `TE-L04` — Build and drain a large backlog while measuring recovery time and fairness.
- [ ] `TE-L05` — Measure bytes per pending, processing, processed, and failed row with representative payloads.
- [ ] `TE-L06` — Define processed and failed retention, cleanup batch size, and a documented storage budget from `TE-L05` evidence.
- [ ] `TE-L07` — Run a soak test with repeated worker and database disruption.

Existing evidence is reused where it proves the same behavior. A partial result is not marked complete until the missing measurement is executable and repeatable.

## 4. V1 Retention and Cleanup

Retention cleanup is the only planned TinyEvents V1 feature still blocked on dogfood evidence.

- [ ] Choose retention defaults from `TE-L05` and `TE-L06`; do not guess them in production code.
- [ ] Delete eligible terminal rows in bounded batches.
- [ ] Never delete pending or actively claimed messages.
- [ ] Prove cleanup can resume after process or database failure.
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
- [ ] Publish the accepted at-least-once limitations and operator responsibilities.
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
- batched completion updates without measured evidence that they are needed;
- additional orchestration abstractions that do not close an observable scenario.

Deferral is intentional. A demonstrated product problem must justify reopening these designs.
