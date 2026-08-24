# TinyEvents Dogfood Roadmap

This is the public evidence roadmap for TinyEvents. It records demonstrated
behavior and future product questions; it is not an implementation diary.

## Beta Hardening Status

TinyEvents beta hardening is complete as of August 24, 2026.

- 50 named behavioral contracts have executable evidence.
- SQL Server and PostgreSQL pass the same supported behavioral guarantees.
- Transaction, worker, retry, database-recovery, migration, upgrade, load,
  storage, retention, cleanup, and disruption evidence is complete.
- All six supported packages pass compatibility, metadata, isolated restore,
  build, and runtime consumption checks.
- The composed gate passed all 36 mandatory suites and all 543 product tests
  against Dogfood `69bef4c` and TinyEvents `e479a83`.

See the [scenario catalog](scenario-catalog.md) for copyable commands and the
[complete gate result](beta-gate-result-2026-08-24.md) for the tested revisions,
suite matrix, measurements, and accepted limitations.

No behavioral hardening item remains open for the beta. Versioning, release
notes, tagging, and package publication are release operations rather than
additional reliability evidence.

## Demonstrated Evidence

| Area | Contract | Providers |
| --- | --- | --- |
| Identity and compatibility | `TE-C01`–`TE-C08` | SQL Server |
| Transactional publishing | `TE-T01`–`TE-T05` | SQL Server and PostgreSQL |
| Workers, claims, retries, and shutdown | `TE-W01`–`TE-W13` | SQL Server and PostgreSQL |
| Database failure and recovery | `TE-D01`–`TE-D06` | SQL Server and PostgreSQL |
| Schema and deployment | `TE-S01`–`TE-S05` | SQL Server and PostgreSQL |
| Load, storage, cleanup, and disruption | `TE-L01`–`TE-L07` | SQL Server and PostgreSQL |

Some IDs have several executable variants, and some reuse stronger evidence
instead of duplicating a scenario. The catalog makes those relationships
explicit.

## Public Beta Boundaries

The beta deliberately retains these boundaries:

- delivery is at least once, so consumer side effects may repeat;
- explicitly configured worker IDs must be unique;
- `ClaimTimeout` must cover the configured batch's worst-case processing time;
- ambiguous publisher acknowledgement after a database interruption requires
  business idempotency or reconciliation;
- failed rows are preserved in V1 and processed-row cleanup is bounded and
  configurable;
- measured throughput and storage figures describe the tested environment, not
  universal production limits.

The complete guarantees, non-guarantees, and operator responsibilities are in
[V1 product findings](v1-product-findings.md).

## Beyond the Beta

Future work must be justified by observable product evidence. Current areas to
investigate are:

- worker-instance fencing or lease renewal for workloads that cannot size
  `ClaimTimeout` safely;
- failed-message retention and operational recovery workflows;
- automated release-gate execution with externally retained artifacts;
- longer resource profiles for CPU, managed allocations, garbage collection,
  working set, and connection-pool stability;
- additional providers only when they can meet the same behavioral contract.

These are not missing beta guarantees. They are candidates for later versions.
