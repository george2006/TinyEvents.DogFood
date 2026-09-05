#!/usr/bin/env bash
# Run only in a disposable Linux container; all external commands are doubled.
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
test_root="$(mktemp -d -t tinyevents-evidence-test.XXXXXXXX)"
export LAB_ROOT="$test_root/lab with spaces"
export LAB_ENVIRONMENT_FILE="$test_root/environment"
export LAB_EVIDENCE_UPLOADER="$test_directory/../host/sync-lab-evidence.sh"
export TEST_COMMAND_LOG="$test_root/commands.log" TEST_REMOTE="$test_root/remote"
mkdir -p "$test_root/bin" "$LAB_ROOT/artifacts/soak-20260905/runtime/soak" \
  "$LAB_ROOT/artifacts/soak-20260905/metadata" \
  "$LAB_ROOT/sources/TinyEvents.Dogfood/artifacts/load/scaling-1"
cp "$test_directory/fixtures/evidence-command.sh" "$test_root/evidence-command"
chmod +x "$test_root/evidence-command"
for name in aws systemctl shutdown logger; do
  ln -s "$test_root/evidence-command" "$test_root/bin/$name"
done
export PATH="$test_root/bin:$PATH"
printf 'LAB_RESULTS_BUCKET=test-evidence-bucket\nLAB_EXPIRES_AT=2000-01-01T00:00:00Z\n' > "$LAB_ENVIRONMENT_FILE"
printf 'sample\n' > "$LAB_ROOT/artifacts/soak-20260905/runtime/soak/worker-1.runtime.csv"
printf 'live worker\n' > "$LAB_ROOT/sources/TinyEvents.Dogfood/artifacts/load/scaling-1/worker.log"
printf '{"State":"Running"}\n' > "$LAB_ROOT/experiment-status.json"
cp "$LAB_ROOT/experiment-status.json" "$LAB_ROOT/artifacts/soak-20260905/metadata/status.json"
printf '{"Repositories":[]}\n' > "$LAB_ROOT/source-manifest.json"
remote="$TEST_REMOTE/test-evidence-bucket"

fail() { echo "FAIL: $*" >&2; exit 1; }
reset_log() { : > "$TEST_COMMAND_LOG"; }
expect_failure() {
  local expected="$1"; shift
  local actual=0
  "$@" || actual=$?
  [ "$actual" -eq "$expected" ] || fail "Expected exit $expected; got $actual"
}

reset_log
bash "$LAB_EVIDENCE_UPLOADER" checkpoint
cmp "$LAB_ROOT/artifacts/soak-20260905/runtime/soak/worker-1.runtime.csv" \
  "$remote/runs/soak-20260905/runtime/soak/worker-1.runtime.csv"
test -f "$remote/runs/soak-20260905/metadata/status.json"
test -f "$remote/live/worker-scaling/scaling-1/worker.log"
test -f "$remote/host/source-manifest.json"
grep -q 'checkpoints/latest.json' <(tail -n 1 "$TEST_COMMAND_LOG")
grep -q '"ExperimentComplete":false' "$remote/checkpoints/latest.json"
grep -q -- '--no-follow-symlinks' "$TEST_COMMAND_LOG"
if grep -q -- '--delete' "$TEST_COMMAND_LOG"; then fail 'Remote evidence must not be deleted'; fi
echo 'PASS: periodic checkpoint, live scaling, host metadata, partial receipt last'

reset_log
bash "$LAB_EVIDENCE_UPLOADER" run soak-20260905
[ "$(wc -l < "$TEST_COMMAND_LOG")" -eq 1 ] || fail 'Run finalization should only upload that run'
grep -q 'runs/soak-20260905/' "$TEST_COMMAND_LOG"
expect_failure 64 bash "$LAB_EVIDENCE_UPLOADER" run ../outside
echo 'PASS: scoped run upload and traversal rejection'

