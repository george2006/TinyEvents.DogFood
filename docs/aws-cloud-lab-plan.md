# AWS Cloud Laboratory Plan

## Purpose

The AWS laboratory closes the remaining TinyEvents V1 operational evidence
without turning the dogfood environment into a permanent production platform.
It must answer four questions:

1. Does a worker retain memory during a sustained workload?
2. Where does worker scaling stop producing useful throughput?
3. Which resource becomes the bottleneck: worker CPU, database CPU, connections,
   or storage?
4. Which worker defaults are safe starting points, and which values must remain
   workload-specific?

The first implementation deliberately uses one disposable EC2 instance. Worker
and publisher hosts run as normal .NET processes. PostgreSQL and the
observability services run as resource-bounded containers on the same host.
This topology is inexpensive and reproducible; it does not claim to reproduce
the network or I/O behavior of a managed database.

## Target Topology

```text
AWS account
  VPC and public subnet
    EC2: 8 vCPU / 32 GiB
      systemd
        TinyEvents publisher/load generator
        1-24 independent TinyEvents workers
      Docker
        PostgreSQL
        Prometheus
        Grafana
        postgres-exporter
        node-exporter
        cAdvisor
      EBS gp3 evidence volume
    S3 results bucket
    Systems Manager access
```

The instance has a public address for package and container downloads, but its
security group contains no ingress rules. Operators use AWS Systems Manager
Session Manager instead of SSH. This avoids both an exposed administration port
and the fixed cost of a NAT gateway.

## Reproducibility Contract

Every experiment manifest must record:

- TinyEvents and TinyEvents.Dogfood Git commit IDs;
- dirty/clean source state;
- scenario document SHA-256;
- AWS region, instance type, AMI, EBS configuration, and CPU architecture;
- .NET SDK/runtime, Docker, database, and monitoring versions;
- start and completion timestamps;
- requested and observed workload duration;
- worker, batch, timeout, polling, retry, cleanup, and connection-pool settings;
- terminal durable-state reconciliation;
- paths and hashes for metrics, logs, dumps, and the result document.

Capacity measurements are environment-specific evidence, not product
throughput guarantees.

## Safety and Cost Boundaries

- On-Demand is the default for acceptance and memory-soak runs. Spot is allowed
  only for development runs where interruption is acceptable.
- Every instance receives an absolute `LabExpiresAt` timestamp.
- A host-side timer stops workloads and shuts down the machine at expiry.
- A later account-side automation will stop expired lab instances even if the
  host timer fails.
- The default maximum lifetime is 30 hours.
- No inbound security-group rules are created.
- Evidence is copied to S3 before infrastructure destruction.
- The results bucket is protected from deletion unless destruction is explicitly
  requested.
- Resources are tagged with project, owner, experiment, and expiry.

## Delivery Slices

### Slice 0 - Experiment Contract

Define the topology, reproducibility manifest, safety boundaries, metrics,
acceptance rules, and V1 decision process.

Acceptance:

- this plan is versioned;
- local capacity results are retained as the starting hypothesis;
- cloud results cannot silently become universal product claims.

### Slice 1 - Disposable AWS Foundation

Create Terraform for the VPC, subnet, routing, security group, IAM instance
profile, EC2 instance, encrypted gp3 volume, S3 evidence bucket, and SSM access.
Add PowerShell entry points for deployment, status, Grafana tunneling, result
download, and destruction.

Acceptance:

- `Deploy-Lab.ps1` creates the complete foundation;
- the instance becomes reachable through SSM without inbound ports;
- the selected AMI and instance ID are printed;
- expiry is mandatory and no later than the configured maximum;
- `Destroy-Lab.ps1` removes compute and networking;
- a non-empty evidence bucket blocks accidental deletion unless explicitly
  authorized.

### Slice 2 - Host Bootstrap and Smoke Test

Use cloud-init to install Docker, .NET 8, PowerShell 7, Git, diagnostic tools,
and the AWS CLI. Install systemd units and start the monitoring containers.
Build exact TinyEvents and dogfood revisions in Release configuration, migrate
the database, publish a small event set, drain it with two workers, and reconcile
durable state.

