#!/usr/bin/env bash
# Offline command double. Never invokes AWS, systemd, or machine shutdown.
set -euo pipefail
command_name="$(basename "$0")"
printf '%s %s\n' "$command_name" "$*" >> "$TEST_COMMAND_LOG"
case "$command_name" in
  aws)
    case "${MOCK_AWS_MODE:-success}" in
      fail) exit 23 ;;
      hang) sleep 30; exit 24 ;;
    esac
    destination="$TEST_REMOTE/${4#s3://}"
    case "$2" in
      sync)
        mkdir -p "$destination"
        cp -a "$3/." "$destination/"
        ;;
      cp)
        mkdir -p "$(dirname "$destination")"
        cp "$3" "$destination"
        ;;
      *) exit 64 ;;
    esac
    ;;
  systemctl) exit "${MOCK_SYSTEMCTL_EXIT:-0}" ;;
  logger|shutdown) exit 0 ;;
  *) exit 64 ;;
esac
