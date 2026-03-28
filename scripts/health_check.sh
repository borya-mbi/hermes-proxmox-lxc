#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"
require_cmd pct

start_ctid="${1:-$START_CTID}"
count="${2:-$COUNT}"

printf '%-8s %-12s %-10s %-10s %-10s %-10s\n' "CTID" "User" "Status" "Service" "Memory" "CPUTime"
printf '%s\n' "----------------------------------------------------------------------"

for offset in $(seq 0 $((count - 1))); do
  ctid=$((start_ctid + offset))
  
  if ! pct status "$ctid" >/dev/null 2>&1; then
    printf '%-8s %-12s %-10s %-10s %-10s %-10s\n' "$ctid" "-" "missing" "-" "-" "-"
    continue
  fi

  ct_status="$(pct status "$ctid" | awk '{print $2}')"
  if [ "$ct_status" != "running" ]; then
    printf '%-8s %-12s %-10s %-10s %-10s %-10s\n' "$ctid" "-" "$ct_status" "-" "-" "-"
    continue
  fi

  for user in $(all_hermes_users); do
    service_name="hermes-agent@$user"
    
    # Status
    service_status="$(pct exec "$ctid" -- systemctl is-active "$service_name" 2>/dev/null || echo "failed")"
    
    # Memory
    mem_bytes="$(pct exec "$ctid" -- systemctl show "$service_name" -p MemoryCurrent --value 2>/dev/null || echo "0")"
    if [[ "$mem_bytes" =~ ^[0-9]+$ ]] && [ "$mem_bytes" -gt 0 ]; then
      mem_display="$((mem_bytes / 1024 / 1024))MB"
    else
      mem_display="0MB"
    fi
    
    # CPU: use systemd cgroup accounting for accuracy in multi-user environment
    cpu_ns="$(pct exec "$ctid" -- systemctl show "$service_name" -p CPUUsageNSec --value 2>/dev/null || echo "0")"
    if [[ "$cpu_ns" =~ ^[0-9]+$ ]] && [ "$cpu_ns" -gt 0 ]; then
      cpu_display="$((cpu_ns / 1000000))ms"
    else
      cpu_display="0ms"
    fi

    printf '%-8s %-12s %-10s %-10s %-10s %-10s\n' "$ctid" "$user" "running" "$service_status" "$mem_display" "$cpu_display"
  done
done
