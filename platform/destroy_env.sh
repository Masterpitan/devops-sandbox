#!/usr/bin/env bash
set -euo pipefail

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env_id>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$ROOT_DIR/envs/${ENV_ID}.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[destroy] State file not found: $STATE_FILE" >&2
  exit 1
fi

LOG_PID=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('log_pid',''))" 2>/dev/null || true)
NETWORK=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('network',''))" 2>/dev/null || true)

echo "[destroy] Stopping env $ENV_ID"

# Kill log shipping process
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" 2>/dev/null; then
  kill "$LOG_PID" 2>/dev/null || true
fi

# Stop and remove labeled containers
docker ps -aq --filter "label=sandbox.env=$ENV_ID" | xargs -r docker rm -f 2>/dev/null || true

# Remove Docker network
if [[ -n "$NETWORK" ]]; then
  docker network rm "$NETWORK" 2>/dev/null || true
fi

# Remove Nginx config and reload
NGINX_CONF="$ROOT_DIR/nginx/conf.d/${ENV_ID}.conf"
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  docker exec sandbox-nginx nginx -s reload 2>/dev/null || true
fi

# Archive logs
LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
ARCHIVE_DIR="$ROOT_DIR/logs/archived/$ENV_ID"
if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$ROOT_DIR/logs/archived"
  mv "$LOG_DIR" "$ARCHIVE_DIR"
fi

# Delete state file
rm -f "$STATE_FILE"

echo "[destroy] Env $ENV_ID destroyed. Logs archived to logs/archived/$ENV_ID/"
