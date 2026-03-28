#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

port_forward_file="${1:-$PORT_FORWARD_FILE}"
port_forward_file="$(resolve_path "$port_forward_file")"
require_file "$port_forward_file"

printf '# Add the lines below into /etc/network/interfaces under %s\n' "$BRIDGE"
printf '# Host public IP: %s\n' "${HOST_PUBLIC_IP:-replace-me}"
printf '# Private subnet: %s\n' "${PRIVATE_SUBNET_CIDR:-"${STATIC_IP_PREFIX}.0/${PRIVATE_PREFIX_LENGTH}"}"
printf 'post-up sysctl -w net.ipv4.ip_forward=1\n'
printf "post-up iptables -t nat -A POSTROUTING -s '%s' -o %s -j MASQUERADE\n" \
  "${PRIVATE_SUBNET_CIDR:-"${STATIC_IP_PREFIX}.0/${PRIVATE_PREFIX_LENGTH}"}" \
  "${HOST_WAN_IF:-vmbr0}"
printf "post-down iptables -t nat -D POSTROUTING -s '%s' -o %s -j MASQUERADE\n" \
  "${PRIVATE_SUBNET_CIDR:-"${STATIC_IP_PREFIX}.0/${PRIVATE_PREFIX_LENGTH}"}" \
  "${HOST_WAN_IF:-vmbr0}"
printf "post-up iptables -A FORWARD -i %s -o %s -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT\n" \
  "$BRIDGE" \
  "${HOST_WAN_IF:-vmbr0}"
printf "post-up iptables -A FORWARD -i %s -o %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n" \
  "${HOST_WAN_IF:-vmbr0}" \
  "$BRIDGE"
printf "post-down iptables -D FORWARD -i %s -o %s -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT\n" \
  "$BRIDGE" \
  "${HOST_WAN_IF:-vmbr0}"
printf "post-down iptables -D FORWARD -i %s -o %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n" \
  "${HOST_WAN_IF:-vmbr0}" \
  "$BRIDGE"

while IFS=$'\t' read -r public_port proto target private_port description; do
  [ -z "${public_port:-}" ] && continue
  case "$public_port" in
    \#*) continue ;;
  esac

  target_ip="$(resolve_target_ip "$target")"
  printf "post-up iptables -t nat -A PREROUTING -i %s -p %s -d %s --dport %s -j DNAT --to-destination %s:%s\n" \
    "${HOST_WAN_IF:-vmbr0}" \
    "$proto" \
    "${HOST_PUBLIC_IP:-replace-me}" \
    "$public_port" \
    "$target_ip" \
    "$private_port"
  printf "post-up iptables -A FORWARD -i %s -o %s -p %s -d %s --dport %s -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT\n" \
    "${HOST_WAN_IF:-vmbr0}" \
    "$BRIDGE" \
    "$proto" \
    "$target_ip" \
    "$private_port"
  printf "post-down iptables -t nat -D PREROUTING -i %s -p %s -d %s --dport %s -j DNAT --to-destination %s:%s\n" \
    "${HOST_WAN_IF:-vmbr0}" \
    "$proto" \
    "${HOST_PUBLIC_IP:-replace-me}" \
    "$public_port" \
    "$target_ip" \
    "$private_port"
  printf "post-down iptables -D FORWARD -i %s -o %s -p %s -d %s --dport %s -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT\n" \
    "${HOST_WAN_IF:-vmbr0}" \
    "$BRIDGE" \
    "$proto" \
    "$target_ip" \
    "$private_port"
  printf '# %s -> %s:%s\n' "$description" "$target_ip" "$private_port"
done < "$port_forward_file"
