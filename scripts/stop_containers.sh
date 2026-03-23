#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"
require_cmd pct

start_ctid="${1:-$START_CTID}"
count="${2:-$COUNT}"

for offset in $(seq 0 $((count - 1))); do
  ctid=$((start_ctid + offset))
  if ! pct status "$ctid" 2>/dev/null | grep -q running; then
    log "Already stopped or missing: $ctid"
    continue
  fi
  run_cmd pct shutdown "$ctid"
done
