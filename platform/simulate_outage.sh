#!/usr/bin/env bash
set -euo pipefail

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$ROOT_DIR/envs/${ENV_ID}.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[simulate] State file not found for $ENV_ID" >&2
  exit 1
fi

# Guard: never simulate against platform containers
CONTAINER_NAME=$(docker ps --filter "label=sandbox.env=$ENV_ID" --format '{{.Names}}' | head -1)
if [[ -z "$CONTAINER_NAME" ]]; then
  echo "[simulate] No running container found for $ENV_ID" >&2
  exit 1
fi

for PROTECTED in sandbox-nginx sandbox-daemon sandbox-api; do
  if [[ "$CONTAINER_NAME" == "$PROTECTED" ]]; then
    echo "[simulate] REFUSED: cannot simulate against platform container $PROTECTED" >&2
    exit 1
  fi
done

NETWORK=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['network'])" 2>/dev/null)

echo "[simulate] mode=$MODE target=$CONTAINER_NAME"

case "$MODE" in
  crash)
    docker kill "$CONTAINER_NAME"
    echo "[simulate] Container killed. Health monitor will detect within 90s."
    ;;
  pause)
    docker pause "$CONTAINER_NAME"
    echo "[simulate] Container paused. Use --mode recover to unpause."
    ;;
  network)
    docker network disconnect "$NETWORK" "$CONTAINER_NAME"
    echo "[simulate] Network disconnected. Use --mode recover to reconnect."
    ;;
  recover)
    # Try unpause
    docker unpause "$CONTAINER_NAME" 2>/dev/null && echo "[simulate] Unpaused $CONTAINER_NAME" || true
    # Try reconnect network
    docker network connect "$NETWORK" "$CONTAINER_NAME" 2>/dev/null && echo "[simulate] Reconnected network" || true
    # Try restart if stopped
    docker start "$CONTAINER_NAME" 2>/dev/null && echo "[simulate] Restarted $CONTAINER_NAME" || true
    ;;
  stress)
    docker exec "$CONTAINER_NAME" sh -c "command -v stress-ng && stress-ng --cpu 2 --timeout 30s || (apk add --no-cache stress-ng -q && stress-ng --cpu 2 --timeout 30s)" &
    echo "[simulate] CPU stress started for 30s."
    ;;
  *)
    echo "[simulate] Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