Acceptance:

- bootstrap has an explicit success/failure marker;
- rerunning host initialization is idempotent;
- the smoke test produces a manifest and result in S3;
- no product source modification is required.

### Slice 3 - Process Supervisor and Runtime Metrics

Run publisher and worker instances as independently named systemd services.
The supervisor records PID, worker identity, command line, configuration, exit
status, and log path. It attaches .NET diagnostics by PID and survives planned
worker replacement.

Capture per process:

- CPU time and percentage;
- working set, private bytes, and virtual memory;
- GC heap size, committed heap, allocation rate, and fragmentation;
- Gen0, Gen1, Gen2, LOH, and GC pause/time percentage;
- thread-pool queue, thread count, exception rate, and loaded assemblies.

Acceptance:

- metrics remain attributable to one worker;
- a replacement process creates a new identity/time series;
- diagnostic collection does not change TinyEvents code;
- collection overhead is measured with monitoring enabled and disabled.

### Slice 4 - Host, Container, and Database Metrics

Prometheus scrapes host, container, PostgreSQL, process, and TinyEvents durable
state collectors. Grafana provides a fixed dashboard. Raw samples remain
available for offline analysis even if the dashboard is unavailable.

Capture:

- host CPU by core, memory, swap, load, context switches, disk latency/IOPS,
  filesystem use, and network;
- container CPU, working set, limits, throttling, disk, and restarts;
- PostgreSQL sessions, transaction rate, cache reads, physical reads, locks,
  waits, checkpoints, database/table/index size, and connection limits;
- pending, processing, processed, and failed messages, oldest pending age,
  claims, effects, duplicate effects, and cleanup progress.

Acceptance:

- resource pressure can be assigned to worker, publisher, database, or monitor;
- monitoring storage is bounded;
- dashboard access requires an SSM tunnel and is never public.

### Slice 5 - Declarative Scenario Runner

Add versioned declarative scenario documents and a runner that performs reset,
warm-up, publication, worker orchestration, measurement, cooldown, durable
reconciliation, and evidence upload.

Initial scenarios:

- `cloud-smoke-2h`;
- `worker-scaling`;
- `batch-scaling`;
- `memory-soak-24h`;
- `mixed-load-24h`.

Acceptance:

- a scenario continues after the initiating SSM session closes;
- status can be queried independently;
- only one destructive database scenario can run at a time;
- failure preserves partial evidence and still triggers shutdown.

### Slice 6 - Worker Scaling

Start with a 100,000-message backlog, `BatchSize = 50`, worker counts
`1, 2, 4, 8, 12, 16, 24`, and three repetitions. Use the first pass to identify
the useful range, then measure batch sizes `10, 25, 50, 100` only in that range.

Report:

- messages per second, speedup, and scaling efficiency;
- p50/p95/p99 settlement latency;
- worker CPU and memory distribution;
- database CPU, connections, locks, and disk pressure;
- the first resource to saturate;
- the final worker count that adds at least 15% throughput without increasing
  p95 by more than 20% or exhausting a bounded resource.

The existing local evidence is the hypothesis, not the conclusion:

| Workers | SQL Server msg/s | PostgreSQL msg/s |
| ---: | ---: | ---: |
| 1 | 157.72 | 255.48 |
| 2 | 291.38 | 442.06 |
| 4 | 514.93 | 761.08 |
| 8 | 748.98 | 1,020.84 |

Eight workers still improve throughput locally, but efficiency falls to about
59% for SQL Server and 50% for PostgreSQL. Cloud evidence must locate the knee
rather than treating eight as a fixed limit.

### Slice 7 - Slow Memory-Leak Soak

Validate instrumentation with a two-hour run, then execute a continuous
24-hour workload without restarting the measured workers. Extend to 72 hours
only when the 24-hour post-warm-up slope is suspicious but inconclusive.

Phases:

1. warm-up;
2. stable load;
3. burst;
4. stable load;
5. controlled backlog and live recovery;
6. mixed success/transient/permanent/slow work;
7. high pressure;
8. cooldown and durable reconciliation.

