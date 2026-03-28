#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

deploy_count="${1:-$COUNT}"
start_ctid="${2:-$START_CTID}"

require_cmd pct
require_nonempty_file "$USER_ENV_FILE"
require_config_yaml
require_file "$SYSTEMD_SERVICE_FILE"
require_file "$SCRIPT_DIR/bootstrap_hermes.sh"

init_report_files

log "Running preflight check..."
bash "$SCRIPT_DIR/preflight_check.sh" || die "Preflight check failed. Aborting deployment."

for offset in $(seq 0 $((deploy_count - 1))); do
  ctid=$((start_ctid + offset))
  hostname="${NAME_PREFIX}-${ctid}"
  net0_opts="$(build_net0_opts "$ctid")"
  ip="-"
  status="success"

  if is_dry_run; then
    printf '[DRY-RUN] pct clone %s %s --hostname %s\n' "$TEMPLATE_CTID" "$ctid" "$hostname"
    printf '[DRY-RUN] pct set %s --memory %s --swap %s --cores %s --onboot %s --net0 %s\n' \
      "$ctid" "$CT_MEMORY" "$CT_SWAP" "$CT_CORES" "$CT_ONBOOT" "$net0_opts"
    printf '[DRY-RUN] pct start %s\n' "$ctid"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/hermes-bootstrap.env\n' "$ctid" "$LXC_ENV_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/hermes-user.env\n' "$ctid" "$USER_ENV_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/config.yaml\n' "$ctid" "$CONFIG_YAML_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/hms@.service\n' "$ctid" "$SYSTEMD_SERVICE_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap_hermes.sh\n' "$ctid" "$SCRIPT_DIR/bootstrap_hermes.sh"
    if file_has_noncomment_lines "${AUTHORIZED_KEYS_FILE:-}"; then
      printf '[DRY-RUN] pct push %s %s /root/bootstrap/authorized_keys\n' "$ctid" "$AUTHORIZED_KEYS_FILE"
    fi
    printf '[DRY-RUN] pct exec %s -- bash /root/bootstrap_hermes.sh\n' "$ctid"
    continue
  fi

  if pct_exists "$ctid"; then
    warn "CTID already exists, skipping: $ctid"
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "multi-user" "failed_ctid_in_use"
    continue
  fi

  log "Cloning template $TEMPLATE_CTID to $ctid ($hostname)..."
  if ! pct clone "$TEMPLATE_CTID" "$ctid" --hostname "$hostname"; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "multi-user" "failed_clone"
    continue
  fi

  log "Setting resources for $ctid..."
  if ! pct set "$ctid" --memory "$CT_MEMORY" --swap "$CT_SWAP" --cores "$CT_CORES" --onboot "$CT_ONBOOT" --net0 "$net0_opts"; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "multi-user" "failed_set"
    continue
  fi

  log "Starting container $ctid..."
  if ! pct start "$ctid"; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "multi-user" "failed_start"
    continue
  fi

  ip="$(wait_for_ip "$ctid" "$CT_DHCP_TIMEOUT" || true)"
  ip="${ip:-"-"}"

  log "Preparing bootstrap directory in $ctid..."
  if ! pct exec "$ctid" -- install -d -m 700 /root/bootstrap; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "multi-user" "failed_prepare_dir"
    continue
  fi

  log "Pushing configuration files to $ctid..."
  push_failed=false
  for push_pair in \
    "$LXC_ENV_FILE:/root/bootstrap/hermes-bootstrap.env" \
    "$USER_ENV_FILE:/root/bootstrap/hermes-user.env" \
    "$CONFIG_YAML_FILE:/root/bootstrap/config.yaml" \
    "$SYSTEMD_SERVICE_FILE:/root/bootstrap/hms@.service" \
    "$SCRIPT_DIR/bootstrap_hermes.sh:/root/bootstrap_hermes.sh"; do
    local_file="${push_pair%%:*}"
    remote_file="${push_pair##*:}"
    if ! pct push "$ctid" "$local_file" "$remote_file"; then
      warn "Failed to push $local_file to $ctid:$remote_file"
      push_failed=true
    fi
  done
  if [ "$push_failed" = "true" ]; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "multi-user" "failed_push"
    continue
  fi

  if file_has_noncomment_lines "${AUTHORIZED_KEYS_FILE:-}" && ! pct push "$ctid" "$AUTHORIZED_KEYS_FILE" /root/bootstrap/authorized_keys; then
    warn "Failed to push authorized_keys to $ctid"
  fi

  log "Executing bootstrap script in $ctid (this may take a while)..."
  if ! pct exec "$ctid" -- bash /root/bootstrap_hermes.sh; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "multi-user" "failed_bootstrap"
    continue
  fi

  log "Checking services status in $ctid..."
  all_active=true
  for user in $(all_hermes_users); do
    if ! pct exec "$ctid" -- systemctl is-active --quiet "hms@$user"; then
      warn "Service hms@$user is not active in $ctid"
      all_active=false
    fi
  done

  if [ "$all_active" = "false" ]; then
    status="partial_failure"
    append_failed_ctid "$ctid"
  fi

  append_container_info "$ctid" "$hostname" "$ip" "multi-user" "$status"
done

log "Deployment routine finished."
