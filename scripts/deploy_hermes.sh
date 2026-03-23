#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

deploy_count="${1:-$COUNT}"
start_ctid="${2:-$START_CTID}"

require_cmd pct
require_nonempty_file "$APP_ENV_FILE"
require_file "$SYSTEMD_TEMPLATE_FILE"
require_file "$SCRIPT_DIR/bootstrap_hermes.sh"

warn_if_placeholder "${HERMES_REPO_URL:-}" "HERMES_REPO_URL still points to a placeholder."
if ! is_dry_run; then
  case "${HERMES_REPO_URL:-}" in
    *example.com*|"")
      die "Set a real HERMES_REPO_URL before real deployment."
      ;;
  esac
fi

init_report_files

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
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/hermes.env\n' "$ctid" "$APP_ENV_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/hermes-bootstrap.env\n' "$ctid" "$LXC_ENV_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap/hermes-agent.service.tpl\n' "$ctid" "$SYSTEMD_TEMPLATE_FILE"
    printf '[DRY-RUN] pct push %s %s /root/bootstrap_hermes.sh\n' "$ctid" "$SCRIPT_DIR/bootstrap_hermes.sh"
    if file_has_noncomment_lines "$AUTHORIZED_KEYS_FILE"; then
      printf '[DRY-RUN] pct push %s %s /root/bootstrap/authorized_keys\n' "$ctid" "$AUTHORIZED_KEYS_FILE"
    fi
    printf '[DRY-RUN] pct exec %s -- bash /root/bootstrap_hermes.sh\n' "$ctid"
    continue
  fi

  if pct_exists "$ctid"; then
    warn "CTID already exists, skipping: $ctid"
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "$HERMES_SERVICE_NAME" "failed_ctid_in_use"
    continue
  fi

  if ! pct clone "$TEMPLATE_CTID" "$ctid" --hostname "$hostname"; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "$HERMES_SERVICE_NAME" "failed_clone"
    continue
  fi

  if ! pct set "$ctid" --memory "$CT_MEMORY" --swap "$CT_SWAP" --cores "$CT_CORES" --onboot "$CT_ONBOOT" --net0 "$net0_opts"; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "$HERMES_SERVICE_NAME" "failed_set"
    continue
  fi

  if ! pct start "$ctid"; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "-" "$HERMES_SERVICE_NAME" "failed_start"
    continue
  fi

  ip="$(wait_for_ip "$ctid" "$CT_DHCP_TIMEOUT" || true)"
  ip="${ip:-"-"}"

  if ! pct exec "$ctid" -- install -d -m 700 /root/bootstrap; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_prepare_dir"
    continue
  fi

  if ! pct push "$ctid" "$APP_ENV_FILE" /root/bootstrap/hermes.env; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_push_app_env"
    continue
  fi

  if ! pct push "$ctid" "$LXC_ENV_FILE" /root/bootstrap/hermes-bootstrap.env; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_push_bootstrap_env"
    continue
  fi

  if ! pct push "$ctid" "$SYSTEMD_TEMPLATE_FILE" /root/bootstrap/hermes-agent.service.tpl; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_push_service_template"
    continue
  fi

  if ! pct push "$ctid" "$SCRIPT_DIR/bootstrap_hermes.sh" /root/bootstrap_hermes.sh; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_push_bootstrap_script"
    continue
  fi

  if file_has_noncomment_lines "$AUTHORIZED_KEYS_FILE" && ! pct push "$ctid" "$AUTHORIZED_KEYS_FILE" /root/bootstrap/authorized_keys; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_push_authorized_keys"
    continue
  fi

  if ! pct exec "$ctid" -- chmod 700 /root/bootstrap_hermes.sh; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_chmod_bootstrap_script"
    continue
  fi

  if ! pct exec "$ctid" -- env \
    HERMES_BOOTSTRAP_ENV=/root/bootstrap/hermes-bootstrap.env \
    HERMES_ENV_SOURCE=/root/bootstrap/hermes.env \
    HERMES_SYSTEMD_TEMPLATE=/root/bootstrap/hermes-agent.service.tpl \
    AUTHORIZED_KEYS_SOURCE=/root/bootstrap/authorized_keys \
    bash /root/bootstrap_hermes.sh; then
    append_failed_ctid "$ctid"
    append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "failed_bootstrap"
    continue
  fi

  service_state="$(pct exec "$ctid" -- systemctl is-active "$HERMES_SERVICE_NAME" 2>/dev/null || true)"
  if [ "$service_state" != "active" ]; then
    status="failed_service_inactive"
    append_failed_ctid "$ctid"
  fi

  append_container_info "$ctid" "$hostname" "$ip" "$HERMES_SERVICE_NAME" "$status"
done

log "Deployment routine finished."
