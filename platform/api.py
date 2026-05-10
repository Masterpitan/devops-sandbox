#!/usr/bin/env python3
import json
import os
import subprocess
import time
from pathlib import Path

from flask import Flask, jsonify, request

app = Flask(__name__)

ROOT_DIR = Path(__file__).parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM_DIR = ROOT_DIR / "platform"


def load_state(env_id: str) -> dict | None:
    f = ENVS_DIR / f"{env_id}.json"
    if not f.exists():
        return None
    return json.loads(f.read_text())


def all_envs() -> list[dict]:
    envs = []
    for f in ENVS_DIR.glob("*.json"):
        try:
            envs.append(json.loads(f.read_text()))
        except Exception:
            pass
    return envs


def ttl_remaining(env: dict) -> int:
    return max(0, env["created_at"] + env["ttl"] - int(time.time()))


@app.post("/envs")
def create_env():
    body = request.get_json(silent=True) or {}
    name = body.get("name", "")
    ttl = str(body.get("ttl", 1800))
    if not name:
        return jsonify(error="name required"), 400
    result = subprocess.run(
        ["bash", str(PLATFORM_DIR / "create_env.sh"), name, ttl],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return jsonify(error=result.stderr.strip()), 500
    env_id = next(
        (line.split("=", 1)[1] for line in result.stdout.splitlines() if line.startswith("[create] ENV_ID=")),
        None
    )
    url = next(
        (line.split("=", 1)[1] for line in result.stdout.splitlines() if line.startswith("[create] URL=")),
        None
    )
    return jsonify(id=env_id, url=url, ttl=int(ttl)), 201


@app.get("/envs")
def list_envs():
    return jsonify([
        {**e, "ttl_remaining": ttl_remaining(e)}
        for e in all_envs()
    ])


@app.delete("/envs/<env_id>")
def destroy_env(env_id: str):
    if not load_state(env_id):
        return jsonify(error="not found"), 404
    result = subprocess.run(
        ["bash", str(PLATFORM_DIR / "destroy_env.sh"), env_id],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return jsonify(error=result.stderr.strip()), 500
    return jsonify(message=f"{env_id} destroyed"), 200


@app.get("/envs/<env_id>/logs")
def get_logs(env_id: str):
    log_file = LOGS_DIR / env_id / "app.log"
    archived = LOGS_DIR / "archived" / env_id / "app.log"
    target = log_file if log_file.exists() else archived
    if not target.exists():
        return jsonify(error="log not found"), 404
    lines = target.read_text(errors="replace").splitlines()[-100:]
    return jsonify(lines=lines)


@app.get("/envs/<env_id>/health")
def get_health(env_id: str):
    health_file = LOGS_DIR / env_id / "health.log"
    archived = LOGS_DIR / "archived" / env_id / "health.log"
    target = health_file if health_file.exists() else archived
    if not target.exists():
        return jsonify(results=[])
    lines = target.read_text(errors="replace").splitlines()[-10:]
    return jsonify(results=lines)


@app.post("/envs/<env_id>/outage")
def trigger_outage(env_id: str):
    if not load_state(env_id):
        return jsonify(error="not found"), 404
    body = request.get_json(silent=True) or {}
    mode = body.get("mode", "")
    if not mode:
        return jsonify(error="mode required"), 400
    result = subprocess.run(
        ["bash", str(PLATFORM_DIR / "simulate_outage.sh"), "--env", env_id, "--mode", mode],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return jsonify(error=result.stderr.strip()), 500
    return jsonify(message=result.stdout.strip())


if __name__ == "__main__":
    ENVS_DIR.mkdir(exist_ok=True)
    app.run(host="0.0.0.0", port=int(os.getenv("API_PORT", "5000")))
