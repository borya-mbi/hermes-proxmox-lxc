#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_LXC_ENV="${HERMES_LXC_ENV:-$PROJECT_ROOT/deploy/hermes-lxc.env}"

log() {
  printf '[INFO] %s\n' "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PROJECT_ROOT/$1" ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

require_file() {
  [ -f "$1" ] || die "Missing file: $1"
}

require_nonempty_file() {
  [ -s "$1" ] || die "Missing or empty file: $1"
}

file_has_noncomment_lines() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -Eq '^[[:space:]]*[^#[:space:]]' "$file_path"
}

is_positive_integer() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$1" -gt 0 ]
      ;;
  esac
}

validate_ipv4() {
  local ip="$1"
  local octet
  local old_ifs

  case "$ip" in
    ''|*[!0-9.]*|*.*.*.*.*|.*|*.)
      return 1
      ;;
  esac

  old_ifs="$IFS"
  IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  IFS="$old_ifs"

  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    case "$octet" in
      ''|*[!0-9]*)
        return 1
        ;;
    esac
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

validate_port() {
  is_positive_integer "$1" && [ "$1" -le 65535 ]
}

is_dry_run() {
  [ "${DRY_RUN:-0}" = "1" ]
}

run_cmd() {
  if is_dry_run; then
    printf '[DRY-RUN]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

load_lxc_env() {
  local env_file="${1:-$DEFAULT_LXC_ENV}"

  env_file="$(resolve_path "$env_file")"
  require_file "$env_file"

  # Зберігаємо значення DRY_RUN, передане через префікс
  local saved_dry_run="${DRY_RUN:-}"

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  # Відновлюємо значення DRY_RUN, якщо воно було явно вказане
  if [ -n "$saved_dry_run" ]; then
    DRY_RUN="$saved_dry_run"
  fi

  LXC_ENV_FILE="$env_file"
  USER_ENV_FILE="$(resolve_path "${LOCAL_HERMES_USER_ENV_FILE:-deploy/hermes-user.env}")"
  CONFIG_YAML_FILE="$(resolve_path "${LOCAL_CONFIG_YAML_FILE:-deploy/config.yaml}")"
  SYSTEMD_SERVICE_FILE="$(resolve_path "${SYSTEMD_SERVICE_FILE:-systemd/hms@.service}")"
  CONTAINER_INFO_FILE="$(resolve_path "${CONTAINER_INFO_FILE:-deploy/container_info.tsv}")"
  FAILED_CTIDS_FILE="$(resolve_path "${FAILED_CTIDS_FILE:-deploy/failed_ctids.txt}")"
  NOTES_FILE="$(resolve_path "${NOTES_FILE:-deploy/container-notes.tsv}")"

  START_CTID="${START_CTID:-931}"
  COUNT="${COUNT:-1}"
  NAME_PREFIX="${NAME_PREFIX:-hermes}"
  CT_MEMORY="${CT_MEMORY:-4096}"
  CT_SWAP="${CT_SWAP:-1024}"
  CT_CORES="${CT_CORES:-4}"
  CT_ROOTFS_SIZE="${CT_ROOTFS_SIZE:-16}"
  CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-1}"
  CT_ONBOOT="${CT_ONBOOT:-1}"
  CT_DHCP_TIMEOUT="${CT_DHCP_TIMEOUT:-120}"
  IP_CONFIG="${IP_CONFIG:-static}"
  PRIVATE_GATEWAY="${PRIVATE_GATEWAY:-192.168.10.1}"
  PRIVATE_PREFIX_LENGTH="${PRIVATE_PREFIX_LENGTH:-24}"
  STATIC_IP_PREFIX="${STATIC_IP_PREFIX:-192.168.10}"
  STATIC_IP_START="${STATIC_IP_START:-31}"
  NPM_LXC_IP="${NPM_LXC_IP:-192.168.10.10}"
  NPM_HTTP_PORT="${NPM_HTTP_PORT:-80}"
  NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-443}"
  NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-81}"
  BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
  PRIMARY_PUBLIC_DOMAIN="${PRIMARY_PUBLIC_DOMAIN:-agent.example.com}"
  PORTAL_CTID="${PORTAL_CTID:-930}"
  PRIMARY_PUBLIC_CTID="${PRIMARY_PUBLIC_CTID:-$START_CTID}"
  NPM_ADMIN_DOMAIN="${NPM_ADMIN_DOMAIN:-npm.example.com}"
  ADMIN_DOMAIN_PREFIX="${ADMIN_DOMAIN_PREFIX:-adm}"
  AGENT_DOMAIN_PREFIX="${AGENT_DOMAIN_PREFIX:-agent}"
  # v2: Per-user ports are calculated from HERMES_BASE_PORT + user_index.
  # These must be set BEFORE the backward-compat aliases below.
  HERMES_BASE_PORT="${HERMES_BASE_PORT:-8080}"
  HERMES_ADMIN_BASE_PORT="${HERMES_ADMIN_BASE_PORT:-9080}"
  # HERMES_PUBLIC_PORT and HERMES_ADMIN_PORT are retained for backward compatibility
  # with preflight_check.sh and the NPM proxy plan generator, representing the
  # first user's ports (index 0).
  HERMES_PUBLIC_PORT="${HERMES_PUBLIC_PORT:-$HERMES_BASE_PORT}"
  HERMES_ADMIN_PORT="${HERMES_ADMIN_PORT:-$HERMES_ADMIN_BASE_PORT}"
  HERMES_HTTP_HEALTH_PATH="${HERMES_HTTP_HEALTH_PATH:-/}"
  STORAGE_FREE_BUFFER_GB="${STORAGE_FREE_BUFFER_GB:-2}"
  TEMPLATE_IP="${TEMPLATE_IP:-.250}"
  PORT_FORWARD_FILE="$(resolve_path "${PORT_FORWARD_FILE:-deploy/port-forwards.tsv}")"
  NPM_PROXY_HOSTS_FILE="$(resolve_path "${NPM_PROXY_HOSTS_FILE:-deploy/npm-proxy-hosts.tsv}")"
  AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-deploy/authorized_keys}"
  if [ -n "$AUTHORIZED_KEYS_FILE" ]; then
    AUTHORIZED_KEYS_FILE="$(resolve_path "$AUTHORIZED_KEYS_FILE")"
  fi
  HERMES_SERVICE_NAME="${HERMES_SERVICE_NAME:-hms}"

  # Multi-user & Fork variables
  HERMES_PROD_USERS="${HERMES_PROD_USERS:-user1 user2}"
  HERMES_DEV_USERS="${HERMES_DEV_USERS:-dev-user}"
  HERMES_FORK_OWNER="${HERMES_FORK_OWNER:-}"
  HERMES_FORK_REPO="${HERMES_FORK_REPO:-hermes-agent}"
  HERMES_PROD_BRANCH="${HERMES_PROD_BRANCH:-main}"
  HERMES_DEV_BRANCH="${HERMES_DEV_BRANCH:-custom-features}"
  INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-true}"
}