reset_log
cp "$remote/checkpoints/latest.json" "$test_root/previous-receipt.json"
export MOCK_AWS_MODE=fail
expect_failure 23 bash "$LAB_EVIDENCE_UPLOADER" checkpoint
cmp "$remote/checkpoints/latest.json" "$test_root/previous-receipt.json"
if grep -q 'checkpoints/latest.json' "$TEST_COMMAND_LOG"; then fail 'Failed transfer published a receipt'; fi
echo 'PASS: failed transfer propagates its exit code and keeps last good receipt'

reset_log
export MOCK_AWS_MODE=hang LAB_UPLOAD_TIMEOUT_SECONDS=1
started=$SECONDS
expect_failure 124 bash "$LAB_EVIDENCE_UPLOADER" checkpoint
[ "$((SECONDS - started))" -lt 8 ] || fail 'Upload timeout was not bounded'
echo 'PASS: hanging upload is terminated within budget'

reset_log
export MOCK_AWS_MODE=success
exec 9> "$LAB_ROOT/evidence-upload.lock"
flock -x 9
expect_failure 124 bash "$LAB_EVIDENCE_UPLOADER" checkpoint 9>&-
flock -u 9
exec 9>&-
test ! -s "$TEST_COMMAND_LOG" || fail 'Concurrent uploader reached AWS'
unset LAB_UPLOAD_TIMEOUT_SECONDS
echo 'PASS: shared lock excludes concurrent transfers and lock wait is bounded'

reset_log
printf 'LAB_RESULTS_BUCKET=test-evidence-bucket\nLAB_EXPIRES_AT=2999-01-01T00:00:00Z\n' > "$LAB_ENVIRONMENT_FILE"
bash "$test_directory/../host/expire-lab.sh"
test ! -s "$TEST_COMMAND_LOG" || fail 'Unexpired lab should not stop or upload'
test ! -e "$LAB_ROOT/expiry-started"
echo 'PASS: no action before expiry'

printf 'LAB_RESULTS_BUCKET=test-evidence-bucket\nLAB_EXPIRES_AT=2000-01-01T00:00:00Z\n' > "$LAB_ENVIRONMENT_FILE"
for mode in success fail hang; do
  reset_log
  export MOCK_AWS_MODE="$mode" LAB_UPLOAD_TIMEOUT_SECONDS=1
  # Even a failed systemctl command must not prevent upload and shutdown.
  export MOCK_SYSTEMCTL_EXIT=5
  bash "$test_directory/../host/expire-lab.sh"
  test -f "$LAB_ROOT/expiry-started"
  grep -q '"State":"Expired"' "$LAB_ROOT/expiry.json"
  grep -q 'systemctl stop tinyevents-experiment.service' "$TEST_COMMAND_LOG"
  [ "$(tail -n 1 "$TEST_COMMAND_LOG")" = 'shutdown -h now' ] || fail 'TTL did not shut down last'
  [ "$(grep -c '^shutdown ' "$TEST_COMMAND_LOG")" -eq 1 ] || fail 'Expected one shutdown'
  if [ "$mode" = success ]; then
    test -f "$remote/host/expiry.json"
    grep -q 'Final partial evidence upload completed' "$TEST_COMMAND_LOG"
  else
    grep -q 'Final evidence upload failed' "$TEST_COMMAND_LOG"
  fi
  echo "PASS: TTL stops workload, attempts upload ($mode), and shuts down"
done

# An invalid local destination simulates inability to write the expiry marker.
reset_log
export LAB_ROOT="$test_root/not-a-directory"
printf 'full/unwritable stand-in\n' > "$LAB_ROOT"
expect_failure 1 bash "$test_directory/../host/expire-lab.sh"
[ "$(tail -n 1 "$TEST_COMMAND_LOG")" = 'shutdown -h now' ] || fail 'Local write failure bypassed TTL'
echo 'PASS: local write failure cannot bypass shutdown'
echo 'PASS: all evidence lifecycle tests (offline; no real AWS or shutdown)'
