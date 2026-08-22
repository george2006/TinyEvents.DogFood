# TinyEvents Beta Hardening Lab

## Status

This document defines the executable hardening work required before TinyEvents is treated as a beta candidate.

It is a test and product-validation plan. It does not authorize production-code changes by itself. Every discovered failure must first be reproduced by an executable scenario, reviewed, and then fixed in the smallest separate slice.

Use the [scenario catalog](scenario-catalog.md) for behavior demonstrated today and the [beta hardening roadmap](roadmap.md) for incomplete work. The implementation-slice history in this document preserves earlier hypotheses and failing baselines only when they are explicitly labeled as historical.

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

TinyEvents keeps two distinct identities:

- `TinyOutboxMessage.Id` identifies one durable outbox message.
- `TinyOutboxMessage.EventType` identifies the .NET contract used to find its dispatcher.

These responsibilities remain separate.

The current publisher and source generator share the same canonical runtime event-name contract. The completed `TE-C01` through `TE-C08` scenarios demonstrate that:

- top-level and nested non-generic event contracts process successfully;
- closed generic event contracts are rejected at build time with `TEV002`;
- moving a contract between assemblies works when its full type name remains unchanged;
- namespace or event-type renames require an explicit previous-name mapping for in-flight messages.
- adding an optional contract member preserves the meaning of a previously persisted payload.
- an event type absent from the worker exhausts its configured retries without blocking later valid work.
- malformed JSON exhausts its configured retries without blocking later valid work.