A larger final working set alone is not a leak. Analysis uses the post-warm-up
slope of live heap after Gen2 collections, LOH, minimum private bytes per time
window, minimum working set, threads, handles, connections, and backlog. A
suspicious threshold triggers bounded gcdump and trace capture.

Acceptance:

- no OOM or unexpected process death;
- stable terminal backlog and exact durable accounting;
- post-GC live memory is stable or any retained growth is explained;
- dumps cannot exhaust the evidence volume;
- monitoring gaps are reported rather than interpreted as zero.

### Slice 8 - Database Pressure and Mixed Load

Run 80% successful, 10% transient, 5% permanent, and 5% slow work with bounded
connection pools. Compare sustainable, overloaded, backlog-recovery, and cleanup
enabled/disabled phases. Add representative 0, 1 KB, and 16 KB payloads after
the base capacity boundary is known.

Acceptance:

- database connection, CPU, lock, or storage saturation is distinguishable from
  worker saturation;
- unrelated successful work progresses during retries and slow consumption;
- terminal durable counts and expected at-least-once duplicates reconcile.

### Slice 9 - V1 Defaults Decision

Publish evidence-backed starting defaults and formulas. Keep environment-specific
values explicitly separate from guarantees. At minimum document:

- worker-count starting point and scaling signals;
- `BatchSize` tradeoff;
- `ClaimTimeout` greater than worst-case complete-batch duration plus margin;
- polling latency/load tradeoff;
- connection-pool planning across processes;
- retry and failure monitoring;
- accepted processed-retention and cleanup defaults;
- required production remeasurement.

## Execution Interface

The intended operator flow is:

```powershell
.\cloud\aws\Deploy-Lab.ps1 -Region eu-west-1
.\cloud\aws\Get-LabStatus.ps1
.\cloud\aws\Start-Experiment.ps1 -Scenario worker-scaling
.\cloud\aws\Get-Results.ps1 -OutputDirectory .\artifacts\cloud
.\cloud\aws\Destroy-Lab.ps1
```

The AWS profile and candidate Git revisions are explicit inputs. Long-running
experiments are host services, not children of the local terminal or SSM
session.

## Initial Cost Envelope

Cost is reported from the actual Terraform plan and AWS bill rather than frozen
as a product promise. The working envelope is one general-purpose 8-vCPU,
32-GiB On-Demand instance, 150 GB gp3, low-cardinality metrics, bounded logs,
and 24-30 hours of runtime. The laboratory is destroyed after evidence upload;
it is not intended to run continuously.

## Current Implementation Status

- Slice 0: documented.
- Slice 1: foundation scripts and Terraform implemented and locally validated;
  an AWS deployment is still required for acceptance.
- Slice 2: host prerequisites and exact clean-commit source staging implemented;
  PostgreSQL, the first bounded monitoring stack, remote build, and smoke runner
  are implemented but still require their first AWS execution for acceptance.
- Slice 5: the first JSON scenario schema, asynchronous systemd/SSM control,
  exclusive experiment lock, status reporting, and partial-evidence upload are
  implemented but still require their first AWS execution for acceptance.
- Slice 3: direct PID resource sampling, .NET `System.Runtime` counter capture,
  and bounded explicit GC-dump capture are implemented in the smoke path; the
  worker-scaling path now attaches and closes one counter collector per worker.
  Runtime summaries and guarded memory slopes are implemented. Continuous OS
  sampling is connected at the experiment boundary; the automated leak trigger
  remains open.
- Slice 4: a ten-second JSONL series correlates host memory/load, PostgreSQL
  container resources, database activity, outbox pressure, and storage. Its
  summary reports ranges, deltas, cache-hit ratio, coverage, guarded host-memory
  slope, and pressure signals. Grafana dashboards remain open.
- Slice 6: TE-L02 now records exact variant windows. A provisional report joins
  repeated throughput, runtime instrumentation, and windowed infrastructure
  pressure, applies the 15% useful-step rule, and distinguishes a measured knee
  from an unbounded largest tested value. The cloud matrix still needs execution.
- Slices 7-9: planned or partially scaffolded, not yet executable evidence.
