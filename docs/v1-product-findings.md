# TinyEvents V1 Product Findings

This document is the source for public product documentation about demonstrated V1 operational boundaries. It contains behavior TinyEvents cannot eliminate without changing its delivery model or adding infrastructure outside the V1 scope.

These findings are not hidden test failures. Each one has executable evidence, an explicit operator response, and a documented product decision.

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

## Public Documentation Checklist

Before the V1 release gate closes, product documentation must explain:

- that TinyEvents provides atomic outbox persistence and at-least-once delivery, not exactly-once external effects;
- how `BatchSize` and `ClaimTimeout` interact;
- why consumers must be idempotent;
- how multiple consumers affect retry behavior;
- why explicit worker IDs must be unique;
- which defaults are safe starting points and which values require workload-specific measurement.

The public wording must link guarantees to demonstrated behavior without presenting dogfood throughput or timing as universal production capacity.
