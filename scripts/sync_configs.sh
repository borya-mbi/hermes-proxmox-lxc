#!/usr/bin/env bash
#
# scripts/sync_configs.sh: Synchronize config.yaml with environment variables safely.
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

log "Synchronizing config for $username in $ctid..."

# Inside container variables
HERMES_HOME="/home/$username/.hermes"
USER_ENV="${HERMES_HOME}/.env"
USER_CONFIG="${HERMES_HOME}/config.yaml"

# This script must run INSIDE the container to have access to the user's .env
# We use envsubst with an explicit list of variables to prevent accidental corruption.

log "Running config synchronization in $ctid..."
pct exec "$ctid" -- su - "$username" -c "set -a && source ${USER_ENV} && set +a && envsubst '\$TG_CHANNEL_ID \$GOOGLE_API_KEY_1 \$GOOGLE_API_KEY_2 \$GOOGLE_API_KEY_3' < ${HERMES_HOME}/config.yaml.tpl > ${USER_CONFIG}"

log "Config synchronized for $username. Restarting service..."
pct exec "$ctid" -- systemctl restart "hermes-agent@$username"

log "Waiting for service to stabilize..."
sleep 5

if ! pct exec "$ctid" -- systemctl is-active --quiet "hermes-agent@$username"; then
  die "Service failed to start after config sync for $username in $ctid."
fi

log "Sync complete for $username in $ctid."
