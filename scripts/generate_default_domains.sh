#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_lxc_env "${HERMES_LXC_ENV:-}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/generate_default_domains.sh
  bash scripts/generate_default_domains.sh --append <ctid> [<ctid> ...]
  bash scripts/generate_default_domains.sh --file <path>

Режим за замовчуванням перезаписує файл для діапазону
START_CTID..START_CTID+COUNT-1 і лишає PRIMARY_PUBLIC_DOMAIN
прив'язаним до PORTAL_CTID. Файл генерується з урахуванням усіх користувачів
(HERMES_PROD_USERS, HERMES_DEV_USERS) для кожного контейнера.
Режим --append оновлює або додає записи для вказаних CTID.
EOF
}

emit_header() {
  printf '# domain\t scheme\t target\t target_port\t websocket\t description\n'
}

emit_primary_line() {
  printf '%s\thttp\t%s\t%s\ttrue\tГоловний портал Hermes\n' \
    "$PRIMARY_PUBLIC_DOMAIN" \
    "$PORTAL_CTID" \
    "80"
}

emit_agent_line() {
  local ctid="$1"
  local user="$2"
  local port
  port=$(get_user_port "$user" "$HERMES_BASE_PORT")
  
  printf '%s-%s-%s.%s\thttp\t%s\t%s\ttrue\tЧат Hermes для %s у CT %s\n' \
    "$user" \
    "$AGENT_DOMAIN_PREFIX" \
    "$ctid" \
    "$BASE_DOMAIN" \
    "$ctid" \
    "$port" \
    "$user" \
    "$ctid"
}

emit_admin_line() {
  local ctid="$1"
  local user="$2"
  local port
  port=$(get_user_port "$user" "$HERMES_ADMIN_BASE_PORT")

  printf '%s-%s-%s.%s\thttp\t%s\t%s\ttrue\tАдмінка Hermes для %s у CT %s\n' \
    "$user" \
    "$ADMIN_DOMAIN_PREFIX" \
    "$ctid" \
    "$BASE_DOMAIN" \
    "$ctid" \
    "$port" \
    "$user" \
    "$ctid"
}

emit_optional_npm_line() {
  printf '# %s\thttp\tnpm\t%s\tfalse\tАдмін-панель NPM (опційно)\n' "$NPM_ADMIN_DOMAIN" "$NPM_ADMIN_PORT"
}

ensure_header() {
  if [ ! -f "$target_file" ] || [ ! -s "$target_file" ]; then
    emit_header > "$target_file"
    return
  fi

  if ! grep -Fq '# domain' "$target_file"; then
    tmp_file="$(mktemp)"
    emit_header > "$tmp_file"
    cat "$target_file" >> "$tmp_file"
    mv "$tmp_file" "$target_file"
  fi
}

upsert_domain_line() {
  local domain="$1"
  local line="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -F '\t' -v domain="$domain" '
    BEGIN { OFS = "\t" }
    /^#/ { print; next }
    $1 != domain { print }
  ' "$target_file" > "$tmp_file"
  printf '%s\n' "$line" >> "$tmp_file"
  mv "$tmp_file" "$target_file"
}

ensure_optional_npm_comment() {
  if ! grep -Fq "# $NPM_ADMIN_DOMAIN" "$target_file"; then
    printf '%s\n' "$(emit_optional_npm_line)" >> "$target_file"
  fi
}

strip_optional_npm_comment() {
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v domain="$NPM_ADMIN_DOMAIN" '
    index($0, "# " domain "\t") == 1 { next }
    { print }
  ' "$target_file" > "$tmp_file"
  mv "$tmp_file" "$target_file"
}

mode="rewrite"
target_file="$NPM_PROXY_HOSTS_FILE"
declare -a ctids=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --append)
      mode="append"
      ;;
    --file)
      shift
      [ "$#" -gt 0 ] || die "Missing path after --file"
      target_file="$1"
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

target_file="$(resolve_path "$target_file")"
ensure_parent_dir "$target_file"

if [ "${#ctids[@]}" -eq 0 ]; then
  for offset in $(seq 0 $((COUNT - 1))); do
    ctids+=("$((START_CTID + offset))")
  done
fi

case "$mode" in
  rewrite)
    {
      emit_header
      emit_primary_line
      for ctid in "${ctids[@]}"; do
        for user in $(all_hermes_users); do
          emit_agent_line "$ctid" "$user"
          emit_admin_line "$ctid" "$user"
        done
      done
      emit_optional_npm_line
    } > "$target_file"
    printf 'Перезаписано чернетку Proxy Host для NPM: %s\n' "$target_file"
    ;;
  append)
    ensure_header
    strip_optional_npm_comment
    upsert_domain_line "$PRIMARY_PUBLIC_DOMAIN" "$(emit_primary_line)"
    for ctid in "${ctids[@]}"; do
      for user in $(all_hermes_users); do
        upsert_domain_line "${user}-${AGENT_DOMAIN_PREFIX}-${ctid}.${BASE_DOMAIN}" "$(emit_agent_line "$ctid" "$user")"
        upsert_domain_line "${user}-${ADMIN_DOMAIN_PREFIX}-${ctid}.${BASE_DOMAIN}" "$(emit_admin_line "$ctid" "$user")"
      done
    done
    ensure_optional_npm_comment
    printf 'Оновлено або додано записи Proxy Host у: %s\n' "$target_file"
    ;;
  *)
    die "Unsupported mode: $mode"
    ;;
esac
