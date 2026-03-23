#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"
target_ctid="${1:-$START_CTID}"

# Pre-deployment validation
require_nonempty_file "$APP_ENV_FILE"
require_file "$SYSTEMD_TEMPLATE_FILE"
warn_if_placeholder "${HERMES_REPO_URL:-}" "HERMES_REPO_URL still points to a placeholder."

bash "$SCRIPT_DIR/deploy_hermes.sh" 1 "$target_ctid"

# Automatic health-check
if is_dry_run; then
    log "[DRY_RUN] Skipping health-check."
else
    log "Waiting 5s for service initialization..."
    sleep 5
    bash "$SCRIPT_DIR/health_check.sh" "$target_ctid" 1 --http
fi

