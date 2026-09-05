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

## Active V1 Operational Evidence - AWS Laboratory

The [AWS cloud laboratory plan](aws-cloud-lab-plan.md) tracks the delivery
slices for a disposable, single-instance lab. The [operator guide](../cloud/aws/README.md)
describes the implemented commands, evidence layout, and validation boundaries.
This work extends the completed beta evidence; it does not reopen its behavioral
contracts.

Infrastructure scripts, runtime and database sampling, organized evidence
uploads, and a sustained mixed-workload runner are implemented. Short local
Linux/PostgreSQL integration tests passed with 2 and 8 workers and real .NET
runtime collectors. These runs validate the test machinery, not long-term memory
stability or a recommended worker limit. AWS end-to-end validation has not run.

Setup preparation now has two entry points: environment credentials create
only the operator; Terraform creates the laboratory and cost alerts. See the
[two-block quickstart](aws-account-setup.md). Offline tests are preparation
evidence, not AWS acceptance.

Remaining work and acceptance evidence:

- [x] Prepare the two-block setup scripts and short guide with offline tests.
- [x] Prepare the independent AWS expiry schedule, strict scenario/TTL admission,
  runtime deadlines and [first-day gates](aws-first-test-day.md), with offline tests.
- [ ] Validate deployment, SSM access, experiment execution, evidence recovery,
  expiry, and teardown in an explicitly authorized AWS account.
- [ ] Run the two-hour instrumentation check and 24-hour memory/mixed-load soaks;
  investigate retained growth after warm-up before drawing leak conclusions.
- [ ] Execute repeated worker and batch scaling measurements, including database
  pressure, and close the missing settlement-latency decision input.
- [ ] Complete monitoring-overhead measurements, Grafana dashboards and bounded
  automatic leak diagnostics; validate the independent expiry safeguard in AWS.
- [ ] Publish retained results and evidence-backed V1 starting defaults, with
  environment-specific limits and remaining uncertainty stated explicitly.

The detailed plan owns slice scope; this checklist tracks outstanding acceptance
work. Implemented scripts alone do not close a cloud-evidence item.

## Beyond the Beta

Future work must be justified by observable product evidence. Current areas to
investigate are:

- worker-instance fencing or lease renewal for workloads that cannot size
  `ClaimTimeout` safely;
- failed-message retention and operational recovery workflows;
- automated release-gate execution with externally retained artifacts;
- resource-profile extensions beyond the active AWS laboratory scope;
- additional providers only when they can meet the same behavioral contract.

These are not missing beta guarantees. They remain future candidates, separate
from the active V1 operational-evidence work above.
