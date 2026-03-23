#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

start_ctid="${1:-$START_CTID}"
count="${2:-$COUNT}"

require_cmd pct
require_nonempty_file "$APP_ENV_FILE"
require_file "$SYSTEMD_TEMPLATE_FILE"
require_file "$SCRIPT_DIR/bootstrap_hermes.sh"

for offset in $(seq 0 $((count - 1))); do
  ctid=$((start_ctid + offset))

  if ! pct_exists "$ctid"; then
    warn "Skipping missing CTID: $ctid"
    continue
  fi

  if ! pct status "$ctid" 2>/dev/null | grep -q running; then
    run_cmd pct start "$ctid"
  fi

  if is_dry_run; then
    printf '[DRY-RUN] refresh bootstrap files in %s and rerun bootstrap script\n' "$ctid"
    continue
  fi

  pct exec "$ctid" -- install -d -m 700 /root/bootstrap
  pct push "$ctid" "$APP_ENV_FILE" /root/bootstrap/hermes.env
  pct push "$ctid" "$LXC_ENV_FILE" /root/bootstrap/hermes-bootstrap.env
  pct push "$ctid" "$SYSTEMD_TEMPLATE_FILE" /root/bootstrap/hermes-agent.service.tpl
  pct push "$ctid" "$SCRIPT_DIR/bootstrap_hermes.sh" /root/bootstrap_hermes.sh
  pct exec "$ctid" -- chmod 700 /root/bootstrap_hermes.sh
  pct exec "$ctid" -- env \
    HERMES_BOOTSTRAP_ENV=/root/bootstrap/hermes-bootstrap.env \
    HERMES_ENV_SOURCE=/root/bootstrap/hermes.env \
    HERMES_SYSTEMD_TEMPLATE=/root/bootstrap/hermes-agent.service.tpl \
    bash /root/bootstrap_hermes.sh
done

log "Update routine finished."

