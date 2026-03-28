#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

start_ctid="${1:-$START_CTID}"
count="${2:-$COUNT}"

require_cmd pct
require_nonempty_file "$USER_ENV_FILE"
require_config_yaml
require_file "$SYSTEMD_SERVICE_FILE"
require_file "$SCRIPT_DIR/bootstrap_hermes.sh"

for offset in $(seq 0 $((count - 1))); do
  ctid=$((start_ctid + offset))

  if ! pct_exists "$ctid"; then
    warn "Skipping missing CTID: $ctid"
    continue
  fi

  if ! pct status "$ctid" 2>/dev/null | grep -q running; then
    log "Starting container $ctid..."
    pct start "$ctid"
  fi

  log "Updating container $ctid..."
  if is_dry_run; then
    printf '[DRY-RUN] refresh bootstrap files in %s and rerun bootstrap script\n' "$ctid"
    continue
  fi

  pct exec "$ctid" -- install -d -m 700 /root/bootstrap
  pct push "$ctid" "$LXC_ENV_FILE" /root/bootstrap/hermes-bootstrap.env
  pct push "$ctid" "$USER_ENV_FILE" /root/bootstrap/hermes-user.env
  pct push "$ctid" "$CONFIG_YAML_FILE" /root/bootstrap/config.yaml
  pct push "$ctid" "$SYSTEMD_SERVICE_FILE" /root/bootstrap/hms@.service
  pct push "$ctid" "$SCRIPT_DIR/bootstrap_hermes.sh" /root/bootstrap_hermes.sh
  
  if file_has_noncomment_lines "${AUTHORIZED_KEYS_FILE:-}"; then
    pct push "$ctid" "$AUTHORIZED_KEYS_FILE" /root/bootstrap/authorized_keys
  else
    pct exec "$ctid" -- rm -f /root/bootstrap/authorized_keys
  fi
  
  pct exec "$ctid" -- chmod 700 /root/bootstrap_hermes.sh
  
  if ! pct exec "$ctid" -- bash /root/bootstrap_hermes.sh; then
    warn "Failed to update $ctid"
    continue
  fi
  
  # For each user, perform sync_configs just in case
  for user in $(all_hermes_users); do
    log "Performing config sync for $user in $ctid..."
    # Call the script properly with error handling
    if ! bash "$SCRIPT_DIR/sync_configs.sh" "$ctid" "$user"; then
      warn "Failed to sync configs for $user in $ctid. Skipping."
      continue
    fi
  done
done

log "Update routine finished."
