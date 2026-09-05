# Complete Cloud Bench Campaign

This is executable preparation, not a record of successful AWS tests. The
TinyEvents library is unchanged. Run short local checks before the full campaign;
real AWS acceptance still requires the authorized account.

## Prepared workloads

| Scenario | Question | Execution |
| --- | --- | --- |
| `cloud-smoke` | Can we publish, process and collect evidence? | 100 successful events; shared managed-readiness runner |
| `memory-soak-2h` | Does instrumentation remain usable over hours? | Persistent mixed publisher and four workers |
| `worker-batch-matrix` | Where does useful scaling stop? | Workers 1/2/4/8/12/16/24, batch 50, backlog 100,000; then batches 1/10/25/50/100, four workers, backlog 20,000; three alternating-order repetitions each |
| `monitoring-overhead` | How much does collection change performance? | Three full/minimal pairs, alternating order, four workers/batch 50/backlog 100,000 |
| `mixed-pressure` | Does overload recover? What changes with payloads/cleanup? | Baseline, overload, no-input recovery, steady again; then 0/1,024/16,384 extra ASCII bytes with cleanup off/on |
| `memory-diagnostics-24h` | Is there sustained memory growth to investigate? | Persistent mixed 24h run, cleanup on, one-shot bounded diagnostic trigger |

The legacy `worker-scaling` and `memory-soak-24h` scenarios remain available.
Prefer the new matrix for processing-latency evidence. Batch sweeps use a smaller
backlog so batch 1 fits the bounded drain. Compare the same backlog, worker count,
workload and monitoring profile. Four workers is an initial batch-sweep control,
not a recommendation: edit a candidate scenario and rerun the prepared machinery
near the measured worker knee if needed.

Every variant is explicit in JSON. Unknown fields, duplicate names, invalid
rates/payloads, conflicting cleanup/backlog settings and insufficient duration
budgets fail before database reset. Each variant resets the disposable database;
never use production data. Experiments cannot overlap on the host. Backlog
workers start and emit collector samples before a shared release gate. Timed
drain excludes staggered process/collector startup but includes service activation
after the gate; this is not a guarantee of warm database connections.

Mixed phases preserve publisher and worker PIDs. Publication tasks are bounded
to one second of requested work per window. A saturated publisher can fall behind:
journals retain actual commits/timestamps, not just configured rate. The overload
case requires 500 additional outstanding rows relative to baseline and zero
outstanding rows at the end of no-input recovery. Otherwise the variant fails.

## Execution

Follow [account setup](aws-account-setup.md) and the live safety gates in
[first test day](aws-first-test-day.md). Stage exact clean source commits. Then:

```powershell
.\cloud\aws\Start-Experiment.ps1 -Scenario worker-batch-matrix
.\cloud\aws\Get-ExperimentStatus.ps1
.\cloud\aws\Get-Results.ps1
# Wait for completion and review evidence before the next scenario.
# Repeat with monitoring-overhead and mixed-pressure.
# Use a fresh 30-hour lab for memory-diagnostics-24h after the earlier gates pass.
```

Each scenario executes its variants automatically, sequentially, stopping on the
first failed contract. No test code needs to be written between variants.
Completed variants and failed-workload logs/results are retained. Ordinary
failures restore monitoring in `finally`; forced process/host death cannot
guarantee restoration. After a forced interruption, inspect the status and
restore monitoring before another run; never count it as a completed test.

Do not queue all scenarios simultaneously or assume they fit one 30-hour lease.
Admission uses conservative maximum durations, not forecasts, and rejects work
that cannot fit the remaining TTL. Use sequential disposable labs as necessary,
not extra parallel VMs. Download before teardown. Do not extend an active soak
by reapplying Terraform: user-data changes can replace its VM.

## Evidence and latency semantics

A scheduled bench is under the outer run's `workload/bench/`, with its own
`metadata/`, `workload/<variant>/`, `runtime/<variant>/`, `infrastructure/`,
`logs/<variant>/` and `reports/`. Start with `metadata/bench-status.json` and
`reports/bench-report.md`; use `bench-report.json` for complete metrics. Each
variant retains UTC windows, configuration, durable counts, latency distributions
and collector evidence. Periodic S3 checkpoints preserve this hierarchy.

- Publication-request latency is in the publisher journal. Do not average window
  percentiles and call the result a pooled percentile.
- `business-created-to-first-effect` joins durable business/effect records, one
  first-effect sample per successful operation. It includes time before publish
  commit and excludes post-effect work/ACK.
- `outbox-created-to-processed` uses outbox timestamps. Creation precedes publish
  commit; the processed timestamp precedes status-update commit. This is a
  processing proxy, not exact commit-to-ACK timing. Backlog age and retries count.
- Permanent failures have no successful-processing percentile. They remain in
  durable counts and are never treated as zero-latency successes.

