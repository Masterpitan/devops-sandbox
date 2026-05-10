#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENVS_DIR="$ROOT_DIR/envs"
LOG_FILE="$ROOT_DIR/logs/cleanup.log"

mkdir -p "$ROOT_DIR/logs"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

log "Cleanup daemon started (PID=$$)"

while true; do
  NOW=$(date -u +%s)

  for STATE_FILE in "$ENVS_DIR"/*.json; do
    [[ -f "$STATE_FILE" ]] || continue

    ENV_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['id'])" 2>/dev/null) || continue
    CREATED_AT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['created_at'])" 2>/dev/null) || continue
    TTL=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['ttl'])" 2>/dev/null) || continue

    EXPIRES_AT=$((CREATED_AT + TTL))

    if [[ "$NOW" -gt "$EXPIRES_AT" ]]; then
      log "TTL expired for $ENV_ID — destroying"
      bash "$ROOT_DIR/platform/destroy_env.sh" "$ENV_ID" >> "$LOG_FILE" 2>&1 && \
        log "Destroyed $ENV_ID successfully" || \
        log "ERROR: Failed to destroy $ENV_ID"
    fi
  done

  sleep 60
done
