#!/usr/bin/env bash
#
# scripts/upgrade_dev.sh: Faster upgrade for development users via install script.
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

if ! echo "$HERMES_DEV_USERS" | grep -qw "$username"; then
  die "User $username is not in HERMES_DEV_USERS. Use upgrade_prod.sh for production users."
fi

log "Upgrading dev user: $username in CT $ctid..."

branch=$(get_user_branch "$username")
install_url=$(get_install_url "$branch")
repo_url=$(get_repo_url)

log "Running re-installation (upgrade) for $username from branch $branch..."
if ! pct exec "$ctid" -- su - "$username" -c "HERMES_REPO_URL='$repo_url' HERMES_REPO_REF='$branch' bash -c 'curl -fsSL $install_url | bash'"; then
  die "Installation failed for $username in $ctid."
fi

log "Rebuilding/Restarting service hms@$username..."
pct exec "$ctid" -- systemctl restart "hms@$username"

log "Waiting for service to stabilize..."
sleep 5

if ! pct exec "$ctid" -- systemctl is-active --quiet "hms@$username"; then
  die "Service failed to start after install for $username in $ctid."
fi

log "Dev upgrade successful for $username in $ctid."
