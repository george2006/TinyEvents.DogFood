# TinyEvents Beta Hardening Lab

## Status

This document defines the executable hardening work required before TinyEvents is treated as a beta candidate.

It is a test and product-validation plan. It does not authorize production-code changes by itself. Every discovered failure must first be reproduced by an executable scenario, reviewed, and then fixed in the smallest separate slice.

## Objective

Prove TinyEvents under the conditions that make an outbox difficult:

- sustained publishing and processing load;
- several worker processes competing for the same outbox;
- workers stopping during processing;
- lease expiration and recovery;
- SQL Server or PostgreSQL becoming unavailable and returning;
- retries, exhausted retries, malformed messages, and unknown event types;
- application upgrades while messages remain in flight;
- backlog growth, drain, and long-lived outbox tables.

The lab must make every scenario repeatable. A successful manual demonstration is useful during development, but it is not release evidence.

## Evidence Rules

Every scenario must:

1. Run real application processes using the normal TinyEvents registration and hosted worker.
2. Use a real SQL Server or PostgreSQL database.
3. Introduce failure outside production TinyEvents code. No chaos hooks are added to the library.
4. Assert observable behavior from durable state, process exit state, and structured logs.
5. Produce a non-zero exit code when its contract is violated.
6. Save a run manifest, configuration, timestamps, assertions, database snapshots, and process logs under `artifacts/<suite>/<run-id>/`.
7. Be invokable again with one documented PowerShell command.

Unit and integration tests remain valuable after a defect is discovered. They are not substitutes for these process-level scenarios.

## Proposed Lab Shape

The smallest useful lab consists of:

- a dogfood ASP.NET host that publishes events through real application transactions;
- the real TinyEvents hosted worker;
- durable dogfood-only tables recording consumer attempts and business effects;
- Docker-hosted SQL Server and PostgreSQL;
- a PowerShell scenario runner that starts and stops databases and application processes;
- independently addressable worker processes with normal unique worker identities;
- versioned dogfood contracts used to reproduce in-flight application upgrades;
- scenario scripts stored in source control;
- SQL assertions and saved evidence for every run.

The durable probe tables belong to the dogfood application. They must not become TinyEvents product abstractions.

The first destructive host should use SQL Server and EF Core because it exercises the most common integrated path. PostgreSQL must then run the same database-engine-sensitive scenarios. ADO.NET transaction ownership remains part of the real-database provider matrix; it does not require duplicating the entire destructive host four times unless evidence reveals provider-specific behavior.

## Message Identity and Contract Evolution

TinyEvents currently has two different identities:

- `TinyOutboxMessage.Id` identifies one durable outbox message.
- `TinyOutboxMessage.EventType` identifies the .NET contract used to find its dispatcher.

These responsibilities must remain separate.

The publisher currently persists the runtime `Type.FullName`. The source generator emits its dispatcher key from a Roslyn type display name. Normal top-level non-generic events appear equivalent, but nested and closed-generic event names may not be represented identically. This is a hypothesis until an executable scenario reproduces it.

A namespace, type, or assembly rename is a different problem. An old event-type name remains stored with every in-flight message. A deployment containing only the renamed type cannot infer automatically that the two contracts are equivalent.

NServiceBus follows the same general model: it keeps a unique message ID separate from an enclosed .NET message-type name. Moving or renaming a contract is not automatic; its documented solution explicitly translates the previous type name to the new type. NServiceBus also rejects generic message definitions rather than pretending they have a safe evolution contract.

Official references:

