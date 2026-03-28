#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"
require_cmd pct

usage() {
  cat <<'EOF'
Usage:
  bash scripts/cleanup.sh
  bash scripts/cleanup.sh <ctid> [<ctid> ...]
  bash scripts/cleanup.sh --file <path>

Stops and destroys the given containers. Without arguments, reads CTIDs from FAILED_CTIDS_FILE.
EOF
}

failed_file="$FAILED_CTIDS_FILE"
declare -a ctids=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      shift
      [ "$#" -gt 0 ] || die "Missing path after --file"
      failed_file="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      ctids+=("$1")
      ;;
  esac
  shift
done

if [ "${#ctids[@]}" -eq 0 ]; then
  failed_file="$(resolve_path "$failed_file")"
  require_file "$failed_file"
  while IFS= read -r ctid; do
    [ -z "$ctid" ] && continue
    ctids+=("$ctid")
  done < "$failed_file"
fi

for ctid in "${ctids[@]}"; do
  is_positive_integer "$ctid" || die "Invalid CTID: $ctid"
  if ! pct_exists "$ctid"; then
    continue
  fi

  if pct status "$ctid" 2>/dev/null | grep -q running; then
    run_cmd pct stop "$ctid"
  fi
  run_cmd pct destroy "$ctid" --purge
done

log "Cleanup finished."
