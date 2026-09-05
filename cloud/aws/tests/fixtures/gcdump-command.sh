#!/usr/bin/env bash
set -euo pipefail
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--output' ]; then output="$2"; shift 2; else shift; fi
done
case "${LAB_GCDUMP_TEST_MODE:-success}" in
  success) printf 'offline test, not a real dump' > "$output" ;;
  hang) sleep 120 ;;
  large) dd if=/dev/zero of="$output" bs=1048576 count=2 status=none ;;
  failure) exit 2 ;;
  *) exit 3 ;;
esac