SQL reports p50/p95/p99 and sample counts per run and event kind. Cleanup censors
the processing distribution; coverage is samples divided by expected successful
events. Cleanup-off backlog variants require full coverage. Never present a
cleanup-on distribution as complete. Repeated per-kind percentiles are retained,
not averaged into a fictitious pooled p95. Queries run after measured drain with
a 120-second command timeout, using PostgreSQL's
[ordered-set percentiles](https://www.postgresql.org/docs/16/functions-aggregate.html).

Runtime summaries stream CSV rows with memory proportional to counter names.
Cloud soaks of two hours or longer collect runtime counters every ten seconds;
short bench variants use one second. The effective interval is in each result,
and the bench records the SDK and counter-tool versions in its metadata.
Slopes exclude 15 minutes of warm-up and require at least six subsequent samples
spanning 30 minutes. Neither a slope nor high resident memory is a leak verdict.
Reports do not manufacture worker/batch defaults. Consider repeated throughput,
processing latency, CPU/memory and timestamped lock waits, storage and backlog
together. `waiting_connections` counts active lock waiters, not idle clients.

## Monitoring and diagnostics

Full mode runs six monitoring services, infrastructure sampling, per-PID runtime
collectors and process safety samples. Minimal mode stops those six services and
omits runtime collectors/infrastructure sampling. PostgreSQL, workload journals,
lightweight process samples, expiry and S3 safeguards remain enabled: this is
reduced, not zero, instrumentation. Local tests without `-ManageMonitoringStack`
compare runtime collectors only; the report labels that scope. Whole-variant host
CPU includes reset/startup, drain, post-run queries and collector shutdown.

PostgreSQL is a real PostgreSQL 16 server in a container limited to four CPUs and
8 GiB, with 2 GiB shared buffers, 128 connections and loopback-only port 54323.
Monitoring has separate limits. These are experiment controls, not production
defaults; all components still contend for the same eight-vCPU host.

After a 15-minute warm-up, resident growth of at least 256 MiB and 50% must persist
for five samples at least a minute apart to trigger diagnostics. At most one
capture is attempted across all PIDs, including failed attempts. Collection has
a 65-second wall-clock budget, monitored 1-GiB output threshold, and requires
10 GiB free plus the output budget on the evidence filesystem. Checks run every
250 ms and can overshoot; this is not a filesystem quota. Partial files/errors
are retained. [GC-dump collection](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/dotnet-gcdump)
forces GC and consumes memory. Every attempt is marked and excludes that run
from clean overhead comparisons. Growth can be native memory or caches; inspect
the cause and keep diagnostics private. `MemoryVerdict: Inconclusive` is not a
memory-stability pass.

Grafana uses [file provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
for a versioned dashboard and stable datasource. `Open-LabDashboard.ps1` forwards
localhost:3000 through SSM (requires the Session Manager plugin), with no public
ingress. Sign in as `admin` using the host-local secret at
`/etc/tinyevents-lab/secrets/grafana-admin-password` through your private host
session; never paste it into chat. Panels show infrastructure; runtime GC and
latencies remain in CSV/JSON. Missing scrapes, including deliberate minimal-mode
gaps, are not zero. Raw Prometheus volumes are not in S3 checkpoint exports.

## Local validation

Offline suites: `Test-ExperimentAdmission.ps1`, `Test-BenchContracts.ps1`,
`Test-MonitoringProfiles.ps1`, `Test-BoundedDiagnostics.ps1`,
`Test-StreamingCounters.ps1`, existing lifecycle/layout/recovery/bootstrap suites
and Terraform provider mocks. Use the read-only `--network none` Docker pattern
in the [operator guide](../cloud/aws/README.md).

The real integration requires a built dogfood assembly, disposable PostgreSQL,
PowerShell 7.4, .NET 8 and dotnet-counters 8.0.547301. Inside a Linux SDK container
with `/repo` read-only, `/out` writable and PostgreSQL on an isolated network:

```powershell
& /repo/cloud/aws/tests/Test-CloudBench.ps1 -DogfoodRoot /repo `
    -ArtifactDirectory /out/new-bench-run -ConnectionString $env:SOAK_TEST_CONNECTION `
    -CounterToolPath /tools/dotnet-counters
```

It resets the database between variants. It checks batches 1/10, counter modes,
persistent phase transitions, payloads, cleanup/recovery, exact counts, latency
ordering/coverage, child cleanup and the shared 100-message smoke. Short tests
cannot establish memory stability or sufficient repetitions for recommendations.
`Test-LabDashboard.ps1` checks provisioning against disposable local Grafana,
not exporter coverage. Monitoring control has command-double coverage; real
service/data behavior, SSM forwarding and both expiry paths remain live acceptance.

After preparation passes, the remaining gates are actual AWS acceptance,
full-duration campaign evidence, analysis, regression against the release
revisions and the V1 release decision.