generate_mac_for_ctid() {
  local ctid="$1"
  printf 'BC:24:11:%02X:%02X:%02X\n' \
    $(((ctid >> 16) & 255)) \
    $(((ctid >> 8) & 255)) \
    $((ctid & 255))
}

generate_container_ip() {
  local ctid="$1"
  local host_octet

  if [ "$ctid" = "${TEMPLATE_CTID:-}" ] && [ -n "$TEMPLATE_IP" ]; then
    if [[ "$TEMPLATE_IP" =~ ^\.[0-9]+$ ]]; then
      host_octet="${TEMPLATE_IP#.}"
    else
      printf '%s\n' "$TEMPLATE_IP"
      return 0
    fi
  else
    host_octet=$((STATIC_IP_START + (ctid - START_CTID)))
  fi

  if [ "$host_octet" -gt 254 ]; then
    die "Calculated host octet is out of range ($host_octet > 254) for CTID $ctid. Check START_CTID and STATIC_IP_START."
  fi

  printf '%s.%s\n' "$STATIC_IP_PREFIX" "$host_octet"
}

resolve_target_ip() {
  local target="$1"

  case "$target" in
    npm)
      printf '%s\n' "$NPM_LXC_IP"
      ;;
    ''|*[!0-9]*.*)
      printf '%s\n' "$target"
      ;;
    *)
      printf '%s\n' "$(generate_container_ip "$target")"
      ;;
  esac
}

build_net0_opts() {
  local ctid="$1"
  local opts

  case "$IP_CONFIG" in
    dhcp)
      opts="name=eth0,bridge=${BRIDGE},ip=dhcp,hwaddr=$(generate_mac_for_ctid "$ctid")"
      ;;
    static)
      opts="name=eth0,bridge=${BRIDGE},ip=$(generate_container_ip "$ctid")/${PRIVATE_PREFIX_LENGTH},gw=${PRIVATE_GATEWAY},hwaddr=$(generate_mac_for_ctid "$ctid")"
      ;;
    *)
      die "Unsupported IP_CONFIG value: $IP_CONFIG"
      ;;
  esac

  if [ -n "${VLAN_TAG:-}" ]; then
    opts="${opts},tag=${VLAN_TAG}"
  fi

  printf '%s\n' "$opts"
}