Applications declare a renamed durable contract through `AcceptPreviousEventName<TEvent>(previousEventName)`. TinyEvents then resolves the current generated dispatcher, deserializes the old payload into the current event type, and invokes the current consumers. The complete product contract and deployment guidance live in [Event Contracts and Durable Names](https://github.com/george2006/TinyEvents/blob/main/docs/event-contracts.md).

The consumer implementation type is not part of the persisted event identity. Renaming or moving an `IEventConsumer<TEvent>` implementation therefore requires no durable-name mapping as long as the event contract itself remains unchanged and the current consumer assembly is loaded before TinyEvents registration.

NServiceBus follows the same general model: it keeps a unique message ID separate from an enclosed .NET message-type name. Moving or renaming a contract is not automatic; its documented solution explicitly translates the previous type name to the new type. NServiceBus also rejects generic message definitions rather than pretending they have a safe evolution contract.

Official references:

- [NServiceBus message identity](https://docs.particular.net/nservicebus/messaging/message-identity)
- [NServiceBus message type detection](https://docs.particular.net/nservicebus/messaging/message-type-detection)
- [NServiceBus change/move message type sample](https://docs.particular.net/samples/serializers/change-message-type/)
- [NServiceBus evolving message contracts](https://docs.particular.net/nservicebus/messaging/evolving-contracts)

The beta decision is closed: TinyEvents supports old persisted names through explicit mappings. The API preserves POCO contracts, keeps message identity independent from type identity, and does not guess whether two differently named contracts represent the same event.

## Scenario Catalogue

Each identifier below defines a stable behavioral contract. Completed evidence is indexed in the [scenario catalog](scenario-catalog.md); incomplete contracts remain visible in the [roadmap](roadmap.md). Expected at-least-once duplicates must be measured and reported, not incorrectly classified as library failures.

### Contract and Upgrade

#### TE-C01 - Normal event round trip

Publish a top-level event with version 1 of the host, stop publishing, and prove that the hosted worker records one durable consumer effect.

#### TE-C02 - Nested event identity

Publish and consume a nested event through the complete persisted path using the canonical runtime event name.

#### TE-C03 - Closed generic event identity

Compile a closed generic event contract and prove that TinyEvents rejects it with the actionable `TEV002` diagnostic.

#### TE-C04 - Namespace rename with an in-flight message

Publish using the V1 contract, leave the message pending, stop V1, and start V2 with an explicit previous-name mapping to the event type in its new namespace. Prove that the in-flight message reaches the current consumer.

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

**Executable:** `.\operations\Run-PublishingLoad.ps1` runs this curve with workers stopped against SQL Server or PostgreSQL. Behavioral acceptance requires exact durable counts and zero failed commits. Whether the local machine sustained at least 95% of each requested rate remains separate, visible capacity evidence.

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

### BETA-1 - Event identity characterization — Complete

This slice first implemented `TE-C01` through `TE-C05` without changing the production identity contract. It reproduced the original behavior before the smallest reviewed product fix defined nested, generic, and in-flight rename ownership.

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

Execute TE-D01 through TE-D06 unchanged against SQL Server and PostgreSQL.

TE-D01 runs against SQL Server and PostgreSQL. It starts a worker while the selected database is unavailable. The worker reports the first four failures and selected repeated-failure milestones, remains alive, announces recovery after the same container returns, and processes the preserved message exactly once without a process restart.

TE-D02 runs against SQL Server and PostgreSQL. It proves a worker processes one message before the selected database disappears during polling, remains alive throughout the outage, announces recovery when the database returns, and processes a second message without restarting or duplicating either effect.

TE-D03 runs against SQL Server and PostgreSQL. It removes the selected database after a slow consumer has acquired a claim and before its durable effect. The resulting consumer failure cannot update the unavailable outbox, so no failed attempt is recorded. Once the database returns, the same process reclaims the expired lease, records one effect, completes the message, and announces recovery.

TE-D04 runs against SQL Server and PostgreSQL. It removes the selected database after the consumer effect is durable and while the same invocation is delayed before outbox completion. The completion update fails, the worker remains alive, and the same process redelivers after lease expiry. The final evidence contains two consumer invocations and one duplicate effect, making the at-least-once boundary explicit rather than concealing it.

TE-D05 runs against SQL Server and PostgreSQL. It keeps success, transient-failure, permanent-failure, and slow work in one backlog while the selected database restarts. The outage begins after the slow effect is durable but before completion. One unchanged worker recovers, drains all eligible work, exhausts the permanent failure, respects transient retries, and retains the expected duplicate slow effect with exact per-scenario evidence.

TE-D06 bounds every process to two pooled connections for the selected provider. Two workers deliberately exhaust their own pools while four concurrent publishers commit 100 messages. Both workers observe pool timeouts, remain alive, recover without restart, share the final drain, and produce exactly one durable effect per message.

The PostgreSQL EF Core real-database suite passed 65 tests with zero skips on 2026-08-21. It covers transactional publishing, provider-specific claim and completion behavior, retries, terminal failure, lease ownership, competing claims, and migrations. The separate destructive suite also passed `TE-D01` through `TE-D06` consecutively against PostgreSQL on 2026-08-21. That run proves recovery from physical container loss before polling and during active processing, the observable at-least-once boundary after a lost completion acknowledgement, mixed-load restart recovery, and bounded connection-pool recovery.

The destructive host selects one internal storage-provider implementation at startup. SQL Server and PostgreSQL each own their configuration, model mapping, database reset, durable probe writers, evidence queries, and physical connection creation without branching throughout the host or scenarios. The same executable scenarios and acceptance rules prove both providers; no provider-specific copies or weakened PostgreSQL assertions were introduced.

### BETA-6 - Transactions, contracts, and deployment

Complete the transactional, malformed-message, migration, alpha-upgrade, and rolling-upgrade scenarios.

TE-S01 starts eight independent application migrators against a fresh SQL Server or PostgreSQL database. Every process completes successfully while the durable result contains one outbox table and one exact `001_CreateTinyOutbox` history row. This proves process-level migration serialization in addition to each provider's real-database integration tests.

The unchanged process-level scenario passed against both providers on 2026-08-21: one process applied the migration, seven observed the current schema, and the durable history contained exactly one migration.

TE-T02 uses the normal application publisher inside an explicit database transaction, saves ten business rows and ten outbox messages together, and then rolls the transaction back. The independently observed durable state was empty against SQL Server and PostgreSQL on 2026-08-21. Together with the ten-operation commit proven by TE-T01, this also satisfies TE-T03's several-events all-or-nothing contract without a duplicate executable scenario.

TE-D06 also satisfies TE-T04 without a duplicate executable scenario. Four concurrent publisher processes each acknowledge a 25-operation commit. The durable result contains exactly 100 business rows, 100 outbox rows, and 100 distinct consumer effects with no duplicates. The unchanged evidence passed against SQL Server and PostgreSQL while the worker connection pools were deliberately exhausted.

TE-T05 writes business state and its outbox message inside an open transaction, then terminates the publisher process on each side of the commit boundary. Saved but uncommitted work disappears, a commit survives immediate process termination, and a normally acknowledged commit remains durable. The unchanged scenario passed against SQL Server and PostgreSQL on 2026-08-21.

TE-C06 publishes the V1 contract, then starts a V2 worker whose same durable event type adds one optional member. The SQL Server acceptance run on 2026-08-22 reached `Processed`, recorded exactly one durable effect, and observed the absent V2 member as `not-provided`. This demonstrates the supported additive evolution path without changing TinyEvents production code.

TE-C07 publishes one producer-only event followed by one registered event through the normal publisher API. With one configured maximum attempt, the SQL Server acceptance run on 2026-08-22 left the unknown event in `Failed`, retained the exact missing-dispatcher error, emitted `EventRetriesExhausted`, and processed the valid event later in the same batch with exactly one durable effect. This demonstrates that one unknown contract does not stop valid work behind it.

TE-C08 publishes a registered event through the normal API, replaces only its durable payload with malformed JSON through an external dogfood fault, and then publishes another valid event. The SQL Server acceptance run on 2026-08-22 left the malformed event in `Failed`, retained the JSON error, emitted `EventRetriesExhausted`, and processed the valid event later in the same batch with exactly one durable effect. TinyEvents production code contains no malformed-message test hook.

TE-S02-A restores the package-consuming upgrade host only from nuget.org and runs it against published `0.1.0-alpha.3`. The SQL Server acceptance run on 2026-08-22 created one pending message, one processing message with an expired lease, and one terminally failed message with one attempt. All three rows retained one exact event type, the schema contained one migration history row, and no candidate consumer effect existed.

TE-S02-B packs the release train from clean `main`, restores the same package-only host from those candidate packages, migrates the alpha-created database, and invokes the real outbox processor. The SQL Server acceptance run on 2026-08-22 processed the pending and expired-processing rows with exactly two distinct effects. It preserved the terminally failed row, its single attempt, and its exact error, while migration history remained at one row.

TE-S02-C runs that unchanged package-only contract against PostgreSQL. The parity acceptance run on 2026-08-22 passed both providers together against candidate commit `560d1d98724140bde31980bb1c357d3edf0bb8fa`. Each provider processed two supported rows with two distinct effects, preserved the exact terminal failure, and retained one migration history row. `TE-S02` is complete.

TE-S03 uses a temporary SQL Server DDL trigger or PostgreSQL event trigger to block the real migrator after it owns the provider migration lock. The runner observes that boundary from the database, terminates the application process, waits for the abandoned lock to disappear, removes the fault, and starts a replacement process. Acceptance allows any atomic resumable boundary after process death: no migration infrastructure, empty history infrastructure, or a completely committed migration. Mixed outbox/history state is rejected. Both providers passed on 2026-08-22 and recovered to one exact `001_CreateTinyOutbox` history row.

TE-S04 prepares three durable schema states through provider-specific external setup. A completely absent schema migrates to one exact current history row. Current history without its physical outbox is rejected as inconsistent and names the missing table. A checksum-conflicting history row is rejected with its migration version and checksum diagnostic. The initial run exposed that both providers silently accepted the missing outbox; TinyEvents fix `5396617` closed that hole. SQL Server and PostgreSQL then passed the unchanged scenario from merged `main` commit `4612c24` on 2026-08-22.

TE-S05 builds package-only application assemblies against published `0.1.0-alpha.3` and clean `main`, creates a separate 100-message alpha backlog, and starts both versions concurrently against one database. Durable effects retain operation and worker identity so acceptance proves both versions participated and every message produced one distinct effect. SQL Server and PostgreSQL each completed with 100 processed messages, 100 distinct operation effects, two worker identities, no remaining or failed work, and one migration row on 2026-08-22 using candidate commit `4612c24`.

### BETA-7 - Capacity, backlog, and retention

Execute TE-L01 through TE-L07. Make the retention decision from measured storage and claim behavior.

TE-L01 issues one real application scope and database commit per request while workers remain stopped. On 2026-08-22, both providers committed all 14,000 attempted requests across independent 200, 400, and 800 requests-per-second runs, with exact business and pending-outbox counts and no failed commit. SQL Server sustained 200.02, 399.49, and 576.04 committed requests per second; PostgreSQL sustained 199.85, 399.81, and 799.59. These are local capacity observations, not product guarantees. The repeatable result retains target achievement and committed-request p50, p95, and p99 latency so later runs can be compared without mixing publisher and worker throughput.

TE-L02 builds a fresh 10,000-message backlog before every worker-count variant, then measures drain with publishers stopped. On 2026-08-22, SQL Server processed 120.39, 246.15, 481.51, and 553.74 messages per second with 1, 2, 4, and 8 workers. PostgreSQL processed 235.04, 457.66, 716.49, and 1,121.03. All 80,000 messages across both providers reached `Processed`, every worker participated, and no failed attempt, lost effect, or duplicate effect was observed. SQL Server scaled almost linearly through four workers and then gained 15% at eight; PostgreSQL still gained 56% from four to eight. This provider contrast prevents the SQL Server knee from being misclassified as a universal TinyEvents coordination limit.

The first canonical SQL Server run also exposed the dogfood observation query as a deadlock victim while it scanned the active outbox. The worker remained correct and all unfinished rows stayed recoverable. The laboratory now retries only SQL Server error 1205 for this read-only exact observation; it does not use dirty reads or change TinyEvents production behavior. The unchanged canonical scenario then passed.

TE-L03 uses one application publisher to sustain a 2,000-message mix at a combined target of 200 requests per second: 80% successful, 10% transient, 5% permanent, and 5% delayed after their durable effect. Four worker processes run concurrently. Both providers committed all 2,000 messages, processed 1,900, deliberately exhausted 100, recorded exactly 700 failed attempts and 900 failure-plan invocations, produced 1,900 effects, and produced no duplicate. An intermediate durable observation proved successful work advanced while retries remained active. SQL Server settled 6.28 seconds after publishing completed; PostgreSQL settled in 6.23 seconds. The two configured three-second retry boundaries account for that expected tail.

The first PostgreSQL topology used four publisher processes solely to create four traffic classes. Their independent default pools exhausted the container's 100-connection limit and produced `53300: too many clients already`. TinyEvents correctly settled every accepted message, while the enhanced publisher evidence retained the rejected commits and root cause. The accepted scenario now uses one publisher process with four concurrent traffic definitions and limits every publisher and worker pool to 16 connections. This leaves explicit capacity for observation and administration without increasing the database limit or retrying rejected connections. The same bounded topology passes unchanged against SQL Server.

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
