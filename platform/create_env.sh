#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
TTL="${2:-1800}"

if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <name> [ttl_seconds]" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENVS_DIR="$ROOT_DIR/envs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"
LOGS_DIR="$ROOT_DIR/logs"

mkdir -p "$ENVS_DIR" "$NGINX_CONF_DIR"

ENV_ID="env-$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')-$(date +%s | tail -c 6)"
NETWORK="${ENV_ID}-net"
PORT=$(shuf -i 4000-9000 -n 1)
CREATED_AT=$(date -u +%s)
STATE_FILE="$ENVS_DIR/${ENV_ID}.json"
LOG_DIR="$LOGS_DIR/$ENV_ID"

mkdir -p "$LOG_DIR"

echo "[create] Starting env $ENV_ID (name=$NAME, ttl=${TTL}s, port=$PORT)"

# Create dedicated Docker network
docker network create "$NETWORK" >/dev/null

# Start app container
docker run -d \
  --name "$ENV_ID" \
  --network "$NETWORK" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$NAME" \
  -e "ENV_ID=$ENV_ID" \
  -p "${PORT}:3000" \
  sandbox-demo-app >/dev/null

# Write Nginx config
cat > "$NGINX_CONF_DIR/${ENV_ID}.conf" <<EOF
upstream ${ENV_ID}_upstream {
    server host.docker.internal:${PORT};
}
server {
    listen 80;
    server_name ${ENV_ID}.sandbox.local;
    location / {
        proxy_pass http://${ENV_ID}_upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Env-ID ${ENV_ID};
    }
}
EOF

# Reload Nginx
docker exec sandbox-nginx nginx -s reload 2>/dev/null || true

# Start log shipping (Approach A)
docker logs -f "$ENV_ID" >> "$LOG_DIR/app.log" 2>&1 &
LOG_PID=$!

# Write state file atomically
TEMP_FILE=$(mktemp)
cat > "$TEMP_FILE" <<EOF
{
  "id": "$ENV_ID",
  "name": "$NAME",
  "created_at": $CREATED_AT,
  "ttl": $TTL,
  "port": $PORT,
  "network": "$NETWORK",
  "log_pid": $LOG_PID,
  "status": "running"
}
EOF
mv "$TEMP_FILE" "$STATE_FILE"

echo "[create] ENV_ID=$ENV_ID"
echo "[create] URL=http://${ENV_ID}.sandbox.local (or http://localhost:${PORT})"
echo "[create] TTL=${TTL}s (expires at $(date -u -d "@$((CREATED_AT + TTL))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$((CREATED_AT + TTL))" '+%Y-%m-%dT%H:%M:%SZ'))"
