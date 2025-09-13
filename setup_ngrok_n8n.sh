#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# setup_n8n.sh  (with Docker DNS fix + get-ngrok-url.sh + alias ngurl + auto WEBHOOK_URL)
#   Usage:
#     bash setup_n8n.sh --authtoken "NGROK_TOKEN"
#     bash setup_n8n.sh --authtoken "NGROK_TOKEN" --hostname "yourname.ngrok.app"
# ------------------------------------------------------------

# ===== Parse args =====
NGROK_AUTHTOKEN=""
NGROK_HOSTNAME=""   # optional

while [[ $# -gt 0 ]]; do
  case "$1" in
    --authtoken) NGROK_AUTHTOKEN="${2:-}"; shift 2 ;;
    --hostname)  NGROK_HOSTNAME="${2:-}";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$NGROK_AUTHTOKEN" ]]; then
  echo "ERROR: Please provide --authtoken \"YOUR_NGROK_TOKEN\""; exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run as root."; exit 1
fi

echo "==> Step 0: Clean old containers (if any)"
docker rm -f n8n ngrok watchtower >/dev/null 2>&1 || true

echo "==> Step 1: Install Docker Engine + Compose plugin"
apt update -y
apt install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings || true
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "==> Step 1b: Configure Docker daemon DNS (global)"
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

echo "==> Step 3: Create .env"
cat >/root/n8n/.env <<EOF
TZ=Asia/Bangkok
GENERIC_TIMEZONE=Asia/Bangkok
NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN}
EOF

echo "==> Step 4: Create docker-compose.yml"
if [[ -n "$NGROK_HOSTNAME" ]]; then
  NGROK_CMD='["http","--authtoken","${NGROK_AUTHTOKEN}","--region","ap","--log","stdout","--hostname","'${NGROK_HOSTNAME}'","http://n8n:5678"]'
else
  NGROK_CMD='["http","--authtoken","${NGROK_AUTHTOKEN}","--region","ap","--log","stdout","http://n8n:5678"]'
fi

cat >/root/n8n/docker-compose.yml <<YAML
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - N8N_SECURE_COOKIE=false
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
    volumes:
      - ./local:/home/node/.n8n
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - com.centurylinklabs.watchtower.enable=true

  ngrok:
    image: ngrok/ngrok:alpine
    container_name: ngrok
    restart: unless-stopped
    depends_on:
      - n8n
    command: ${NGROK_CMD}
    environment: []
    ports:
      - "4040:4040"
    labels:
      - com.centurylinklabs.watchtower.enable=true

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      - TZ=\${TZ}
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_ROLLING_RESTART=true
      - WATCHTOWER_LABEL_ENABLE=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
YAML

echo "==> Step 5: Pull & Up"
cd /root/n8n
docker compose pull
docker compose up -d

# ---- Helper script + alias ----
echo "==> Step 6: Install /root/get-ngrok-url.sh + alias ngurl"
cat >/root/get-ngrok-url.sh <<'EOS'
#!/usr/bin/env bash
# get-ngrok-url.sh — print current ngrok URL (API first, then logs)
set -euo pipefail

if ! docker ps -a --format '{{.Names}}' | grep -qx ngrok; then
  echo "❌ ไม่พบคอนเทนเนอร์ชื่อ 'ngrok'"; exit 1
fi

if ! docker ps --format '{{.Names}} {{.Status}}' | grep -q '^ngrok .*Up'; then
  echo "❌ 'ngrok' ยังไม่ขึ้น (สถานะไม่ใช่ Up). ดู log ด้วย: docker logs -f ngrok"; exit 1
fi

URL="$(curl -s --max-time 2 http://127.0.0.1:4040/api/tunnels \
  | grep -o '"public_url":"https:[^"]*' | cut -d'"' -f4 || true)"

if [[ -z "${URL}" ]]; then
  URL="$(docker logs ngrok 2>&1 \
    | grep -Eo 'https://[a-z0-9-]+\.ngrok(-free)?\.app' \
    | tail -n1 || true)"
fi

if [[ -n "${URL}" ]]; then
  echo "Current ngrok URL:"
  echo "  ${URL}"
  echo
  echo "OAuth Redirect URI:"
  echo "  ${URL}/rest/oauth2-credential/callback"
else
  echo "❌ ไม่พบ ngrok URL (อาจยังไม่สร้าง tunnel)"
fi
EOS
chmod +x /root/get-ngrok-url.sh

if ! grep -q "alias ngurl=" /root/.bashrc 2>/dev/null; then
  echo "alias ngurl='/root/get-ngrok-url.sh'" >> /root/.bashrc
fi

echo "==> Waiting ngrok to expose public URL ..."
for i in {1..30}; do
  PUB_URL="$(curl -s http://127.0.0.1:4040/api/tunnels \
    | grep -o '"public_url":"https:[^"]*' \
    | cut -d'"' -f4 || true)"
  [[ -n "$PUB_URL" ]] && break
  sleep 1
done

# ===== NEW: Apply WEBHOOK_URL =====
if [[ -n "${PUB_URL:-}" ]]; then
  echo "==> Applying WEBHOOK_URL into .env and docker-compose.yml ..."
  sed -i '/^WEBHOOK_URL=/d' /root/n8n/.env
  echo "WEBHOOK_URL=${PUB_URL}" >> /root/n8n/.env

  sed -i '/^- WEBHOOK_URL=/d' /root/n8n/docker-compose.yml
  sed -i '/N8N_PROTOCOL=http/a\      - WEBHOOK_URL=\${WEBHOOK_URL}' /root/n8n/docker-compose.yml

  cd /root/n8n && docker compose up -d
fi

echo
echo "================= SUMMARY ================="
docker compose ps
echo

if [[ -n "${PUB_URL:-}" ]]; then
  echo "Public URL (ngrok): $PUB_URL"
else
  echo "WARNING: ยังดึง public URL ไม่ได้ ณ ตอนนี้"
  echo "  ลองสั่ง: ngurl"
fi

if [[ -n "$NGROK_HOSTNAME" ]]; then
  REDIRECT_URI="https://${NGROK_HOSTNAME}/rest/oauth2-credential/callback"
elif [[ -n "${PUB_URL:-}" ]]; then
  REDIRECT_URI="${PUB_URL}/rest/oauth2-credential/callback"
else
  REDIRECT_URI="(ยังไม่ทราบ: รัน ngurl แล้วนำ URL + /rest/oauth2-credential/callback ไปใช้)"
fi

echo "OAuth Redirect URI:"
echo "  ${REDIRECT_URI}"
echo "==========================================="
echo "Files:"
echo "  /root/n8n/.env"
echo "  /root/n8n/docker-compose.yml"
echo "  /root/get-ngrok-url.sh  (alias: ngurl)"
echo
echo "Useful commands:"
echo "  ngurl"
echo "  cd /root/n8n && docker compose logs -f ngrok"
echo "  cd /root/n8n && docker compose restart n8n ngrok"
echo "  tar -C /root -czf /root/n8n-backup-\$(date +%F).tar.gz n8n/local"
echo "==========================================="
