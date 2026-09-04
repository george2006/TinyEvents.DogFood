#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: sample-experiment.sh <output-jsonl> <stop-file> <interval-seconds>" >&2
  exit 2
fi

output_path="$1"
stop_file="$2"
interval_seconds="$3"

if ! [[ "$interval_seconds" =~ ^[0-9]+$ ]] || [ "$interval_seconds" -lt 1 ] || [ "$interval_seconds" -gt 60 ]; then
  echo "interval must be an integer from 1 to 60 seconds" >&2
  exit 2
fi

mkdir -p "$(dirname "$output_path")"
rm -f "$stop_file"

while [ ! -e "$stop_file" ]; do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  load_json="$(awk '{printf "{\"oneMinute\":%s,\"fiveMinutes\":%s,\"fifteenMinutes\":%s}", $1, $2, $3}' /proc/loadavg)"
  memory_json="$(awk '
    /^MemTotal:/ { total=$2*1024 }
    /^MemAvailable:/ { available=$2*1024 }
    /^SwapTotal:/ { swapTotal=$2*1024 }
    /^SwapFree:/ { swapFree=$2*1024 }
    END { printf "{\"totalBytes\":%.0f,\"availableBytes\":%.0f,\"usedBytes\":%.0f,\"swapUsedBytes\":%.0f}", total, available, total-available, swapTotal-swapFree }
  ' /proc/meminfo)"

  container_json="null"
  container_error="null"
  container_raw="$(docker stats --no-stream --format '{{json .}}' tinyevents-postgresql 2>&1)"
  container_exit=$?
  if [ "$container_exit" -eq 0 ] && [ -n "$container_raw" ]; then
    container_json="$(printf '%s' "$container_raw" | jq -c '.')"
  else
    container_error="$(printf '%s' "$container_raw" | jq -Rs '.')"
  fi

  database_json="null"
  database_error="null"
  database_raw="$(docker exec tinyevents-postgresql psql \
    -U postgres \
    -d TinyEventsDogfoodOperations \
    -tAc '
      WITH outbox AS (
        SELECT
          COUNT(*)::bigint AS total,
          COUNT(*) FILTER (WHERE "Status" = 0)::bigint AS pending,
          COUNT(*) FILTER (WHERE "Status" = 1)::bigint AS processing,
          COUNT(*) FILTER (WHERE "Status" = 2)::bigint AS processed,
          COUNT(*) FILTER (WHERE "Status" = 3)::bigint AS failed,
          COALESCE(EXTRACT(EPOCH FROM (
            CURRENT_TIMESTAMP - MIN("CreatedAtUtc") FILTER (WHERE "Status" = 0)
          )), 0)::double precision AS oldest_pending_seconds
        FROM "TinyOutbox"
      ), activity AS (
        SELECT
          COUNT(*) FILTER (WHERE datname = current_database())::bigint AS connections,
          COUNT(*) FILTER (WHERE datname = current_database() AND state = '\''active'\'')::bigint AS active_connections,
          COUNT(*) FILTER (WHERE datname = current_database() AND wait_event IS NOT NULL)::bigint AS waiting_connections
        FROM pg_stat_activity
      ), database_stats AS (
        SELECT
          xact_commit::bigint,
          xact_rollback::bigint,
          blks_read::bigint,
          blks_hit::bigint,
          temp_bytes::bigint,
          deadlocks::bigint
        FROM pg_stat_database
        WHERE datname = current_database()
      )
      SELECT json_build_object(
        '\''databaseUtcNow'\'', CURRENT_TIMESTAMP,
        '\''outbox'\'', row_to_json(outbox),
        '\''activity'\'', row_to_json(activity),
        '\''database'\'', row_to_json(database_stats),
        '\''outboxTableBytes'\'', pg_table_size('\''"TinyOutbox"'\''),
        '\''outboxIndexBytes'\'', pg_indexes_size('\''"TinyOutbox"'\''),
        '\''outboxTotalBytes'\'', pg_total_relation_size('\''"TinyOutbox"'\'')
      )
      FROM outbox, activity, database_stats;
    ' 2>&1)"
  database_exit=$?
  if [ "$database_exit" -eq 0 ] && [ -n "$database_raw" ]; then
    database_json="$(printf '%s' "$database_raw" | jq -c '.')"
  else
    database_error="$(printf '%s' "$database_raw" | jq -Rs '.')"
  fi

  jq -cn \
    --arg timestampUtc "$timestamp" \
    --argjson load "$load_json" \
    --argjson memory "$memory_json" \
    --argjson postgresContainer "$container_json" \
    --argjson postgresContainerError "$container_error" \
    --argjson postgresql "$database_json" \
    --argjson postgresqlError "$database_error" \
    '{
      timestampUtc: $timestampUtc,
      host: { load: $load, memory: $memory },
      postgresContainer: $postgresContainer,
      postgresContainerError: $postgresContainerError,
      postgresql: $postgresql,
      postgresqlError: $postgresqlError
    }' >> "$output_path"

  sleep "$interval_seconds" &
  wait $! || true
done
