#!/usr/bin/env bash
#
# scripts/upgrade_prod.sh: Upgrade a production user with backup and auto-rollback.
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

if ! echo "$HERMES_PROD_USERS" | grep -qw "$username"; then
  die "User $username is not in HERMES_PROD_USERS. Use upgrade_dev.sh for development users."
fi

log "Upgrading prod user: $username in CT $ctid..."

# Inside container variables
HERMES_BIN="/home/$username/.local/bin/hermes"
HERMES_DB="/home/$username/.hermes/hermes.db"
BACKUP_DATE="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/home/$username/.hermes/backups/$BACKUP_DATE"

log "Creating backups in $ctid..."
pct exec "$ctid" -- su - "$username" -c "mkdir -p $BACKUP_DIR && \
  cp $HERMES_BIN ${BACKUP_DIR}/hermes.old && \
  if [ -f $HERMES_DB ]; then cp $HERMES_DB ${BACKUP_DIR}/hermes.db.old; fi && \
  cp ~/.hermes/.env ${BACKUP_DIR}/env.old && \
  cp ~/.hermes/config.yaml ${BACKUP_DIR}/config.yaml.old"

log "Rotating old backups (older than 30 days)..."
pct exec "$ctid" -- su - "$username" -c 'find ~/.hermes/backups/ -type d -mtime +30 -exec rm -rf {} +' || true

# Getting branch and install URL
branch=$(get_user_branch "$username")
install_url=$(get_install_url "$branch")
repo_url=$(get_repo_url)

log "Running re-installation (upgrade) for $username..."
if ! pct exec "$ctid" -- su - "$username" -c "HERMES_REPO_URL='$repo_url' HERMES_REPO_REF='$branch' bash -c 'curl -fsSL $install_url | bash'"; then
  log "Installation failed! Rolling back..."
  pct exec "$ctid" -- su - "$username" -c "cp ${BACKUP_DIR}/hermes.old $HERMES_BIN"
  die "Upgrade failed. Binary rolled back."
fi

log "Restarting service hermes-agent@$username..."
pct exec "$ctid" -- systemctl restart "hermes-agent@$username"

log "Waiting for service to stabilize..."
sleep 5

if ! pct exec "$ctid" -- systemctl is-active --quiet "hermes-agent@$username"; then
  log "Service failed to start after upgrade! Rolling back..."
  pct exec "$ctid" -- systemctl stop "hermes-agent@$username"
  pct exec "$ctid" -- su - "$username" -c "cp ${BACKUP_DIR}/hermes.old $HERMES_BIN"
  if pct exec "$ctid" -- test -f "${BACKUP_DIR}/hermes.db.old"; then 
    pct exec "$ctid" -- su - "$username" -c "cp ${BACKUP_DIR}/hermes.db.old $HERMES_DB"
  fi
  pct exec "$ctid" -- su - "$username" -c "cp ${BACKUP_DIR}/env.old ~/.hermes/.env && cp ${BACKUP_DIR}/config.yaml.old ~/.hermes/config.yaml"
  pct exec "$ctid" -- systemctl start "hermes-agent@$username"
  die "Service check failed. Rollback complete."
fi

log "Upgrade successful for $username in $ctid."
