#!/usr/bin/env python3
"""Health poller — checks GET /health for every active env every 30s."""
import json
import time
import urllib.request
import urllib.error
from pathlib import Path

ROOT_DIR = Path(__file__).parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"

INTERVAL = 30
FAILURE_THRESHOLD = 3

failure_counts: dict[str, int] = {}


def load_envs() -> list[dict]:
    envs = []
    for f in ENVS_DIR.glob("*.json"):
        try:
            envs.append(json.loads(f.read_text()))
        except Exception:
            pass
    return envs


def update_status(env_id: str, status: str):
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return
    data = json.loads(state_file.read_text())
    data["status"] = status
    tmp = state_file.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.rename(state_file)


def poll_env(env: dict):
    env_id = env["id"]
    port = env.get("port")
    if not port:
        return

    url = f"http://host.docker.internal:{port}/health"
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    start = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            status = resp.status
        latency = round((time.monotonic() - start) * 1000)
        failure_counts[env_id] = 0
        if env.get("status") == "degraded":
            update_status(env_id, "running")
        line = f"{ts} status={status} latency={latency}ms"
    except Exception as e:
        latency = round((time.monotonic() - start) * 1000)
        failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
        line = f"{ts} status=ERROR latency={latency}ms error={type(e).__name__}"
        if failure_counts[env_id] >= FAILURE_THRESHOLD:
            print(f"[health] WARNING: {env_id} degraded ({failure_counts[env_id]} consecutive failures)")
            update_status(env_id, "degraded")

    log_file = LOGS_DIR / env_id / "health.log"
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a") as f:
        f.write(line + "\n")


def main():
    print("[health] Poller started")
    while True:
        for env in load_envs():
            try:
                poll_env(env)
            except Exception as e:
                print(f"[health] Error polling {env.get('id')}: {e}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
