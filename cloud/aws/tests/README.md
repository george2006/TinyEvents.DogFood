# AWS Runner Contributor Tests

For maintainers changing the lab machinery, not users running experiments.
The only user workflow is [Run TinyEvents Tests on AWS](../README.md).
These checks do not require or validate a real AWS account.

## Offline checks

From the repository root, with Docker and the SDK image already available:

```powershell
$offlineSuites = @(
    'Test-AccountBootstrap.ps1', 'Test-PartialDeploymentRecovery.ps1',
    'Test-EvidenceLayout.ps1', 'Test-ExperimentAdmission.ps1',
    'Test-BenchContracts.ps1', 'Test-MonitoringProfiles.ps1',
    'Test-BoundedDiagnostics.ps1', 'Test-StreamingCounters.ps1'
)
foreach ($suite in $offlineSuites) {
    docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 pwsh -NoProfile -File "/repo/cloud/aws/tests/$suite"
    if ($LASTEXITCODE -ne 0) { throw "Failed: $suite" }
}
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" mcr.microsoft.com/dotnet/sdk:8.0 bash /repo/cloud/aws/tests/Test-EvidenceLifecycle.sh
if ($LASTEXITCODE -ne 0) { throw 'Evidence lifecycle failed' }
```

The source mount is read-only, networking is disabled and credentials are not
passed to containers. Command doubles cover guards, bootstrap/recovery, bounded
uploads/capture, monitoring profiles and failure cleanup. Layout checks also
parse cloud PowerShell scripts. They do not prove real IAM, MFA/browser login,
SSM, systemd, uploads, expiry or Windows ACL behavior. Never bypass a failing
MFA guard to obtain a passing live run.

## Terraform provider mocks

With Linux provider plugins already installed by `terraform init`, Terraform
1.7+ can run the provider-mocked tests (validated with 1.9.8):

```powershell
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" hashicorp/terraform:1.9.8 -chdir=/repo/cloud/aws/terraform validate
if ($LASTEXITCODE -ne 0) { throw 'Terraform validation failed' }
docker run --rm --network none --mount "type=bind,source=$($PWD.Path),target=/repo,readonly" hashicorp/terraform:1.9.8 -chdir=/repo/cloud/aws/terraform test
if ($LASTEXITCODE -ne 0) { throw 'Terraform mock tests failed' }
```

Windows-native provider installations are not interchangeable with Linux
binaries. All four tests use mock providers, not AWS resources. They cover
budget/runtime settings, evidence protection, quota/account guards and the
independent stop schedule. Actual cloud behavior still requires live acceptance.

## Real local workload checks

Build the dogfood Release assembly first. Use PowerShell 7.4, .NET 8,
dotnet-counters 8.0.547301 and a disposable PostgreSQL 16 database whose name
starts with `TinyEventsDogfood`. Tests reset it repeatedly; never use real data.
Inside a Linux SDK container, mount the built repository at `/repo` read-only,
provide writable `/out`, and connect PostgreSQL over an isolated Docker network.
Unlike offline checks, these need that local network. Then run:

```powershell
& /repo/cloud/aws/tests/Test-CloudSoak.ps1 -DogfoodRoot /repo `
    -ArtifactDirectory /out/new-soak-run -ConnectionString $env:SOAK_TEST_CONNECTION `
    -CounterToolPath /tools/dotnet-counters -WorkerCount 8
& /repo/cloud/aws/tests/Test-CloudBench.ps1 -DogfoodRoot /repo `
    -ArtifactDirectory /out/new-bench-run -ConnectionString $env:SOAK_TEST_CONNECTION `
    -CounterToolPath /tools/dotnet-counters
```

Use new evidence directories each time. These check real publishing, persistent
PIDs, backlog/phase execution, latency coverage, negative acceptance and owned
process cleanup. Short runs are not memory stability or worker-limit evidence.
`Test-LabDashboard.ps1` checks provisioning against disposable local Grafana,
not exporter coverage. Inspect its parameters before running it.

The [user guide](../README.md#safety-checks-before-unattended-tests) retains the
live acceptance gates. Unit tests, command doubles and provider mocks do not
close them or establish release readiness.
