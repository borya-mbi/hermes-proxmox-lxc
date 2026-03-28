#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

proxy_hosts_file="${1:-$NPM_PROXY_HOSTS_FILE}"
proxy_hosts_file="$(resolve_path "$proxy_hosts_file")"
require_file "$proxy_hosts_file"

printf 'NPM LXC IP: %s\n' "$NPM_LXC_IP"
printf 'Recommended public forwards: %s:%s->NPM, %s:%s->NPM\n' "$HOST_PUBLIC_IP" "$NPM_HTTP_PORT" "$HOST_PUBLIC_IP" "$NPM_HTTPS_PORT"
printf '\n'
printf 'Domain\tScheme\tForward Host/IP\tForward Port\tWebsocket\tDescription\n'

while IFS=$'\t' read -r domain scheme target target_port websocket description; do
  [ -z "${domain:-}" ] && continue
  case "$domain" in
    \#*) continue ;;
  esac

  target_ip="$(resolve_target_ip "$target")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" \
    "$scheme" \
    "$target_ip" \
    "$target_port" \
    "$websocket" \
    "$description"
done < "$proxy_hosts_file"

printf '\n'
printf '# NPM setup checklist\n'
printf '1. Ensure public 80/443 DNAT to NPM LXC %s.\n' "$NPM_LXC_IP"
printf '2. In NPM create one Proxy Host per row from %s.\n' "$proxy_hosts_file"
printf '3. Enable Websockets Support where the table says true.\n'
printf '4. Request Lets Encrypt certificates in NPM after DNS points to %s.\n' "$HOST_PUBLIC_IP"
