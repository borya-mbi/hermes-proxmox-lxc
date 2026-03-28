#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${1:-}"
require_cmd pct

if pct status "$TEMPLATE_CTID" >/dev/null 2>&1; then
  if pct config "$TEMPLATE_CTID" 2>/dev/null | grep -q '^template: 1'; then
    log "CTID $TEMPLATE_CTID is already a Proxmox template."
    exit 0
  fi
  warn "Prototype CTID $TEMPLATE_CTID already exists. Reusing it."
else
  run_cmd pct create "$TEMPLATE_CTID" "$TEMPLATE_IMAGE" \
    --hostname "${NAME_PREFIX}-golden" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --cores "$CT_CORES" \
    --unprivileged "$CT_UNPRIVILEGED" \
    --rootfs "${STORAGE}:${CT_ROOTFS_SIZE}" \
    --net0 "$(build_net0_opts "$TEMPLATE_CTID")"
fi

run_cmd pct start "$TEMPLATE_CTID"

if ! is_dry_run; then
  log "Waiting for container $TEMPLATE_CTID network to initialize..."
  wait_for_ip "$TEMPLATE_CTID" 30 >/dev/null || warn "Could not detect IP, proceeding anyway..."
  sleep 2 # Give it a bit more time for routes to settle
fi


run_cmd pct exec "$TEMPLATE_CTID" -- bash -lc \
  "ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 || { echo '[ERROR] No outbound connectivity. Check vmbr1 NAT on host.' >&2; exit 1; }"

run_cmd pct exec "$TEMPLATE_CTID" -- bash -lc \
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ${HERMES_APT_PACKAGES} systemd"

if [ -n "${TIMEZONE:-}" ]; then
  run_cmd pct exec "$TEMPLATE_CTID" -- bash -lc "ln -fs /usr/share/zoneinfo/$TIMEZONE /etc/localtime && echo $TIMEZONE > /etc/timezone"
fi

run_cmd pct exec "$TEMPLATE_CTID" -- bash -lc \
  "truncate -s 0 /etc/machine-id && rm -f /var/lib/dbus/machine-id && apt-get clean"

run_cmd pct stop "$TEMPLATE_CTID"
run_cmd pct template "$TEMPLATE_CTID"

log "Golden template is ready: $TEMPLATE_CTID"

