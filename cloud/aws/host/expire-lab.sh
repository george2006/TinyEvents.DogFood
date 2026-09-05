#!/usr/bin/env bash
set -euo pipefail

lab_root="${LAB_ROOT:-/opt/tinyevents-lab}"
source "${LAB_ENVIRONMENT_FILE:-/etc/tinyevents-lab/environment}"
now_epoch="$(date -u +%s)"
expiry_epoch="$(date -u -d "$LAB_EXPIRES_AT" +%s)"
if [ "$now_epoch" -lt "$expiry_epoch" ]; then
  exit 0
fi

# Even a full disk or another preparation failure must not bypass the TTL.
trap 'shutdown -h now' EXIT

# Prevent another experiment from starting during the final upload.
touch "$lab_root/expiry-started"
logger -t tinyevents-lab "Laboratory expired; stopping workload and saving partial evidence."
printf '{"State":"Expired","Reason":"TTL","AtUtc":"%s","ExperimentComplete":false}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lab_root/expiry.json"

# Each stop is bounded independently. The experiment unit also has its own
# TimeoutStopSec. SIGTERM/forced stop may lose buffered metrics; no success claim.
timeout --kill-after=5s 15s systemctl stop tinyevents-lab-checkpoint.timer || true
timeout --kill-after=5s 15s systemctl stop tinyevents-lab-checkpoint.service || true
timeout --kill-after=5s 60s systemctl stop tinyevents-experiment.service || true

uploader="${LAB_EVIDENCE_UPLOADER:-/usr/local/sbin/tinyevents-lab-sync-evidence}"
if bash "$uploader" checkpoint; then
  logger -t tinyevents-lab "Final partial evidence upload completed; shutting down."
else
  upload_exit=$?
  logger -t tinyevents-lab "Final evidence upload failed (exit $upload_exit); shutting down to enforce cost limit."
fi
