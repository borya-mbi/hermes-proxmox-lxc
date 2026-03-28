#!/usr/bin/env bash
#
# scripts/add_user.sh: Add a new user to an existing Hermes LXC.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

ctid="${1:-}"
username="${2:-}"

if [ -z "$ctid" ] || [ -z "$username" ]; then
  die "Usage: $0 <ctid> <username>"
fi

require_cmd pct
validate_username "$username"

log "Adding user: $username to CT $ctid..."

# Calculate index for port assignment and verify existence in inventory
user_idx=0
user_found=false
for u in $(all_hermes_users); do
  if [ "$u" = "$username" ]; then
    user_found=true
    break
  fi
  user_idx=$((user_idx + 1))
done

if [ "$user_found" = "false" ]; then
  die "User '$username' not found in HERMES_PROD_USERS or HERMES_DEV_USERS in deploy/hermes-lxc.env. Add it first and rerun."
fi

if ! pct_exists "$ctid"; then
    die "Container $ctid does not exist."
fi

branch=$(get_user_branch "$username")
log "Proceeding with branch: $branch"


# Prepare bootstrap dir
pct exec "$ctid" -- install -d -m 700 /root/bootstrap

# Push files
pct push "$ctid" "$LXC_ENV_FILE" /root/bootstrap/hermes-bootstrap.env
pct push "$ctid" "$USER_ENV_FILE" /root/bootstrap/hermes-user.env
pct push "$ctid" "$CONFIG_YAML_FILE" /root/bootstrap/config.yaml
pct push "$ctid" "$SYSTEMD_SERVICE_FILE" /root/bootstrap/hms@.service

# We need a way to run JUST setup_user for this person.
# We can create a temporary script inside the container and run it.

log "Creating setup script in $ctid..."
SETUP_SCRIPT_CT="/root/setup_one_user.sh"

# Note: We reuse the logic from bootstrap_hermes.sh here
cat <<EOF > /tmp/setup_one_user.sh
#!/usr/bin/env bash
set -euo pipefail

# Inline multi-user logic (same as bootstrap)
get_install_url() {
  printf 'https://raw.githubusercontent.com/%s/%s/%s/scripts/install.sh\n' \
    "$HERMES_FORK_OWNER" "$HERMES_FORK_REPO" "\$1"
}
get_repo_url() {
  printf 'https://github.com/%s/%s.git\n' "$HERMES_FORK_OWNER" "$HERMES_FORK_REPO"
}

BOOTSTRAP_DIR="/root/bootstrap"
USER_ENV_TEMPLATE="\$BOOTSTRAP_DIR/hermes-user.env"
CONFIG_YAML_TEMPLATE="\$BOOTSTRAP_DIR/config.yaml"
SERVICE_TEMPLATE="\$BOOTSTRAP_DIR/hms@.service"

user="$username"
branch="$branch"

if ! id "\$user" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "\$user"
fi
chmod 700 /home/"\$user"

su - "\$user" -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
if [ ! -f "/home/\$user/.ssh/id_ed25519" ]; then
  su - "\$user" -c 'ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q'
fi

su - "\$user" -c 'mkdir -p ~/.local/bin'
if [ "${INSTALL_CLAUDE_CODE:-false}" = "true" ]; then
  su - "\$user" -c 'npm config set prefix "~/.local"'
fi
path_append='export PATH="\$HOME/.local/bin:\$PATH"'
if ! su - "\$user" -c "grep -qF '\$path_append' ~/.bashrc"; then
  su - "\$user" -c "echo '\$path_append' >> ~/.bashrc"
fi

install_url=\$(get_install_url "\$branch")
repo_url=\$(get_repo_url)
su - "\$user" -c "HERMES_REPO_URL='\$repo_url' HERMES_REPO_REF='\$branch' bash -c 'curl -fsSL \$install_url | bash'"

if [ "${INSTALL_CLAUDE_CODE:-false}" = "true" ]; then
  su - "\$user" -c 'npm install -g @anthropic-ai/claude-code'
fi

su - "\$user" -c 'mkdir -p ~/.hermes'
if [ ! -f "/home/\$user/.hermes/.env" ]; then
  cp "\$USER_ENV_TEMPLATE" "/home/\$user/.hermes/.env"
fi

# Assign ports (idempotent)
env_file="/home/\$user/.hermes/.env"
if [ -f "\$env_file" ]; then
  if grep -q '^HERMES_LISTEN_PORT=' "\$env_file"; then
    sed -i "s|^HERMES_LISTEN_PORT=.*|HERMES_LISTEN_PORT=$((HERMES_BASE_PORT + user_idx))|" "\$env_file"
  else
    printf '\n# Assigned ports for this user\nHERMES_LISTEN_PORT=%s\n' "$((HERMES_BASE_PORT + user_idx))" >> "\$env_file"
  fi
  if grep -q '^HERMES_ADMIN_LISTEN_PORT=' "\$env_file"; then
    sed -i "s|^HERMES_ADMIN_LISTEN_PORT=.*|HERMES_ADMIN_LISTEN_PORT=$((HERMES_ADMIN_BASE_PORT + user_idx))|" "\$env_file"
  else
    printf 'HERMES_ADMIN_LISTEN_PORT=%s\n' "$((HERMES_ADMIN_BASE_PORT + user_idx))" >> "\$env_file"
  fi
fi

# Save template and render config
cp "\$CONFIG_YAML_TEMPLATE" "/home/\$user/.hermes/config.yaml.tpl"
su - "\$user" -c "set -a && source ~/.hermes/.env && set +a && envsubst '\\\$TG_CHANNEL_ID \\\$GOOGLE_API_KEY_1 \\\$GOOGLE_API_KEY_2 \\\$GOOGLE_API_KEY_3' < ~/.hermes/config.yaml.tpl > ~/.hermes/config.yaml"
chown -R "\$user":"\$user" "/home/\$user/.hermes"
chmod 600 "/home/\$user/.hermes/.env" "/home/\$user/.hermes/config.yaml" "/home/\$user/.hermes/config.yaml.tpl"

# Update sudoers
sudoers_file="/etc/sudoers.d/hermes-users"
if ! grep -q "hms@${username}.service" "\$sudoers_file" 2>/dev/null; then
  printf '${username} ALL=(root) NOPASSWD: /bin/systemctl restart hms@${username}.service, /bin/systemctl stop hms@${username}.service, /bin/systemctl status hms@${username}.service, /bin/journalctl -u hms@${username}.service *\n' >> "\$sudoers_file"
  chmod 440 "\$sudoers_file"
fi

# Service
cp "\$SERVICE_TEMPLATE" "/etc/systemd/system/hms@.service"
systemctl daemon-reload
systemctl enable --now "hms@\$user"

EOF

# Push the temporary setup script
pct push "$ctid" /tmp/setup_one_user.sh "$SETUP_SCRIPT_CT"
rm /tmp/setup_one_user.sh

log "Executing setup script in $ctid..."
# We need to pass the ENV variables for the setup script to work
pct exec "$ctid" -- env \
    HERMES_FORK_OWNER="$HERMES_FORK_OWNER" \
    HERMES_FORK_REPO="$HERMES_FORK_REPO" \
    INSTALL_CLAUDE_CODE="$INSTALL_CLAUDE_CODE" \
    bash "$SETUP_SCRIPT_CT"

log "User $username added successfully to $ctid."
log "IMPORTANT: Don't forget to perform a manual login for Claude Code:"
log "If 'claude login' fails with 'not a tty' error, use 'lxc console <ctid>' or direct SSH to login."
log "  su - $username -c 'claude login'"
