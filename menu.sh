#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/compose.yml"
ENV_FILE="$ROOT_DIR/.env"
BACKUP_DIR="$ROOT_DIR/backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err() { echo -e "${RED}$*${NC}" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run this script as root."
    exit 1
  fi
}

require_apt() {
  if ! command -v apt >/dev/null 2>&1; then
    err "Only Debian/Ubuntu systems with apt are supported."
    exit 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq
  apt install -y -qq ca-certificates curl dnsutils iproute2 openssl
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker and Docker Compose are already installed."
    return
  fi

  warn "Docker is missing. Installing Docker using the official convenience script."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

prompt_required() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt" value
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    err "Value cannot be empty."
  done
}

prompt_secret() {
  local prompt="$1"
  local value
  while true; do
    read -r -s -p "$prompt" value
    echo
    if [[ ${#value} -ge 12 ]]; then
      printf '%s' "$value"
      return
    fi
    err "Use at least 12 characters."
  done
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

prompt_domain() {
  local prompt="$1"
  local value
  while true; do
    value="$(prompt_required "$prompt")"
    if valid_domain "$value"; then
      printf '%s' "$value"
      return
    fi
    err "Enter a valid domain, for example vpn.example.com."
  done
}

prompt_email() {
  local value
  while true; do
    value="$(prompt_required "Let's Encrypt email: ")"
    if [[ "$value" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      printf '%s' "$value"
      return
    fi
    err "Enter a valid email address."
  done
}

detect_public_ip() {
  local ip
  ip="$(curl -fsS4 --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s' "$ip"
    return
  fi
  return 1
}

random_port() {
  while true; do
    local port
    port="$(shuf -i 35000-45000 -n 1)"
    if ! ss -lun "( sport = :$port )" | grep -q ":$port"; then
      printf '%s' "$port"
      return
    fi
  done
}

random_cidr() {
  local second third
  second="$(shuf -i 16-31 -n 1)"
  third="$(shuf -i 0-255 -n 1)"
  printf '10.%s.%s.0/24' "$second" "$third"
}

cidr_to_wg_default_address() {
  local cidr="$1"
  printf '%s.x' "${cidr%.0/24}"
}

wg_easy_image() {
  if [[ -f "$ENV_FILE" ]]; then
    local image
    image="$(env_get WG_EASY_IMAGE)"
    if [[ -n "$image" ]]; then
      printf '%s' "$image"
      return
    fi
  fi
  printf 'ghcr.io/wg-easy/wg-easy:latest'
}

wg_password_hash() {
  local password="$1"
  local image="$2"
  local output hash
  output="$(docker run --rm "$image" wgpw "$password" 2>/dev/null || true)"
  hash="$(printf '%s\n' "$output" | sed -n "s/^PASSWORD_HASH='\(.*\)'/\1/p" | tail -n 1)"
  if [[ -z "$hash" ]]; then
    err "Could not generate wg-easy PASSWORD_HASH with image $image."
    return 1
  fi
  printf '%s' "$hash"
}

dotenv_value() {
  local value="$1"
  value="${value//$'\n'/}"
  value="${value//\'/\\\'}"
  printf "'%s'" "$value"
}

write_env() {
  local wg_domain="$1"
  local email="$2"
  local host="$3"
  local port="$4"
  local cidr="$5"
  local username="$6"
  local password="$7"
  local password_hash
  password_hash="$(wg_password_hash "$password" "ghcr.io/wg-easy/wg-easy:latest")"

  {
    echo "NGINX_PROXY_IMAGE=nginxproxy/nginx-proxy:latest"
    echo "ACME_COMPANION_IMAGE=nginxproxy/acme-companion:latest"
    echo "WG_EASY_IMAGE=ghcr.io/wg-easy/wg-easy:latest"
    echo "WG_UI_DOMAIN=$(dotenv_value "$wg_domain")"
    echo "WG_HOST=$(dotenv_value "$host")"
    echo "WG_PORT=$port"
    echo "WG_DNS=$(dotenv_value "1.1.1.1,8.8.8.8")"
    echo "WG_IPV4_CIDR=$(dotenv_value "$cidr")"
    echo "WG_DEFAULT_ADDRESS=$(dotenv_value "$(cidr_to_wg_default_address "$cidr")")"
    echo "WG_IPV6_CIDR=$(dotenv_value "fdcc:ad94:bacf:61a3::/64")"
    echo "WG_ALLOWED_IPS=$(dotenv_value "0.0.0.0/0")"
    echo "WG_DISABLE_IPV6=true"
    echo "WG_INIT_ENABLED=true"
    echo "WG_ADMIN_USERNAME=$(dotenv_value "$username")"
    echo "WG_ADMIN_PASSWORD=$(dotenv_value "$password")"
    echo "WG_PASSWORD_HASH=$(dotenv_value "$password_hash")"
    echo "LETSENCRYPT_EMAIL=$(dotenv_value "$email")"
    echo "BESZEL_IMAGE=henrygd/beszel:latest"
    echo "BESZEL_AGENT_IMAGE=henrygd/beszel-agent:latest"
    echo "BESZEL_DOMAIN="
    echo "BESZEL_AGENT_LISTEN=$(dotenv_value "/beszel_socket/beszel.sock")"
    echo "BESZEL_AGENT_TOKEN="
    echo "BESZEL_AGENT_KEY="
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

disable_wg_init_secret() {
  local tmp
  tmp="$(mktemp)"
  awk '
    /^WG_INIT_ENABLED=/ { print "WG_INIT_ENABLED=false"; next }
    /^WG_ADMIN_PASSWORD=/ { print "WG_ADMIN_PASSWORD="; next }
    { print }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

validate_compose() {
  compose config >/dev/null
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err ".env is missing. Run install first."
    return 1
  fi
}

env_get() {
  local key="$1"
  local line value
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  value="${line#*=}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

check_dns() {
  local domain="$1"
  local expected_ip="$2"
  local resolved
  resolved="$(dig +short A "$domain" | tail -n 1)"
  if [[ "$resolved" != "$expected_ip" ]]; then
    warn "$domain resolves to '${resolved:-nothing}', expected $expected_ip."
    warn "Let's Encrypt will fail until DNS points to this server."
    return 1
  fi
  info "$domain resolves to $expected_ip."
}

backup_state() {
  mkdir -p "$BACKUP_DIR"
  local stamp
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  local archive="$BACKUP_DIR/vpn-wg-$stamp.tar.gz"

  tar -czf "$archive" \
    --exclude='./backups' \
    -C "$ROOT_DIR" \
    .env compose.yml agent.yml 2>/dev/null || true

  info "Backup saved: $archive"
}

wait_for_service() {
  local name="$1"
  local seconds="${2:-120}"
  local end=$((SECONDS + seconds))

  while (( SECONDS < end )); do
    local state health
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)"
    if [[ "$state" == "running" && ( -z "$health" || "$health" == "healthy" ) ]]; then
      return 0
    fi
    sleep 3
  done

  err "$name did not become ready in ${seconds}s."
  docker logs "$name" --tail 80 2>/dev/null || true
  return 1
}

install_vpn() {
  require_root
  require_apt
  install_packages
  install_docker

  if [[ -f "$ENV_FILE" ]]; then
    warn ".env already exists."
    read -r -p "Overwrite configuration? Existing WireGuard data volume will be kept. Type yes: " answer
    [[ "$answer" == "yes" ]] || return
    backup_state
  fi

  local public_ip wg_domain email wg_host wg_port wg_cidr admin_user admin_pass
  public_ip="$(detect_public_ip || true)"
  if [[ -z "$public_ip" ]]; then
    public_ip="$(prompt_required "Public IPv4 address: ")"
  fi

  info "Detected public IPv4: $public_ip"
  wg_domain="$(prompt_domain "WireGuard web UI domain, for example vpn.example.com: ")"
  email="$(prompt_email)"
  admin_user="$(prompt_required "Initial WireGuard admin username: ")"
  admin_pass="$(prompt_secret "Initial WireGuard admin password, at least 12 chars: ")"
  wg_host="$wg_domain"
  wg_port="$(random_port)"
  wg_cidr="$(random_cidr)"

  check_dns "$wg_domain" "$public_ip" || return
  write_env "$wg_domain" "$email" "$wg_host" "$wg_port" "$wg_cidr" "$admin_user" "$admin_pass"
  validate_compose

  info "Starting VPN stack..."
  compose up -d nginx-proxy acme-companion wg-easy
  wait_for_service nginx-proxy 120
  wait_for_service wg-easy 180

  disable_wg_init_secret
  compose up -d --no-deps wg-easy
  wait_for_service wg-easy 180

  info "Installation complete."
  echo "WireGuard UI: https://$wg_domain"
  echo "WireGuard UDP port: $wg_port"
  echo "Admin username: $admin_user"
  warn "Open UDP $wg_port in your VPS provider firewall if it is not open automatically."
}

status() {
  load_env || return
  validate_compose
  compose ps
  echo
  echo "WireGuard UI: https://$(env_get WG_UI_DOMAIN)"
  echo "WireGuard UDP port: $(env_get WG_PORT)"
}

update_stack() {
  require_root
  load_env || return
  backup_state
  validate_compose
  compose pull
  compose up -d
  info "Update complete."
}

reset_wg_password() {
  require_root
  load_env || return
  local password password_hash tmp
  password="$(prompt_secret "New WireGuard admin password, at least 12 chars: ")"
  password_hash="$(wg_password_hash "$password" "$(wg_easy_image)")"
  tmp="$(mktemp)"
  awk -v hash="$password_hash" '
    BEGIN { found = 0 }
    /^WG_PASSWORD_HASH=/ { print "WG_PASSWORD_HASH='\''" hash "'\''"; found = 1; next }
    { print }
    END {
      if (found == 0) {
        print "WG_PASSWORD_HASH='\''" hash "'\''"
      }
    }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  compose up -d --force-recreate wg-easy
  info "WireGuard admin password hash was updated and wg-easy was recreated."
}

print_menu() {
  echo
  echo "WireGuard VPN deployment"
  echo
  echo "1. Install or reconfigure VPN"
  echo "2. Show status"
  echo "3. Backup local config"
  echo "4. Pull pinned images and restart"
  echo "5. Reset WireGuard admin password"
  echo "6. Exit"
}

main() {
  cd "$ROOT_DIR"
  while true; do
    print_menu
    read -r -p "Enter number (1-6): " choice
    case "$choice" in
      1) install_vpn ;;
      2) status ;;
      3) backup_state ;;
      4) update_stack ;;
      5) reset_wg_password ;;
      6) exit 0 ;;
      *) err "Unknown option." ;;
    esac
  done
}

main "$@"
