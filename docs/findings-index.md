# TinyEvents Beta Findings Index

This index is the front door to what the beta laboratory learned. It separates
product boundaries from fixed correctness defects and from limitations in the
laboratory itself. A failed experiment is not silently rewritten as a passing
result.

The [scenario catalog](scenario-catalog.md) contains every completed behavioral
contract and its reproducible command. The
[hardening record](beta-hardening-lab.md) retains the detailed accepted results,
measurements, commits, and historical failing baselines. The
[V1 product findings](v1-product-findings.md) are the publication source for
operator-facing guarantees and responsibilities.

## Accepted Product Boundaries

| Finding | Evidence | V1 decision |
| --- | --- | --- |
| A durable consumer effect can be invoked again after worker or database loss. | `TE-W05`, `TE-D04`, `TE-D05`, `TE-L07` | At-least-once remains explicit; consumers own effect idempotency. |
| A claim covers the complete sequential batch, not one consumer call. | `TE-W07`, `TE-L05-B` | Size `ClaimTimeout` for the worst-case batch or reduce `BatchSize`; heartbeat renewal is deferred. |
| A later consumer failure retries the complete event. | `TE-W12` | Per-consumer durable checkpoints are outside V1; every consumer must tolerate repetition. |
| Two processes with one explicit worker ID cannot fence each other. | `TE-W13` | Generated IDs remain process-unique; manually configured IDs must be unique. |
| A database commit may survive a lost client acknowledgement. | `TE-T05`, `TE-L07` | Acknowledged commits are durable; ambiguous application outcomes require business idempotency or reconciliation. |
| Event names survive in durable storage. | `TE-C04`, `TE-C05` | Renames require explicit previous-name mappings; TinyEvents does not guess identity. |
| Failed rows are outside processed retention. | `TE-C07`, `TE-C08`, `TE-W11`, `TE-L06-A` | Operators monitor and handle failed rows explicitly in V1. |
| Forward migrations reject inconsistent schema state. | `TE-S03`, `TE-S04` | TinyEvents resumes atomic interruption but does not repair drift or migrate down. |
| Capacity and storage depend on the real provider and workload. | `TE-L01` through `TE-L06` | Published measurements and formulas are planning evidence, not universal guarantees. |

## Design and Correctness Findings Closed Before Beta

| Finding | Evidence after the fix | Resolution |
| --- | --- | --- |
| Namespace-rename compatibility for durable event names was not explicit. | `TE-C04` | Added explicit previous-name mappings without marker interfaces or runtime scanning. |
| Current migration history could silently coexist with a missing outbox table. | `TE-S04` | Both providers now reject the inconsistent schema and name the missing table. |
| Disabled cleanup incorrectly required a custom provider cleanup store at startup. | Cleanup registration tests and `TE-L06` | Startup validation now requires the store only when cleanup is enabled. |
| The package consumer assumed TinyEvents registered only one hosted service. | Package smoke at TinyEvents commit `cf9a8bd` | The sample now proves one processing worker and the independent cleanup worker. Product code was already correct. |

## Laboratory Method Findings

| Finding | What changed |
| --- | --- |
| Repeated full-state observation can perturb the system under test. | Retained-history and backlog-drain runners replaced 100 ms aggregate scans with an indexed outstanding-work probe and one terminal exact read. The monolithic gate retained the resulting lease loss and 49 duplicate effects as failed evidence before the TE-L02 correction. |
| An exact SQL Server observation can itself become deadlock victim 1205, and three immediate attempts are insufficient under sustained disruption. | Dogfood retries only that read-only observation through a bounded ten-attempt backoff window; production locking and worker behavior were not weakened. |
| Four PostgreSQL publisher processes exhausted the container's 100-connection limit. | Mixed traffic now uses one publisher with concurrent traffic definitions and explicit pool budgets. |
| Publisher acknowledgement counts are not durable commit counts during connection loss. | The soak records acknowledged and durable operations separately and reconciles by business identity. |
| Racing published-alpha and candidate cold starts is not a rolling deployment; alpha can correctly reject the newer schema if candidate migrates first. | TE-S05 proves alpha is already processing before candidate applies `002`. Existing alpha continues; an alpha restart after migration must be replaced by candidate. |
| SQL Server saturated locally at the requested 800 writes/s while PostgreSQL did not. | The result remains provider-specific evidence; no universal TinyEvents ceiling is claimed. |
| Process working set, connection peaks, storage bytes, and timing belong to the tested machine. | Artifacts retain the environment and commits; public documentation labels the numbers as measurements rather than guarantees. |

## Positive Guarantees Demonstrated

- business state and its outbox message commit or roll back together;
- active claims are protected until the database-authoritative lease expires;
- workers survive process and database interruption and retry from durable state;
- retries, terminal errors, and retry eligibility survive worker replacement;
- malformed or unknown messages fail independently without blocking valid work;
- concurrent migrations serialize and supported alpha state upgrades in place;
- cleanup deletes only eligible processed rows in bounded atomic batches;
- SQL Server and PostgreSQL expose the same worker recovery contract;
- all six packages restore in isolation and all four package-consumer provider paths run.

These guarantees apply to the exact contracts described by their scenarios.
They do not turn local throughput, timing, or resource measurements into product
capacity promises.
