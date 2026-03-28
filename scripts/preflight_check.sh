#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${1:-}"

require_cmd pct
require_nonempty_file "$USER_ENV_FILE"
require_config_yaml
require_file "$SYSTEMD_SERVICE_FILE"
require_file "$PROJECT_ROOT/scripts/bootstrap_hermes.sh"

validate_ipv4 "$PRIVATE_GATEWAY" || die "Invalid PRIVATE_GATEWAY: $PRIVATE_GATEWAY"
validate_ipv4 "$NPM_LXC_IP" || die "Invalid NPM_LXC_IP: $NPM_LXC_IP"
is_positive_integer "$START_CTID" || die "Invalid START_CTID: $START_CTID"
is_positive_integer "$COUNT" || die "Invalid COUNT: $COUNT"
is_positive_integer "$PRIMARY_PUBLIC_CTID" || die "Invalid PRIMARY_PUBLIC_CTID: $PRIMARY_PUBLIC_CTID"
is_positive_integer "$CT_ROOTFS_SIZE" || die "Invalid CT_ROOTFS_SIZE: $CT_ROOTFS_SIZE"
is_positive_integer "$STORAGE_FREE_BUFFER_GB" || die "Invalid STORAGE_FREE_BUFFER_GB: $STORAGE_FREE_BUFFER_GB"
validate_port "$HERMES_BASE_PORT" || die "Invalid HERMES_BASE_PORT: $HERMES_BASE_PORT"
validate_port "$HERMES_ADMIN_BASE_PORT" || die "Invalid HERMES_ADMIN_BASE_PORT: $HERMES_ADMIN_BASE_PORT"
validate_port "$NPM_HTTP_PORT" || die "Invalid NPM_HTTP_PORT: $NPM_HTTP_PORT"
validate_port "$NPM_HTTPS_PORT" || die "Invalid NPM_HTTPS_PORT: $NPM_HTTPS_PORT"
validate_port "$NPM_ADMIN_PORT" || die "Invalid NPM_ADMIN_PORT: $NPM_ADMIN_PORT"
validate_ipv4 "$(generate_container_ip "$START_CTID")" || die "Invalid generated container IP for START_CTID=$START_CTID"

if [ -n "${HOST_PUBLIC_IP:-}" ] && ! validate_ipv4 "$HOST_PUBLIC_IP"; then
  warn "HOST_PUBLIC_IP does not look like a plain IPv4 address: $HOST_PUBLIC_IP"
fi

if [ -z "${HERMES_FORK_OWNER:-}" ]; then
  die "HERMES_FORK_OWNER is required for v2. Set it to your GitHub username in hermes-lxc.env."
fi

if [ -z "${HERMES_PROD_USERS:-}" ]; then
  die "HERMES_PROD_USERS is required for v2. Define at least one production user."
fi

if [ -z "${HERMES_PROD_BRANCH:-}" ]; then
  die "HERMES_PROD_BRANCH is required for v2."
fi

if [ -z "${HERMES_DEV_BRANCH:-}" ]; then
  die "HERMES_DEV_BRANCH is required for v2."
fi

api_key_value="$(awk -F= '/^OPENAI_API_KEY=/{print $2}' "$USER_ENV_FILE" | head -n1 || true)"
warn_if_placeholder "$api_key_value" "OPENAI_API_KEY still has a placeholder value."

printf 'Project root: %s\n' "$PROJECT_ROOT"
printf 'Config file: %s\n' "$LXC_ENV_FILE"
printf 'User env: %s\n' "$USER_ENV_FILE"
printf 'Config YAML: %s\n' "$CONFIG_YAML_FILE"
printf 'Template CTID: %s\n' "$TEMPLATE_CTID"
if [ "$COUNT" = "1" ]; then
  printf 'Target CTID: %s\n' "$START_CTID"
else
  printf 'Target range: %s..%s\n' "$START_CTID" "$((START_CTID + COUNT - 1))"
fi
printf 'Bridge: %s\n' "$BRIDGE"
printf 'IP config: %s\n' "$IP_CONFIG"
printf 'Service name: %s (template unit)\n' "$HERMES_SERVICE_NAME"
printf 'Prod users: %s\n' "$HERMES_PROD_USERS"
printf 'Dev users: %s\n' "$HERMES_DEV_USERS"
printf 'Unprivileged CT: %s\n' "$CT_UNPRIVILEGED"
printf 'NPM LXC IP: %s\n' "$NPM_LXC_IP"
printf 'Primary public CTID: %s\n' "$PRIMARY_PUBLIC_CTID"
if [ -f "$PORT_FORWARD_FILE" ]; then
  printf 'Port forward file: %s\n' "$PORT_FORWARD_FILE"
else
  warn "Port forward file not found: $PORT_FORWARD_FILE"
fi
if [ -f "$NPM_PROXY_HOSTS_FILE" ]; then
  printf 'NPM proxy hosts file: %s\n' "$NPM_PROXY_HOSTS_FILE"
else
  warn "NPM proxy hosts file not found: $NPM_PROXY_HOSTS_FILE"
fi
if file_has_noncomment_lines "$AUTHORIZED_KEYS_FILE"; then
  printf 'Authorized keys file: %s\n' "$AUTHORIZED_KEYS_FILE"
else
  warn "Authorized keys file is missing, empty or contains no active keys: $AUTHORIZED_KEYS_FILE"
fi
if [ "$IP_CONFIG" = "static" ]; then
  printf 'Private subnet: %s via %s\n' "${PRIVATE_SUBNET_CIDR:-"${STATIC_IP_PREFIX}.0/${PRIVATE_PREFIX_LENGTH}"}" "$PRIVATE_GATEWAY"
else
  warn "IP_CONFIG=dhcp selected. Proxmox VE itself is not a DHCP server by default; use an external DHCP service or switch to static IP mode."
fi
if [ "$CT_UNPRIVILEGED" != "1" ]; then
  warn "CT_UNPRIVILEGED is not set to 1. This weakens the default container isolation model."
fi

if pct status "$TEMPLATE_CTID" >/dev/null 2>&1; then
  log "Template or prototype container $TEMPLATE_CTID already exists."
else
  warn "Template CTID $TEMPLATE_CTID does not exist yet. This is expected before the first run."
fi


conflicts=0
for offset in $(seq 0 $((COUNT - 1))); do
  ctid=$((START_CTID + offset))
  if pct_exists "$ctid"; then
    warn "Target CTID already exists: $ctid"
    conflicts=1
  fi
done

if [ "$conflicts" -ne 0 ]; then
  die "Target CTID range is not empty."
fi

log "Preflight checks passed."
