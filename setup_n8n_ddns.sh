#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------
# setup_n8n_ddns.sh  (v2, fixed binding)
#   Install Docker + run n8n on a home server (e.g., Raspberry Pi)
#   exposed to Internet via DDNS + router port-forward.
#
# KEY FIX:
#   - n8n ALWAYS binds internally on 0.0.0.0:5678
#   - External URL generation uses WEBHOOK_URL + N8N_EDITOR_BASE_URL
#     (http://<host>:<ext_port> in HTTP mode, https://<host> in HTTPS mode)
#
# Modes:
#   - HTTP  : external port (e.g., 5555) forwarded -> host:5678
#   - HTTPS : domain on 443/80 via Caddy (Let's Encrypt)
#
# Usage examples:
#   # HTTP mode (external 5555 -> internal 5678)
#   sudo bash setup_n8n_ddns.sh --host ddns.host.net --mode http --external-port 5555
#
#   # HTTPS mode (recommended for OAuth)
#   sudo bash setup_n8n_ddns.sh --host ddns.host.net --mode https --email you@example.com
#
# Optional flags:
#   --basic-user <user>     Enable n8n basic auth with this username
#   --basic-pass <pass>     Basic auth password (choose a strong one)
#   --timezone  <TZ>        Default: Asia/Bangkok
#
# Router / Port-Forwarding examples:
#   - HTTP : WAN:5555/TCP -> LAN:192.168.1.x:5678
#   - HTTPS: WAN:80/TCP, WAN:443/TCP -> LAN:192.168.1.x:80/443
#
# Files created:
#   /root/n8n/.env
#   /root/n8n/docker-compose.yml
#   /root/n8n/Caddyfile   (HTTPS mode only)
# ---------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run as root (use sudo)." >&2; exit 1
fi

HOST_VALUE=""
MODE="http"
EXT_PORT="5555"
ACME_EMAIL=""
TIMEZONE="Asia/Bangkok"
BASIC_USER=""
BASIC_PASS=""

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)          HOST_VALUE="${2:-}"; shift 2 ;;
    --mode)          MODE="${2:-}"; shift 2 ;;
    --external-port) EXT_PORT="${2:-}"; shift 2 ;;
    --email)         ACME_EMAIL="${2:-}"; shift 2 ;;
    --timezone)      TIMEZONE="${2:-}"; shift 2 ;;
    --basic-user)    BASIC_USER="${2:-}"; shift 2 ;;
    --basic-pass)    BASIC_PASS="${2:-}"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$HOST_VALUE" ]]; then
  echo "ERROR: --host is required (DDNS hostname or public IP)." >&2; exit 1
fi
if [[ "$MODE" != "http" && "$MODE" != "https" ]]; then
  echo "ERROR: --mode must be 'http' or 'https'." >&2; exit 1
fi

USE_HTTPS=0
[[ "$MODE" == "https" ]] && USE_HTTPS=1

echo "==> Step 0: Clean old containers (if any)"
docker rm -f n8n watchtower caddy >/dev/null 2>&1 || true

echo "==> Step 1: Install Docker Engine + Compose plugin"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings || true
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "==> Step 1b: (Optional) Configure Docker daemon DNS (Google & Cloudflare)"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "dns": ["8.8.8.8", "1.1.1.1"]
}
EOF
systemctl restart docker

echo "==> Step 2: Prepare project folders"
mkdir -p /root/n8n/local
chown -R 1000:1000 /root/n8n/local

echo "==> Step 3: Generate .env (fixed internal bind to 0.0.0.0:5678)"
INTERNAL_PORT=5678
if [[ $USE_HTTPS -eq 1 ]]; then
  EXTERNAL_BASE="https://${HOST_VALUE}"
else
  EXTERNAL_BASE="http://${HOST_VALUE}:${EXT_PORT}"
fi

cat >/root/n8n/.env <<EOF
TZ=${TIMEZONE}
GENERIC_TIMEZONE=${TIMEZONE}
# Internal binding (DO NOT CHANGE)
N8N_HOST=0.0.0.0
N8N_PORT=${INTERNAL_PORT}
N8N_PROTOCOL=http
N8N_SECURE_COOKIE=false

