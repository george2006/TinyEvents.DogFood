# TinyEvents V1 Product Findings

This document is the source for public product documentation about demonstrated V1 operational boundaries. It contains behavior TinyEvents cannot eliminate without changing its delivery model or adding infrastructure outside the V1 scope.

These findings are not hidden test failures. Each one has executable evidence, an explicit operator response, and a documented product decision.

This file is also the publication queue for the TinyEvents product page. Every accepted V1 limitation recorded here must be represented in public documentation before the release gate closes; findings are not considered closed merely because the engine will not change.

## At-Least-Once Delivery After a Durable Effect

**Observed behavior:** A worker can persist a consumer effect and lose the opportunity to mark its outbox message processed. Once the claim expires, redelivery invokes the consumer again.

**Evidence:** `TE-W05` terminates the worker after its effect and before completion. `TE-D04` removes the database at the same boundary. Both retain the expected duplicate invocation.

**Product impact:** TinyEvents does not guarantee exactly-once side effects.

**Operator action:** Consumers must make unsafe external effects idempotent or retain their own processed-message identity.

**V1 decision:** Accepted and documented as part of the at-least-once contract.

## Consumer or Batch Duration Exceeds the Claim

**Observed behavior:** A competing worker may reclaim a message when its claim expires before the original worker completes. The duration risk applies both to one slow consumer and to the cumulative sequential processing time of an already claimed batch.

**Evidence:** `TE-W07` runs a ten-second consumer with a five-second claim and observes overlapping redelivery. The first 10,000-row `TE-L05-B` preparation used four workers, `BatchSize = 50`, and the deliberately short five-second dogfood claim. Every message reached `Processed`, but 10,045 durable effects exposed 45 duplicates.

**Product impact:** `ClaimTimeout` is a lease for the complete claimed batch, not a per-handler timeout.

**Operator action:** Configure `ClaimTimeout` above the worst-case time needed to consume and persist completion for the entire batch, or reduce `BatchSize`.

**V1 decision:** Accepted. Automatic heartbeat renewal and progressive claims remain post-V1 design work.

## Whole-Event Retry with Multiple Consumers

**Observed behavior:** If one consumer succeeds and a later consumer fails, retrying the outbox message invokes every consumer again, including the one that already succeeded.

**Evidence:** `TE-W12` retains two effects from the earlier successful consumer after the later consumer rejects the first delivery.

**Product impact:** TinyEvents tracks delivery per event, not independent completion state per consumer.

**Operator action:** Every consumer attached to the same event must tolerate repeated invocation.

**V1 decision:** Accepted. Per-consumer durable checkpoints would materially change the storage and delivery model.

## Explicit Worker IDs Must Be Unique

**Observed behavior:** Two active processes configured with the same worker ID are indistinguishable as durable claim owners. After lease reassignment, a stale process with that shared identity can still complete the row.

**Evidence:** `TE-W13` runs two processes with one configured ID and retains the resulting duplicate effect.

**Product impact:** Manually configured worker IDs are an operator-controlled fencing boundary.

**Operator action:** Keep explicitly configured worker IDs unique across simultaneously running processes. The default generated IDs are process-unique.

**V1 decision:** Accepted. A durable worker registry and process-incarnation fencing remain post-V1 work.

## A Lost Commit Acknowledgement Has an Ambiguous Outcome

**Observed behavior:** A database can commit the business transaction and close
the connection before the publisher receives the acknowledgement. Retrying the
application operation blindly may create a second business operation even
though the first outbox message is durable.

**Evidence:** `TE-T05` proves the two sides of the commit boundary. `TE-L07`
retained three SQL Server commits whose acknowledgements were lost during a
database interruption and reconciled them from durable business identity.

**Product impact:** TinyEvents guarantees that an acknowledged business commit
contains its outbox message. It cannot turn an interrupted database commit into
a known client-side outcome.

**Operator action:** Give retriable business operations an application-level
idempotency key or reconcile their durable state before retrying an ambiguous
commit.

