#!/usr/bin/env bash
#
# scripts/rollback_user.sh: Rollback a user's binary and database from backup.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

ctid="${1:-}"
username="${2:-}"
backup_timestamp="${3:-}"

if [ -z "$ctid" ] || [ -z "$username" ] || [ -z "$backup_timestamp" ]; then
  die "Usage: $0 <ctid> <username> <backup_timestamp>"
fi

require_cmd pct
validate_username "$username"

if ! echo "$HERMES_PROD_USERS" | grep -qw "$username"; then
  die "User $username is not in HERMES_PROD_USERS. Rollbacks are only supported for prod users."
fi

log "Rolling back user: $username in CT $ctid to backup: $backup_timestamp..."

# Paths
HERMES_BIN="/home/$username/.local/bin/hermes"
HERMES_DB="/home/$username/.hermes/hermes.db"
BACKUP_DIR="/home/$username/.hermes/backups/$backup_timestamp"

# Verification
if ! pct exec "$ctid" -- test -d "$BACKUP_DIR"; then
  die "Backup directory not found: $BACKUP_DIR in $ctid"
fi

log "Stopping service hms@$username..."
pct exec "$ctid" -- systemctl stop "hms@$username"

log "Restoring binary, database and configs from $backup_timestamp..."
pct exec "$ctid" -- su - "$username" -c "cp ${BACKUP_DIR}/hermes.old $HERMES_BIN && \
  if [ -f ${BACKUP_DIR}/hermes.db.old ]; then cp ${BACKUP_DIR}/hermes.db.old $HERMES_DB; fi && \
  if [ -f ${BACKUP_DIR}/env.old ]; then cp ${BACKUP_DIR}/env.old ~/.hermes/.env; fi && \
  if [ -f ${BACKUP_DIR}/config.yaml.old ]; then cp ${BACKUP_DIR}/config.yaml.old ~/.hermes/config.yaml; fi"

log "Starting service hms@$username..."
pct exec "$ctid" -- systemctl start "hms@$username"

log "Waiting for service to stabilize..."
sleep 5

if ! pct exec "$ctid" -- systemctl is-active --quiet "hms@$username"; then
  die "Service failed to start after rollback for $username in $ctid."
fi

log "Rollback successful for $username in $ctid."