- [NServiceBus message identity](https://docs.particular.net/nservicebus/messaging/message-identity)
- [NServiceBus message type detection](https://docs.particular.net/nservicebus/messaging/message-type-detection)
- [NServiceBus change/move message type sample](https://docs.particular.net/samples/serializers/change-message-type/)
- [NServiceBus evolving message contracts](https://docs.particular.net/nservicebus/messaging/evolving-contracts)

TinyEvents must make an explicit beta decision after executable characterization:

- support old persisted names through an explicit alias/mapping contract; or
- reject unsupported event shapes and document that renaming a contract requires draining the outbox first.

The preferred direction to evaluate is explicit aliases. It preserves POCO contracts, keeps message identity independent from type identity, and supports messages already persisted by an older deployment. No alias API will be designed until the upgrade scenario proves the current observable failure and ownership is reviewed.

## Scenario Catalogue

Each identifier below will become a committed executable scenario. Expected at-least-once duplicates must be measured and reported, not incorrectly classified as library failures.

### Contract and Upgrade

#### TE-C01 - Normal event round trip

Publish a top-level event with version 1 of the host, stop publishing, and prove that the hosted worker records one durable consumer effect.

#### TE-C02 - Nested event identity

Publish and consume a nested event through the complete persisted path. The scenario either succeeds or demonstrates a dispatcher-key mismatch.

#### TE-C03 - Closed generic event identity

Attempt the complete persisted round trip for a closed generic event. The beta contract must either support it consistently or reject it at build/startup with an actionable diagnostic.

#### TE-C04 - Namespace rename with an in-flight message

Publish using the V1 contract, leave the message pending, stop V1, and start V2 containing the same type name in a new namespace. The result establishes whether an explicit alias is required and later verifies that alias behavior.

#### TE-C05 - Contract moved to another assembly

Repeat the in-flight upgrade while preserving the namespace/type name and moving the contract assembly. Prove the exact supported behavior.

#### TE-C06 - Additive payload evolution

Consume a V1 payload with a V2 contract containing an optional added property. Preserve the original business meaning.

#### TE-C07 - Unknown event type

Persist an event whose dispatcher is absent. Prove retry count, final status, durable error evidence, and worker survival.

#### TE-C08 - Malformed payload

Process invalid JSON for a registered event. Prove retry/failure behavior and that subsequent valid messages continue processing.

### Transactional Publishing

#### TE-T01 - Business transaction commits

Commit business state and its outbox messages atomically and process all committed events.

#### TE-T02 - Business transaction rolls back

Roll back after publishing. Neither business state nor outbox rows may survive.

#### TE-T03 - Several events in one transaction

Publish multiple events, commit once, and prove all-or-nothing durability.

#### TE-T04 - Concurrent publishers

Publish from concurrent requests while recording request success, generated message IDs, commit outcome, and durable row count.

#### TE-T05 - Publisher process terminates around commit

Terminate publishers at varying points around transaction completion. Every acknowledged commit must be represented durably; rolled-back work must not appear.

### Workers, Claims, and Leases

#### TE-W01 - One worker baseline

Measure a single worker processing a known backlog with no injected failure.

#### TE-W02 - Competing worker processes

Run 2, 4, and 8 independent worker processes against one outbox. Prove that one active lease is granted per message and record final effects, retries, and throughput.

#### TE-W03 - Active claim is not stolen

Hold a consumer inside the configured claim duration while other workers poll. No other worker may process that message.

#### TE-W04 - Worker dies during consumer execution

Wait until SQL shows the message as processing, terminate the owning process, allow the lease to expire, and prove another process reclaims it.

#### TE-W05 - Side effect completes before worker death

Persist a dogfood business effect, terminate the worker before the outbox message is marked processed, and prove the expected at-least-once redelivery. The run must expose duplicate handler invocation rather than conceal it.

#### TE-W06 - Worker restarts before lease expiry

Restart capacity immediately after a worker dies. Prove that the active lease remains protected and processing resumes only after its valid boundary.

#### TE-W07 - Long consumer exceeds claim timeout

Run a handler longer than `ClaimTimeout` with competing workers. Capture concurrent/duplicate invocation as an explicit operational risk of the no-heartbeat V1 design.

#### TE-W08 - Graceful cancellation

Stop a host normally during idle polling and during active consumer work. Prove cancellation classification, process shutdown, and durable message state.

#### TE-W09 - Retry survives process restart

Fail a message, stop all workers during its retry delay, restart them, and prove that attempt count and `NextAttemptAtUtc` remain authoritative.

#### TE-W10 - Transient failure recovers

Fail the first N attempts and then succeed. Prove exact attempt progression, retry timing boundaries, final status, and continued processing of unrelated messages.

#### TE-W11 - Permanent failure exhausts retries

Always fail. Prove the terminal failed state, maximum attempt behavior, durable error evidence, and worker survival.

#### TE-W12 - Multiple consumers, later consumer fails

Allow an earlier consumer to succeed and a later consumer to fail. Prove that the entire event is retried and the earlier consumer may run again under the documented one-message-per-event at-least-once model.

#### TE-W13 - Duplicate configured worker identity

Start two processes with the same explicitly configured worker ID. Establish and document whether startup must reject this configuration or whether uniqueness remains an operator responsibility.

### Database Failure and Recovery

#### TE-D01 - Database unavailable at worker startup

Start workers before SQL is available, then start SQL. Prove bounded failure logging and automatic recovery without restarting the worker.

#### TE-D02 - Database disappears during claiming

Stop the database while workers are polling/claiming, restore it, and prove recovery and eventual backlog drain.

#### TE-D03 - Database disappears during consumer execution

Stop SQL after a message is claimed while its consumer is active. Prove the observable outcome, lease recovery, and at-least-once effects after SQL returns.

#### TE-D04 - Database disappears while marking processed

Complete the consumer effect, interrupt SQL before the completion update, restore SQL, and prove the expected retry without losing the original message.

#### TE-D05 - Database restart under mixed load

Publish successes, transient failures, permanent failures, and slow events while restarting SQL. Prove worker survival, durable state consistency, and eventual drain of eligible messages.

#### TE-D06 - Connection pressure

Run several publishers and workers with a deliberately bounded connection pool. Prove that temporary pool exhaustion does not corrupt claims or terminate hosted workers.

### Schema and Deployment

#### TE-S01 - Concurrent application migrations

Start several application instances against a fresh database. Prove migration lock serialization and identical final history.

#### TE-S02 - Published alpha upgrade

Create the database using published `0.1.0-alpha.3` packages, leave representative pending/processing/failed rows, upgrade to the beta packages, migrate, and process supported rows.

#### TE-S03 - Migration interrupted and resumed

Interrupt an application during migration, restart it, and prove that committed migrations remain valid while incomplete work resumes safely.

#### TE-S04 - Missing or incompatible schema

Start the worker against missing, partially created, and checksum-conflicting schemas. Prove the documented startup/runtime behavior and diagnostics.

#### TE-S05 - Rolling application upgrade

Run old and new worker binaries concurrently against the same compatible schema and in-flight contracts. Prove the explicitly supported rolling-upgrade boundary.

### Load, Backlog, and Storage

#### TE-L01 - Sustained publish rates

Drive 200, 400, and 800 committed publishing requests per second. Measure publisher latency, committed events per second, errors, and outbox growth independently from consumer throughput.

#### TE-L02 - Worker scaling

Drain identical backlogs with 1, 2, 4, and 8 worker processes. Measure claim rate, processed events per second, database pressure, scaling efficiency, and duplicate effects.

#### TE-L03 - Mixed failure load

Run a stable mix of success, transient failure, permanent failure, and slow events. Verify fairness, retry pressure, unrelated-message progress, and terminal counts.

#### TE-L04 - Backlog recovery

Publish while workers are stopped, build a controlled backlog, start workers, and measure recovery time without changing the publishing rate.

#### TE-L05 - Large historical outbox

Measure claim and completion behavior with growing processed history. The initial checkpoints are 10,000, 100,000, and 1,000,000 rows, adjusted only when measured cost justifies it.

#### TE-L06 - Storage budget and retention decision

Measure bytes per pending, processing, processed, and failed row for representative payloads. Use the evidence to define processed-message retention, failed-message retention, cleanup batch size, and a safe storage budget. Do not build cleanup before this decision.

#### TE-L07 - Soak and repeated disruption

Run sustained mixed traffic while repeatedly terminating workers and restarting the database. Record backlog, duplicate effects, memory, connection count, storage growth, and recovery time across the complete run.

## Required Measurements

Every load or disruption run records at least:

- requested and committed publish rate;
- publish latency p50, p95, and p99;
- messages claimed, processed, retried, failed, and pending;
- consumer invocations and durable business effects;
- duplicate invocations and duplicate durable effects;
- backlog size and oldest eligible message age;
- recovery time after each injected failure;
- active worker count and worker IDs;
- database size, outbox row counts by status, and connection pressure;
- process exits, unexpected exceptions, and structured TinyEvents logs.

Throughput never overrides correctness. A run that reaches 800 requests per second while losing or incorrectly claiming messages fails.

## Implementation Slices

Only one slice proceeds at a time. Each slice stops after executable evidence, diff, and principal review.

### BETA-1 - Event identity characterization

Implement TE-C01 through TE-C05 without changing the production identity contract. Reproduce the current behavior first. Review nested/generic support and in-flight rename ownership before designing a fix.

Run the complete identity characterization with:

```powershell
.\identity\Run-IdentityScenarios.ps1
```

Run one independently addressable scenario with `-Scenario TE-C01` through `-Scenario TE-C05`. Evidence is retained under `artifacts/identity/<run-id>/`.

The first SQL Server baseline on 2026-08-20 demonstrated:

- TE-C01 processed a shared top-level contract and recorded one durable effect;
- TE-C02 failed because the nested runtime name uses `+` while its generated dispatcher key does not;
- TE-C03 failed because the closed-generic runtime name is not the generated dispatcher key;
- TE-C04 failed because the persisted V1 namespace has no V2 dispatcher;
- TE-C05 processed a contract moved between assemblies because TinyEvents persists the full type name without assembly identity.

That run was the pre-fix characterization baseline. The beta acceptance contract now requires nested events and explicit previous-name mappings to process successfully, generic event contracts to fail compilation with `TEV002`, and assembly moves that preserve the full type name to remain compatible.

The post-fix SQL Server acceptance run on 2026-08-20 passed all five outcomes:

- TE-C01, TE-C02, TE-C04, and TE-C05 reached `Processed` and recorded exactly one durable effect;
- TE-C03 failed compilation with the expected `TEV002` diagnostic;
- the runner reported `AcceptancePassed = True` for every scenario.

### BETA-2 - Real-database provider parity

Close the currently asymmetric SQL Server/PostgreSQL evidence for claim, completion, retry, failed state, lease loss, and end-to-end processing. Production changes require a red real-database test.

### BETA-3 - Dogfood host and evidence recorder

Create the smallest real hosted-worker application, durable probe tables, Docker configuration, and scenario artifact format. Prove TE-T01 and TE-W01.

Implemented by `operations/Run-OperationalBaseline.ps1`. The first SQL Server EF Core acceptance run on 2026-08-20 proved:

- business rows and outbox messages committed together for TE-T01;
- one independently hosted worker drained 100 queued messages for TE-W01;
- every outbox message reached `Processed`;
- every committed operation produced one durable effect;
- no duplicate effect was observed;
- worker logs, observations, timings, configuration, and repository commits were retained per run.

### BETA-4 - Claims, crashes, and several workers

Execute TE-W02 through TE-W13. Fix only demonstrated product defects; retain honest at-least-once behavior.

The first TE-W02 SQL Server EF Core run on 2026-08-20 processed three independent 1,000-message workloads with 2, 4, and 8 worker processes. Every worker claimed and processed distinct rows, per-worker claim counts exactly matched durable effect counts, and no failed attempt or duplicate effect was observed. End-to-end capacity increased from 183 to 248 to 280 messages per second. These values include concurrent publication and are not isolated worker-drain throughput.

The first TE-W03 and TE-W04 SQL Server EF Core run on 2026-08-20 proved both sides of the lease boundary using the SQL Server clock. A competing process could not steal a live claim. After the owning process was terminated during consumer execution, the claim remained protected before `ClaimExpiresAtUtc`; a second process then reclaimed and completed it after expiry. Both scenarios finished with one durable effect, no failed attempt, and no duplicate effect.

TE-W05 then terminated the owner after its durable consumer effect but before outbox completion. The replacement worker respected the remaining lease, redelivered the event after expiry, and completed the outbox message. The durable evidence contained two consumer invocations for the same operation and one duplicate. That duplicate is the expected at-least-once boundary, not message loss or an engine defect; consumers that cannot tolerate repeated effects require application-level idempotency.

TE-W04 also satisfies TE-W06 without a duplicate executable scenario: it starts replacement capacity immediately after the owner dies, proves the active lease remains protected, and resumes only beyond the SQL lease boundary.

TE-W07 ran a ten-second consumer under a five-second claim with a competing worker. SQL evidence showed the competitor completed after the original lease expired while the slow invocation was still active. The slow invocation then persisted a second effect, detected its lost completion lease through `TinyOutboxLeaseLostException`, emitted the expected structured warning, and remained alive. This is an accepted V1 limitation of claims without heartbeat renewal.

TE-W08 exercised normal host cancellation while idle and during a delayed consumer. Both worker processes reported graceful shutdown and exited with code zero. Idle shutdown changed no durable state. Active cancellation left the message claimed and recoverable, recorded neither a consumer effect nor a failed attempt, and a replacement worker completed it once the SQL lease expired.

TE-W09 rejected the first consumer invocation, persisted `AttemptCount = 1` and `NextAttemptAtUtc`, and stopped all worker capacity during the retry delay. A replacement process started before eligibility without invoking the consumer. It completed the second invocation only after the SQL retry boundary, producing one durable effect and no duplicate. Retry state therefore survives process loss and remains database-authoritative.

TE-W10 rejected one message on its first two invocations while an unrelated message completed during the first retry delay. SQL-recorded attempt times proved both retry boundaries were respected. The same worker survived both failures and completed the third invocation, leaving two processed messages, two durable effects, and no duplicate.

TE-W11 rejected one message on all three configured attempts while an unrelated message completed normally. SQL-recorded attempt times proved both retry boundaries were respected. The terminal row retained `AttemptCount = 3`, no further retry boundary, and the exact final error while the worker remained alive.

TE-W12 registered two consumers for one isolated dogfood event. The recording consumer completed before the later consumer failed once. Whole-message retry invoked the recording consumer again, leaving two effects for one operation and exposing the documented at-least-once boundary. The scenario does not promote consumer execution order to a public contract.

TE-W13 assigned the same explicit worker ID to two slow processes. The second process reclaimed the expired lease, but the original process subsequently marked the row processed because the durable owner value could not distinguish them. Both invocations completed and produced one duplicate effect. Generated worker IDs remain process-unique; uniqueness of manually configured IDs is an explicit V1 operator responsibility.

#### Post-V1 - Worker instance fencing and heartbeat

Evaluate a durable worker-instance identity with an expiring heartbeat only after V1. A future design may separate the operator-facing worker name from a process-incarnation token, detect concurrently duplicated configured names, fence stale processes, and renew claims during legitimately long consumer execution. This work requires an explicit worker-lifecycle model and durable schema; it is not part of V1 hardening. V1 already generates a process-unique ID containing machine name, process ID, and a GUID whenever the operator does not configure one.

Run the repeatable lease scenarios with:

```powershell
.\operations\Run-WorkerRecovery.ps1
```

Processed rows remain retained. Cleanup is not part of BETA-4 and must not be implemented before TE-L05 measures storage cost and defines explicit retention and deletion budgets.

The first scaling curve also makes batched completion a load-test hypothesis. Evaluate it only if isolated measurements attribute material cost to per-message `MarkProcessed` round-trips. Any design must first measure the larger at-least-once redelivery window created when consumer effects complete before a pending completion batch is persisted.

#### Worker laboratory structure

The proven worker laboratory is split by scenario and responsibility without changing behavior:

```text
operations/
  scenarios/
    TE-W03-active-claim.ps1
    TE-W04-worker-death-recovery.ps1
    TE-W05-effect-before-death.ps1
    TE-W07-long-consumer-lease-loss.ps1
    TE-W08-idle-shutdown.ps1
    TE-W08-active-shutdown.ps1
    TE-W09-retry-survives-restart.ps1
    TE-W10-transient-failure-recovers.ps1
    TE-W11-permanent-failure-exhausts-retries.ps1
    TE-W12-later-consumer-failure.ps1
    TE-W13-duplicate-worker-identity.ps1
  support/
    Process.ps1
    SqlServer.ps1
    Workers.ps1
    Observations.ps1
    Assertions.ps1
```

The split is a readability refactor over executable evidence, not a scenario framework. Each scenario can run through its named file or the suite's `-Scenario` selector. The suite retains one command that executes all scenarios and produces the existing manifest. Shared support contains only behavior repeated by the committed scenarios.

### BETA-5 - Database failure and recovery

Execute TE-D01 through TE-D06 against SQL Server, then repeat database-sensitive contracts against PostgreSQL.

TE-D01 runs against SQL Server and PostgreSQL. It starts a worker while the selected database is unavailable. The worker reports the first four failures and selected repeated-failure milestones, remains alive, announces recovery after the same container returns, and processes the preserved message exactly once without a process restart.

TE-D02 proves a worker processes one message before SQL Server disappears during polling, remains alive throughout the outage, announces recovery when SQL returns, and processes a second message without restarting or duplicating either effect.

TE-D03 removes SQL Server after a slow consumer has acquired a claim and before its durable effect. The resulting consumer failure cannot update the unavailable outbox, so no failed attempt is recorded. Once SQL returns, the same process reclaims the expired lease, records one effect, completes the message, and announces recovery.

TE-D04 removes SQL Server after the consumer effect is durable and while the same invocation is delayed before outbox completion. The completion update fails, the worker remains alive, and the same process redelivers after lease expiry. The final evidence contains two consumer invocations and one duplicate effect, making the at-least-once boundary explicit rather than concealing it.

TE-D05 keeps success, transient-failure, permanent-failure, and slow work in one backlog while SQL Server restarts. The outage begins after the slow effect is durable but before completion. One unchanged worker recovers, drains all eligible work, exhausts the permanent failure, respects transient retries, and retains the expected duplicate slow effect with exact per-scenario evidence.

TE-D06 bounds every process to two pooled SQL connections. Two workers deliberately exhaust their own pools while four concurrent publishers commit 100 messages. Both workers observe pool timeouts, remain alive, recover without restart, share the final drain, and produce exactly one durable effect per message.

The PostgreSQL EF Core real-database suite passed 65 tests with zero skips on 2026-08-21. It covers transactional publishing, provider-specific claim and completion behavior, retries, terminal failure, lease ownership, competing claims, and migrations. Physical PostgreSQL container loss and recovery remains a separate destructive parity gate; the integration suite is not presented as evidence for that behavior.

The destructive host now selects one internal storage-provider implementation at startup. SQL Server and PostgreSQL each own their configuration, model mapping, database reset, durable probe writers, and evidence queries without branching throughout the host. The same executable has proved PostgreSQL reset, migration, publishing, hosted processing, transient retry, and durable inspection. Physical PostgreSQL failure and connection-pressure scenarios remain pending; the existing scenarios and acceptance rules remain provider-independent and will not be duplicated.

### BETA-6 - Transactions, contracts, and deployment

Complete the transactional, malformed-message, migration, alpha-upgrade, and rolling-upgrade scenarios.

TE-S01 starts eight independent application migrators against a fresh SQL Server database. Every process completes successfully while the durable result contains one outbox table and one exact `001_CreateTinyOutbox` history row. This proves process-level migration serialization in addition to the provider's real-database integration tests.

### BETA-7 - Capacity, backlog, and retention

Execute TE-L01 through TE-L07. Make the retention decision from measured storage and claim behavior.

### BETA-8 - Package and release gates

Add clean package-consumer smoke, published-alpha upgrade, public API compatibility, package metadata, symbols, Source Link, documentation, and the complete dogfood acceptance command to release automation.

### BETA-9 - Final principal audit

Run every mandatory scenario from a clean checkout, archive the evidence, list accepted limitations, and decide whether the candidate may be tagged beta.

## Beta Acceptance Boundary

The beta is not approved merely because the normal test suite is green.

It requires:

- no unexplained message loss;
- deterministic lease ownership under competing processes;
- demonstrated recovery after worker and database loss;
- an explicit, executable event-refactor contract;
- retries and duplicates matching the documented at-least-once model;
- complete real-database provider evidence with no skipped mandatory tests;
- measured load, backlog, and storage behavior;
- every destructive scenario repeatable from source control;
- no unresolved correctness finding in the supported provider matrix.
