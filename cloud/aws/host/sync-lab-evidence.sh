#!/usr/bin/env bash
# Shared by the periodic timer, experiment finalization, and TTL shutdown.
set -euo pipefail

lab_root="${LAB_ROOT:-/opt/tinyevents-lab}"
artifact_root="${LAB_ARTIFACT_ROOT:-$lab_root/artifacts}"
environment_file="${LAB_ENVIRONMENT_FILE:-/etc/tinyevents-lab/environment}"
source "$environment_file"
: "${LAB_RESULTS_BUCKET:?Missing results bucket}"
mode="${1:-checkpoint}"

# The outer timeout bounds lock contention, retries, and every AWS operation.
if [ "$mode" != "--locked" ]; then
  budget="${LAB_UPLOAD_TIMEOUT_SECONDS:-180}"
  [[ "$budget" =~ ^[1-9][0-9]*$ ]] && [ "$budget" -le 180 ] || exit 64
  exec timeout --signal=TERM --kill-after=5s "${budget}s" \
    flock -w 10 "$lab_root/evidence-upload.lock" \
    bash "$0" --locked "$@"
fi
shift
mode="${1:-checkpoint}"
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=2 AWS_PAGER=""
aws_options=(--only-show-errors --cli-connect-timeout 10 --cli-read-timeout 30)

case "$mode" in
  run)
    run_id="${2:?Missing run id}"
    [[ "$run_id" =~ ^[a-z0-9][a-z0-9-]{1,100}$ ]] || exit 64
    test -d "$artifact_root/$run_id"
    aws s3 sync "$artifact_root/$run_id/" \
      "s3://$LAB_RESULTS_BUCKET/runs/$run_id/" \
      --no-follow-symlinks --exclude '*.tmp' --exclude 'stop-sampler' "${aws_options[@]}"
    ;;
  checkpoint)
    if [ -d "$artifact_root" ]; then
      aws s3 sync "$artifact_root/" "s3://$LAB_RESULTS_BUCKET/runs/" \
        --no-follow-symlinks --exclude '*.tmp' --exclude 'stop-sampler' "${aws_options[@]}"
    fi
    # The legacy scaling runner stages its evidence outside ArtifactRoot until
    # a repetition ends. Preserve its live files as recovery evidence too.
    scaling_root="$lab_root/sources/TinyEvents.Dogfood/artifacts/load"
    if [ -d "$scaling_root" ]; then
      aws s3 sync "$scaling_root/" "s3://$LAB_RESULTS_BUCKET/live/worker-scaling/" \
        --no-follow-symlinks --exclude '*.tmp' "${aws_options[@]}"
    fi
    for name in experiment-status.json source-manifest.json expiry.json; do
      if [ -f "$lab_root/$name" ]; then
        aws s3 cp "$lab_root/$name" "s3://$LAB_RESULTS_BUCKET/host/$name" "${aws_options[@]}"
      fi
    done
    # Uploaded last, only when ALL preceding transfers succeeded. This receipt
    # is not a consistent snapshot or a successful experiment verdict.
    printf '{"UploadedAtUtc":"%s","Kind":"Checkpoint","ExperimentComplete":false}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lab_root/evidence-checkpoint.json"
    aws s3 cp "$lab_root/evidence-checkpoint.json" \
      "s3://$LAB_RESULTS_BUCKET/checkpoints/latest.json" "${aws_options[@]}"
    ;;
  *) echo "Unknown evidence upload mode: $mode" >&2; exit 64 ;;
esac