pct_exists() {
  pct status "$1" >/dev/null 2>&1
}

get_container_ip() {
  pct exec "$1" -- bash -lc "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true
}

wait_for_ip() {
  local ctid="$1"
  local timeout="${2:-$CT_DHCP_TIMEOUT}"
  local waited=0
  local step=10
  local ip=""

  while [ "$waited" -lt "$timeout" ]; do
    ip="$(get_container_ip "$ctid")"
    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep "$step"
    waited=$((waited + step))
  done

  return 1
}

ensure_parent_dir() {
  mkdir -p "$(dirname "$1")"
}

init_report_files() {
  ensure_parent_dir "$CONTAINER_INFO_FILE"
  ensure_parent_dir "$FAILED_CTIDS_FILE"
  : > "$FAILED_CTIDS_FILE"
  if [ ! -f "$CONTAINER_INFO_FILE" ]; then
    printf 'ctid\thostname\tip\tservice\tstatus\n' > "$CONTAINER_INFO_FILE"
  fi
}

append_failed_ctid() {
  ensure_parent_dir "$FAILED_CTIDS_FILE"
  printf '%s\n' "$1" >> "$FAILED_CTIDS_FILE"
}

append_container_info() {
  ensure_parent_dir "$CONTAINER_INFO_FILE"
  if [ ! -f "$CONTAINER_INFO_FILE" ]; then
    printf 'ctid\thostname\tip\tservice\tstatus\n' > "$CONTAINER_INFO_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$CONTAINER_INFO_FILE"
}

warn_if_placeholder() {
  case "$1" in
    *example.com*|replace-me|"")
      warn "$2"
      ;;
  esac
}

# ── Multi-user helpers ───────────────────────────────────

all_hermes_users() {
  printf '%s %s\n' "${HERMES_PROD_USERS:-}" "${HERMES_DEV_USERS:-}" | xargs
}

get_user_branch() {
  local user="$1"
  local prod_user dev_user
  for prod_user in $HERMES_PROD_USERS; do
    if [ "$user" = "$prod_user" ]; then
      printf '%s\n' "$HERMES_PROD_BRANCH"
      return 0
    fi
  done
  for dev_user in $HERMES_DEV_USERS; do
    if [ "$user" = "$dev_user" ]; then
      printf '%s\n' "$HERMES_DEV_BRANCH"
      return 0
    fi
  done
  die "Unknown user '$user': not found in HERMES_PROD_USERS or HERMES_DEV_USERS."
}

get_user_port() {
  local target_user="$1"
  local base_port="$2"
  local idx=0
  local user
  for user in $(all_hermes_users); do
    if [ "$user" = "$target_user" ]; then
      printf '%s\n' $((base_port + idx))
      return 0
    fi
    idx=$((idx + 1))
  done
  die "Unknown user '$target_user': cannot assign port. User not in HERMES_PROD_USERS or HERMES_DEV_USERS."
}

get_install_url() {
  local branch="$1"
  printf 'https://raw.githubusercontent.com/%s/%s/%s/scripts/install.sh\n' \
    "$HERMES_FORK_OWNER" "$HERMES_FORK_REPO" "$branch"
}

get_repo_url() {
  printf 'https://github.com/%s/%s.git\n' "$HERMES_FORK_OWNER" "$HERMES_FORK_REPO"
}

validate_username() {
  local name="$1"
  case "$name" in
    ''|*[!a-z0-9_-]*)
      die "Invalid username: '$name'. Only [a-z0-9_-] allowed."
      ;;
  esac
}

require_config_yaml() {
  local cfg
  cfg="$(resolve_path "${LOCAL_CONFIG_YAML_FILE:-deploy/config.yaml}")"
  if [ ! -f "$cfg" ]; then
    die "Config YAML not found: $cfg. Copy deploy/config.yaml.example to deploy/config.yaml and fill in real values."
  fi
}

generate_sudoers() {
  local sudoers_file="/etc/sudoers.d/hermes-users"
  local user
  : > "$sudoers_file"
  for user in $(all_hermes_users); do
    printf '%s ALL=(root) NOPASSWD: /bin/systemctl restart hms@%s.service, /bin/systemctl stop hms@%s.service, /bin/systemctl status hms@%s.service, /bin/journalctl -u hms@%s.service *\n' \
      "$user" "$user" "$user" "$user" "$user" >> "$sudoers_file"
  done
  chmod 440 "$sudoers_file"
}