# External URLs for link generation
WEBHOOK_URL=${EXTERNAL_BASE}
N8N_EDITOR_BASE_URL=${EXTERNAL_BASE}
EOF

# Optional Basic Auth
if [[ -n "$BASIC_USER" && -n "$BASIC_PASS" ]]; then
  cat >>/root/n8n/.env <<EOF
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=${BASIC_USER}
N8N_BASIC_AUTH_PASSWORD=${BASIC_PASS}
EOF
fi

echo "==> Step 4: Create docker-compose.yml"
if [[ $USE_HTTPS -eq 1 ]]; then
  # With Caddy reverse proxy for HTTPS
  cat >/root/n8n/docker-compose.yml <<'YAML'
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - TZ=${TZ}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_SECURE_COOKIE=false
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}
      - N8N_BASIC_AUTH_ACTIVE=${N8N_BASIC_AUTH_ACTIVE:-false}
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER:-}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD:-}
    volumes:
      - ./local:/home/node/.n8n
    expose:
      - "5678"
    labels:
      - com.centurylinklabs.watchtower.enable=true

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    labels:
      - com.centurylinklabs.watchtower.enable=true

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      - TZ=${TZ}
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_LABEL_ENABLE=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  caddy_data:
  caddy_config:
YAML

  echo "==> Step 4b: Create Caddyfile"
  cat >/root/n8n/Caddyfile <<EOF
${HOST_VALUE} {
  encode zstd gzip
  $( [[ -n "$ACME_EMAIL" ]] && echo "email ${ACME_EMAIL}" )
  reverse_proxy n8n:5678
}
EOF

else
  # Plain HTTP local port 5678 (external port-forward handled by router)
  cat >/root/n8n/docker-compose.yml <<'YAML'
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - TZ=${TZ}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_SECURE_COOKIE=false
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}
      - N8N_BASIC_AUTH_ACTIVE=${N8N_BASIC_AUTH_ACTIVE:-false}
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER:-}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD:-}
    volumes:
      - ./local:/home/node/.n8n
    ports:
      - "5678:5678"
    labels:
      - com.centurylinklabs.watchtower.enable=true

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      - TZ=${TZ}
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_LABEL_ENABLE=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
YAML
fi

# ---- UFW (if available) ----
if command -v ufw >/dev/null 2>&1; then
  echo "==> Step 5: Configure UFW rules (if ufw is active)"
  if ufw status | grep -q "Status: active"; then
    if [[ $USE_HTTPS -eq 1 ]]; then
      ufw allow 80/tcp || true
      ufw allow 443/tcp || true
    else
      ufw allow 5678/tcp || true
    fi
  fi
fi

echo "==> Step 6: Pull & start containers"
cd /root/n8n
docker compose pull
docker compose up -d

echo
echo "================= SUMMARY ================="
docker compose ps
echo

if [[ $USE_HTTPS -eq 1 ]]; then
  echo "Base URL       : https://${HOST_VALUE}"
  echo "OAuth Redirect : https://${HOST_VALUE}/rest/oauth2-credential/callback"
  echo "Note           : Ensure router forwards 80 & 443 to this host."
else
  echo "Base URL       : http://${HOST_VALUE}:${EXT_PORT}"
  echo "OAuth Redirect : http://${HOST_VALUE}:${EXT_PORT}/rest/oauth2-credential/callback"
  echo "Note           : Ensure router forwards ${EXT_PORT} -> 5678 to this host."
fi

echo
echo "Files:"
echo "  /root/n8n/.env"
echo "  /root/n8n/docker-compose.yml"
[[ $USE_HTTPS -eq 1 ]] && echo "  /root/n8n/Caddyfile"
echo
echo "Commands:"
echo "  cd /root/n8n && docker compose logs -f"
echo "  cd /root/n8n && docker compose restart n8n"
[[ $USE_HTTPS -eq 1 ]] && echo "  cd /root/n8n && docker compose restart caddy"
echo "  docker exec -it n8n env | grep -E 'N8N_HOST|N8N_PORT|N8N_PROTOCOL|WEBHOOK_URL|N8N_EDITOR_BASE_URL'"
echo "==========================================="
