#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"
require_cmd pct

usage() {
  cat <<'EOF'
Usage:
  bash scripts/health_check.sh [start_ctid] [count] [--http]

--http adds an internal HTTP probe against 127.0.0.1:HERMES_PUBLIC_PORT.
EOF
}

start_ctid="$START_CTID"
count="$COUNT"
http_check=0
position=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --http)
      http_check=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      case "$position" in
        0) start_ctid="$1" ;;
        1) count="$1" ;;
        *) die "Unexpected argument: $1" ;;
      esac
      position=$((position + 1))
      ;;
  esac
  shift
done

is_positive_integer "$start_ctid" || die "Invalid start CTID: $start_ctid"
is_positive_integer "$count" || die "Invalid CT count: $count"

printf 'CTID\tStatus\tIP\tService'
if [ "$http_check" = "1" ]; then
  printf '\tHTTP'
fi
printf '\n'
for offset in $(seq 0 $((count - 1))); do
  ctid=$((start_ctid + offset))
  raw_status="$(pct status "$ctid" 2>/dev/null || echo "status: missing")"
  case "$raw_status" in
    *running*) status="running" ;;
    *stopped*) status="stopped" ;;
    *) status="missing" ;;
  esac

  ip="-"
  service="-"
  http_status="-"
  if [ "$status" = "running" ]; then
    ip="$(get_container_ip "$ctid")"
    ip="${ip:-"-"}"
    service="$(pct exec "$ctid" -- systemctl is-active "$HERMES_SERVICE_NAME" 2>/dev/null || echo "failed")"
    if [ "$http_check" = "1" ]; then
      http_status="$(pct exec "$ctid" -- bash -lc "code=\$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:${HERMES_PUBLIC_PORT}${HERMES_HTTP_HEALTH_PATH}'); case \"\$code\" in 2*|3*|4*) printf 'http:%s' \"\$code\" ;; *) printf 'fail:%s' \"\$code\" ;; esac" 2>/dev/null || echo "fail:exec")"
    fi
  fi

  printf '%s\t%s\t%s\t%s' "$ctid" "$status" "$ip" "$service"
  if [ "$http_check" = "1" ]; then
    printf '\t%s' "$http_status"
  fi
  printf '\n'
done
