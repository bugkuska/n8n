#!/usr/bin/env bash
set -euo pipefail

# 1) ดึง URL ปัจจุบันจาก ngrok API (มี fallback จาก logs)
PUB_URL="$(curl -s --max-time 2 http://127.0.0.1:4040/api/tunnels \
  | grep -o '"public_url":"https:[^"]*' | cut -d'"' -f4 | head -n1 || true)"

if [[ -z "$PUB_URL" ]]; then
  PUB_URL="$(docker logs ngrok 2>&1 \
    | sed -nE 's#.*(https://[a-z0-9-]+\.ngrok(-free)?\.app).*#\1#p' \
    | tail -n1 || true)"
fi

if [[ -z "$PUB_URL" ]]; then
  echo "❌ ไม่เจอ ngrok URL (ngrok อาจยังไม่รัน)" >&2
  exit 1
fi

echo "==> ngrok URL ปัจจุบัน: $PUB_URL"

# 2) อัปเดตค่าใน /root/n8n/.env
ENV_FILE="/root/n8n/.env"
mkdir -p /root/n8n
touch "$ENV_FILE"
sed -i '/^WEBHOOK_URL=/d;/^N8N_HOST=/d;/^N8N_PROTOCOL=/d' "$ENV_FILE"
{
  echo "WEBHOOK_URL=$PUB_URL"
  echo "N8N_HOST=${PUB_URL#https://}"
  echo "N8N_PROTOCOL=https"
} >> "$ENV_FILE"

# 3) restart n8n (ถ้ามี docker-compose.yml)
cd /root/n8n
if [[ -f docker-compose.yml ]]; then
  docker compose up -d
fi

echo "✅ อัปเดต WEBHOOK_URL แล้ว"

# 4) เพิ่มคำสั่งสั้นๆ 'whurl' ไว้ดูค่า WEBHOOK_URL ได้ตลอด
cat >/usr/local/bin/whurl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# ลองอ่านจากคอนเทนเนอร์ก่อน
if docker ps --format '{{.Names}}' | grep -qx n8n 2>/dev/null; then
  docker exec n8n printenv WEBHOOK_URL 2>/dev/null && exit 0
fi
# ถ้าไม่ได้ ให้ fallback ไปอ่านจาก .env
if [[ -f /root/n8n/.env ]]; then
  awk -F= '$1=="WEBHOOK_URL"{print $2}' /root/n8n/.env
fi
EOF
chmod +x /usr/local/bin/whurl

echo
echo "ใช้คำสั่งสั้นๆ ได้แล้ว:  whurl"
echo "ค่าปัจจุบัน: $(/usr/local/bin/whurl)"