**V1 decision:** Accepted. TinyEvents does not retry or recreate the caller's
business transaction.

## Event Names Are Durable Contracts

**Observed behavior:** Renaming an event type or namespace changes its default
durable name. Existing messages keep the previous name, and TinyEvents cannot
infer whether a new type is a rename or a different business event.

**Evidence:** `TE-C04` processes an in-flight renamed event through an explicit
previous-name mapping. `TE-C05` proves that an assembly move is compatible when
the full type name is unchanged.

**Product impact:** A namespace or type rename without a mapping is a breaking
change for in-flight messages. Adding a mapping does not automatically requeue
rows that already reached `Failed`.

**Operator action:** Deploy an explicit previous-name mapping before the rename
and keep it for as long as old messages can remain pending or retryable.

**V1 decision:** Accepted. TinyEvents preserves POCO contracts and requires an
explicit mapping instead of guessing durable identity.

## Failed Rows Are Preserved in V1

**Observed behavior:** Unknown event types, malformed payloads, and exhausted
consumer retries become terminal `Failed` rows. Processed cleanup deliberately
does not remove them.

**Evidence:** `TE-C07`, `TE-C08`, and `TE-W11` retain the actionable terminal
error. `TE-L06-A` proves cleanup preserves failed rows while deleting only
eligible processed rows.

**Product impact:** Failed-row storage can grow independently of processed
retention, and adding a contract mapping does not replay an already failed row.

**Operator action:** Monitor failed-row growth and use an explicit operational
investigation, removal, or future replay procedure.

**V1 decision:** Accepted. The V1 schema has no authoritative terminal-failure
timestamp for safe automatic retention.

## Migrations Reject Drift Instead of Repairing It

**Observed behavior:** A current migration history without its physical outbox,
or a stored migration with a conflicting checksum, is rejected.

**Evidence:** `TE-S04` first exposed acceptance of a missing outbox, drove the
product fix, and now proves both SQL Server and PostgreSQL reject inconsistent
state with actionable diagnostics.

**Product impact:** Built-in migrations are forward-only. TinyEvents does not
infer or repair manually altered schemas and provides no down migration.

**Operator action:** Back up and reconcile schema drift explicitly before
starting the application with a conflicting database.

**V1 decision:** Accepted after closing silent acceptance. Refusing ambiguous
schema state is the supported behavior.

## Capacity and Storage Results Are Environment-Specific

**Observed behavior:** Worker scaling, publisher saturation, row size, and
cleanup interference differed materially between SQL Server and PostgreSQL on
the same machine.

**Evidence:** `TE-L01` through `TE-L06` retain provider-specific throughput,
latency, connection, row-size, and retention measurements. SQL Server's local
800-request target saturated while PostgreSQL sustained it; neither result is a
universal product ceiling.

**Product impact:** TinyEvents cannot promise a fixed throughput or database-
size budget independent of payload, provider, schema, hardware, and topology.

**Operator action:** Use the published formulas as a starting point and validate
retention, batch, claim, pool, and cleanup settings against the real workload.

**V1 decision:** Accepted. Measurements are reproducible evidence, not marketing
capacity guarantees.

## Public Documentation Checklist

Before the V1 release gate closes, product documentation must explain:

- that TinyEvents provides atomic outbox persistence and at-least-once delivery, not exactly-once external effects;
- how `BatchSize` and `ClaimTimeout` interact;
- why consumers must be idempotent;
- how multiple consumers affect retry behavior;
- why explicit worker IDs must be unique;
- how to handle an ambiguous commit acknowledgement;
- why durable event renames require an explicit previous-name mapping;
- that failed rows require monitoring and an explicit operational procedure;
- that migrations reject drift rather than repairing it;
- which defaults are safe starting points and which values require workload-specific measurement.

The public wording must link guarantees to demonstrated behavior without presenting dogfood throughput or timing as universal production capacity.
