#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[BOOTSTRAP] %s\n' "$*" >&2
}

die() {
  printf '[BOOTSTRAP][ERROR] %s\n' "$*" >&2
  exit 1
}

require_var() {
  local name="$1"
  [ -n "${!name:-}" ] || die "Required variable is empty: $name"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

run_as_user() {
  local command_string="$1"
  su -s /bin/bash -c "$command_string" "$HERMES_RUN_USER"
}

install_authorized_keys_for_root() {
  local source_file="$1"

  install -d -m 700 -o root -g root /root/.ssh
  install -m 600 -o root -g root "$source_file" /root/.ssh/authorized_keys
}

bootstrap_env="${HERMES_BOOTSTRAP_ENV:-/root/bootstrap/hermes-bootstrap.env}"
app_env_source="${HERMES_ENV_SOURCE:-/root/bootstrap/hermes.env}"
systemd_template="${HERMES_SYSTEMD_TEMPLATE:-/root/bootstrap/hermes-agent.service.tpl}"
authorized_keys_source="${AUTHORIZED_KEYS_SOURCE:-/root/bootstrap/authorized_keys}"

[ -f "$bootstrap_env" ] || die "Bootstrap env file not found: $bootstrap_env"
[ -f "$app_env_source" ] || die "Hermes env file not found: $app_env_source"
[ -f "$systemd_template" ] || die "Systemd template not found: $systemd_template"

set -a
# shellcheck disable=SC1090
. "$bootstrap_env"
set +a

require_var HERMES_SERVICE_NAME
require_var HERMES_RUN_USER
require_var HERMES_RUN_GROUP
require_var HERMES_APP_DIR
require_var HERMES_CONFIG_DIR
require_var HERMES_STATE_DIR
require_var HERMES_LOG_DIR
require_var HERMES_ENV_FILE
require_var HERMES_INSTALL_CMD
require_var HERMES_START_CMD

case "${HERMES_REPO_URL:-}" in
  *example.com*|"")
    die "HERMES_REPO_URL must be set to a real repository before real deployment."
    ;;
esac

if [ -n "${TIMEZONE:-}" ]; then
  timedatectl set-timezone "$TIMEZONE" || true
fi

if ! apt-get update; then
  die "apt-get update failed. Check DNS, outbound NAT and vmbr1 routing on the Proxmox host."
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ${HERMES_APT_PACKAGES:-git curl ca-certificates python3 python3-venv python3-pip}; then
  die "Package installation failed. Check apt repositories, DNS and outbound connectivity from the container."
fi

if ! getent group "$HERMES_RUN_GROUP" >/dev/null 2>&1; then
  groupadd --system "$HERMES_RUN_GROUP"
fi

if ! id -u "$HERMES_RUN_USER" >/dev/null 2>&1; then
  useradd --system --gid "$HERMES_RUN_GROUP" --create-home --home-dir "/home/${HERMES_RUN_USER}" --shell /usr/sbin/nologin "$HERMES_RUN_USER"
fi

if [ -s "$authorized_keys_source" ]; then
  install_authorized_keys_for_root "$authorized_keys_source"
  log "Installed authorized_keys for root."
fi

install -d -m 755 -o "$HERMES_RUN_USER" -g "$HERMES_RUN_GROUP" "$HERMES_APP_DIR"
install -d -m 755 -o "$HERMES_RUN_USER" -g "$HERMES_RUN_GROUP" "$HERMES_STATE_DIR"
install -d -m 755 -o "$HERMES_RUN_USER" -g "$HERMES_RUN_GROUP" "$HERMES_LOG_DIR"
install -d -m 750 -o root -g "$HERMES_RUN_GROUP" "$HERMES_CONFIG_DIR"

if [ ! -d "$HERMES_APP_DIR/.git" ]; then
  run_as_user "git clone --depth ${HERMES_GIT_DEPTH:-1} '$HERMES_REPO_URL' '$HERMES_APP_DIR'"
fi

run_as_user "git -C '$HERMES_APP_DIR' fetch --all --tags --prune"
run_as_user "git -C '$HERMES_APP_DIR' checkout '$HERMES_REPO_REF'"

install -m 640 -o root -g "$HERMES_RUN_GROUP" "$app_env_source" "$HERMES_ENV_FILE"

install_cmd="$(printf 'cd %q && /usr/bin/env bash -lc %q' "$HERMES_APP_DIR" "$HERMES_INSTALL_CMD")"
run_as_user "$install_cmd"

start_script="/usr/local/bin/${HERMES_SERVICE_NAME}-start.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\ncd %q\nexec /usr/bin/env bash -lc %q\n' \
  "$HERMES_APP_DIR" \
  "$HERMES_START_CMD" > "$start_script"
chmod 755 "$start_script"

log_file="${HERMES_LOG_DIR}/${HERMES_SERVICE_NAME}.log"
touch "$log_file"
chown "$HERMES_RUN_USER":"$HERMES_RUN_GROUP" "$log_file"

sed \
  -e "s|__SERVICE_NAME__|$(escape_sed "$HERMES_SERVICE_NAME")|g" \
  -e "s|__RUN_USER__|$(escape_sed "$HERMES_RUN_USER")|g" \
  -e "s|__RUN_GROUP__|$(escape_sed "$HERMES_RUN_GROUP")|g" \
  -e "s|__APP_DIR__|$(escape_sed "$HERMES_APP_DIR")|g" \
  -e "s|__ENV_FILE__|$(escape_sed "$HERMES_ENV_FILE")|g" \
  -e "s|__START_SCRIPT__|$(escape_sed "$start_script")|g" \
  -e "s|__LOG_FILE__|$(escape_sed "$log_file")|g" \
  "$systemd_template" > "/etc/systemd/system/${HERMES_SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable --now "$HERMES_SERVICE_NAME"

if [ -n "${HERMES_AFTER_START_CMD:-}" ]; then
  bash -lc "$HERMES_AFTER_START_CMD"
fi

systemctl --no-pager --full status "$HERMES_SERVICE_NAME" || true
log "Bootstrap completed."
