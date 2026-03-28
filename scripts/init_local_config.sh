#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

copy_if_missing() {
  local source_file="$1"
  local target_file="$2"

  if [ -f "$target_file" ]; then
    log "Skipping existing file: $target_file"
    return 0
  fi

  cp "$source_file" "$target_file"
  log "Created draft file: $target_file"
}

copy_if_missing "$PROJECT_ROOT/deploy/hermes-lxc.env.example" "$PROJECT_ROOT/deploy/hermes-lxc.env"
copy_if_missing "$PROJECT_ROOT/deploy/hermes-user.env.example" "$PROJECT_ROOT/deploy/hermes-user.env"
copy_if_missing "$PROJECT_ROOT/deploy/config.yaml.example" "$PROJECT_ROOT/deploy/config.yaml"

copy_if_missing "$PROJECT_ROOT/deploy/port-forwards.tsv.example" "$PROJECT_ROOT/deploy/port-forwards.tsv"
copy_if_missing "$PROJECT_ROOT/deploy/npm-proxy-hosts.tsv.example" "$PROJECT_ROOT/deploy/npm-proxy-hosts.tsv"
copy_if_missing "$PROJECT_ROOT/deploy/container-notes.tsv.example" "$PROJECT_ROOT/deploy/container-notes.tsv"
copy_if_missing "$PROJECT_ROOT/deploy/authorized_keys.example" "$PROJECT_ROOT/deploy/authorized_keys"

log "Local draft files are ready."
