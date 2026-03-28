#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

notes_file="${1:-$NOTES_FILE}"
notes_file="$(resolve_path "$notes_file")"

if [ ! -f "$notes_file" ]; then
  warn "Notes file not found, skipping: $notes_file"
  exit 0
fi

while IFS=$'\t' read -r ctid description; do
  [ -z "${ctid:-}" ] && continue
  case "$ctid" in
    \#*) continue ;;
  esac

  if is_dry_run; then
    printf '[DRY-RUN] pct set %s -description %q\n' "$ctid" "$description"
    continue
  fi

  pct set "$ctid" -description "$description"
done < "$notes_file"

log "Container notes updated."

