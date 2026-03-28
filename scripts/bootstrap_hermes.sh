#!/usr/bin/env bash
#
# deploy-hermes v2: Bootstrap script for multi-user LXC deployment.
# This script runs inside the container to set up multiple Hermes instances.
#
set -euo pipefail

# ── Inline Helpers ───────────────────────────────────────

log() {
  printf '[INFO] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_var() {
  local var_name="$1"
  local var_val="${!var_name:-}"
  if [ -z "$var_val" ]; then
    die "Required environment variable '$var_name' is not set."
  fi
}

# ── Local Multi-user Helpers ─────────────────────────────
# These match common.sh but are included here since bootstrap is self-contained.

all_hermes_users() {
  printf '%s %s\n' "${HERMES_PROD_USERS:-}" "${HERMES_DEV_USERS:-}" | xargs
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

generate_sudoers() {
  local sudoers_file="/etc/sudoers.d/hermes-users"
  local user
  log "Generating sudoers for Hermes users..."
  : > "$sudoers_file"
  for user in $(all_hermes_users); do
    printf '%s ALL=(root) NOPASSWD: /bin/systemctl restart hermes-agent@%s.service, /bin/systemctl stop hermes-agent@%s.service, /bin/systemctl status hermes-agent@%s.service, /bin/journalctl -u hermes-agent@%s.service *\n' \
      "$user" "$user" "$user" "$user" "$user" >> "$sudoers_file"
  done
  chmod 440 "$sudoers_file"
}

# ── Main Bootstrap Logic ─────────────────────────────────

BOOTSTRAP_DIR="/root/bootstrap"
ENV_FILE="$BOOTSTRAP_DIR/hermes-bootstrap.env"
USER_ENV_TEMPLATE="$BOOTSTRAP_DIR/hermes-user.env"
CONFIG_YAML_SOURCE="$BOOTSTRAP_DIR/config.yaml"
SERVICE_TEMPLATE="$BOOTSTRAP_DIR/hermes-agent@.service"
AUTH_KEYS_FILE="$BOOTSTRAP_DIR/authorized_keys"

log "Loading bootstrap environment..."
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
else
  die "Bootstrap environment file not found: $ENV_FILE"
fi

require_var HERMES_PROD_USERS
require_var HERMES_FORK_OWNER
require_var HERMES_FORK_REPO
require_var HERMES_PROD_BRANCH
require_var HERMES_DEV_BRANCH

# Defaults for variables that may be missing in older env files
HERMES_BASE_PORT="${HERMES_BASE_PORT:-8080}"
HERMES_ADMIN_BASE_PORT="${HERMES_ADMIN_BASE_PORT:-9080}"
HERMES_APT_PACKAGES="${HERMES_APT_PACKAGES:-git curl ca-certificates sudo build-essential gettext}"

log "Checking for base packages..."
if ! command -v git >/dev/null || ! command -v curl >/dev/null || ! command -v envsubst >/dev/null || ! command -v sudo >/dev/null; then
  log "Installing missing base packages..."
  apt-get update
  # shellcheck disable=SC2086
  apt-get install -y $HERMES_APT_PACKAGES
else
  log "Base packages already installed, skipping apt-get."
fi

if [ "${INSTALL_CLAUDE_CODE:-false}" = "true" ]; then
  if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
    log "Installing Node.js v22 for Claude Code..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  else
    log "Node.js already installed, skipping installation."
  fi
fi

if [ -f "$AUTH_KEYS_FILE" ]; then
  log "Setting up authorized_keys for root..."
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  # Overwrite completely to support key removal sync
  cp "$AUTH_KEYS_FILE" /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
else
  log "No authorized_keys pushed, clearing root keys..."
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

log "Configuring journald log rotation..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/hermes.conf <<'EOF'
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
EOF
systemctl restart systemd-journald

setup_user() {
  local user="$1"
  local branch="$2"
  local user_idx="$3"
  
  local public_port=$((HERMES_BASE_PORT + user_idx))
  local admin_port=$((HERMES_ADMIN_BASE_PORT + user_idx))
  
  validate_username "$user"
  log "Setting up user: $user (branch: $branch)"
  
  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user"
  fi
  
  chmod 700 /home/"$user"
  
  # SSH Keys per-user (for GitHub deploy keys if needed)
  su - "$user" -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
  if [ ! -f "/home/$user/.ssh/id_ed25519" ]; then
    su - "$user" -c 'ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q'
  fi
  local pub_key
  pub_key=$(cat "/home/$user/.ssh/id_ed25519.pub")
  log "SSH Public Key for $user: $pub_key"
  
  # Ensure local bin exists
  su - "$user" -c 'mkdir -p ~/.local/bin'
  
  # NPM prefix FIX for per-user global install (only if Node.js is available)
  if [ "${INSTALL_CLAUDE_CODE:-false}" = "true" ]; then
    su - "$user" -c 'npm config set prefix "~/.local"'
  fi
  
  # PATH in .bashrc
  local path_append='export PATH="$HOME/.local/bin:$PATH"'
  if ! su - "$user" -c "grep -qF '$path_append' ~/.bashrc"; then
    su - "$user" -c "echo '$path_append' >> ~/.bashrc"
  fi
  
  # Install Hermes Agent
  log "Installing Hermes Agent for $user..."
  local install_url
  install_url=$(get_install_url "$branch")
  local repo_url
  repo_url=$(get_repo_url)
  
  su - "$user" -c "HERMES_REPO_URL='$repo_url' HERMES_REPO_REF='$branch' bash -c 'curl -fsSL $install_url | bash'"
  
  # Install Claude Code
  if [ "${INSTALL_CLAUDE_CODE:-false}" = "true" ]; then
    log "Installing Claude Code for $user..."
    su - "$user" -c 'npm install -g @anthropic-ai/claude-code'
  fi
  
  # Config & Env
  su - "$user" -c 'mkdir -p ~/.hermes'

  # Only copy template .env if it doesn't already exist (preserve user secrets)
  if [ -f "$USER_ENV_TEMPLATE" ] && [ ! -f "/home/$user/.hermes/.env" ]; then
    cp "$USER_ENV_TEMPLATE" "/home/$user/.hermes/.env"
    chown "$user":"$user" "/home/$user/.hermes/.env"
    chmod 600 "/home/$user/.hermes/.env"
  fi

  # Ensure port assignments are correct (idempotent: update if exists, append if not)
  local env_file="/home/$user/.hermes/.env"
  if [ -f "$env_file" ]; then
    if grep -q '^HERMES_LISTEN_PORT=' "$env_file"; then
      sed -i "s|^HERMES_LISTEN_PORT=.*|HERMES_LISTEN_PORT=$public_port|" "$env_file"
    else
      printf '\n# Assigned ports for this user\nHERMES_LISTEN_PORT=%s\n' "$public_port" >> "$env_file"
    fi
    if grep -q '^HERMES_ADMIN_LISTEN_PORT=' "$env_file"; then
      sed -i "s|^HERMES_ADMIN_LISTEN_PORT=.*|HERMES_ADMIN_LISTEN_PORT=$admin_port|" "$env_file"
    else
      printf 'HERMES_ADMIN_LISTEN_PORT=%s\n' "$admin_port" >> "$env_file"
    fi
  fi
  
  # Always update the template; render config.yaml from it via envsubst
  if [ -f "$CONFIG_YAML_SOURCE" ]; then
    cp "$CONFIG_YAML_SOURCE" "/home/$user/.hermes/config.yaml.tpl"
    chown "$user":"$user" "/home/$user/.hermes/config.yaml.tpl"
    chmod 600 "/home/$user/.hermes/config.yaml.tpl"

    # Render config.yaml from template using user's .env
    local env_file="/home/$user/.hermes/.env"
    if [ -f "$env_file" ]; then
      su - "$user" -c "set -a && source ~/.hermes/.env && set +a && envsubst '\$TG_CHANNEL_ID \$GOOGLE_API_KEY_1 \$GOOGLE_API_KEY_2 \$GOOGLE_API_KEY_3' < ~/.hermes/config.yaml.tpl > ~/.hermes/config.yaml"
      chown "$user":"$user" "/home/$user/.hermes/config.yaml"
      chmod 600 "/home/$user/.hermes/config.yaml"
    else
      log "Warning: .env not found for $user, copying template as-is"
      cp "$CONFIG_YAML_SOURCE" "/home/$user/.hermes/config.yaml"
      chown "$user":"$user" "/home/$user/.hermes/config.yaml"
      chmod 600 "/home/$user/.hermes/config.yaml"
    fi
  fi
}

log "Processing production users..."
idx=0
for user in $HERMES_PROD_USERS; do
  setup_user "$user" "$HERMES_PROD_BRANCH" "$idx"
  idx=$((idx + 1))
done

log "Processing development users..."
for user in $HERMES_DEV_USERS; do
  setup_user "$user" "$HERMES_DEV_BRANCH" "$idx"
  idx=$((idx + 1))
done

generate_sudoers

log "Installing systemd template unit..."
if [ -f "$SERVICE_TEMPLATE" ]; then
  cp "$SERVICE_TEMPLATE" "/etc/systemd/system/hermes-agent@.service"
  systemctl daemon-reload
  
  for user in $(all_hermes_users); do
    log "Enabling and starting service for $user..."
    systemctl enable "hermes-agent@$user"
    systemctl start "hermes-agent@$user"
  done
else
  log "Warning: systemd service template not found at $SERVICE_TEMPLATE"
fi

log "Bootstrap complete!"
log "IMPORTANT: For Claude Code, you must perform a manual login for each user."
log "If 'claude login' fails with 'not a tty' error, use 'lxc console <ctid>' or direct SSH to login."
for user in $(all_hermes_users); do
  log "  su - $user -c 'claude login'"
done
