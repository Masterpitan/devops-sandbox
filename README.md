# DevOps Sandbox Platform

A self-service platform for spinning up isolated, short-lived app environments with dynamic Nginx routing, health monitoring, log shipping, outage simulation, and auto-cleanup. Think miniature internal Heroku with a chaos engineering toggle.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Linux VM / Host                          │
│                                                                 │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │  Client  │───▶│  Nginx :80   │───▶│  App Container(s)    │  │
│  │(browser/ │    │  (dynamic    │    │  env-abc123 :XXXX    │  │
│  │  curl)   │    │   routing)   │    │  env-def456 :YYYY    │  │
│  └──────────┘    └──────────────┘    └──────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Control Plane                                           │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │  │
│  │  │  Flask API  │  │Health Poller │  │Cleanup Daemon  │  │  │
│  │  │  :5000      │  │(every 30s)   │  │(every 60s)     │  │  │
│  │  └─────────────┘  └──────────────┘  └────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Filesystem                                              │  │
│  │  envs/<env_id>.json   (state)                           │  │
│  │  logs/<env_id>/app.log  health.log                      │  │
│  │  nginx/conf.d/<env_id>.conf  (auto-generated)           │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Component Roles

| Component | Role |
|---|---|
| `sandbox-nginx` | Front door — routes `<env_id>.sandbox.local` → app container port |
| `sandbox-api` | REST API wrapping all lifecycle scripts |
| `sandbox-health-poller` | Polls `/health` every 30s, marks envs degraded after 3 failures |
| `cleanup_daemon.sh` | Background loop — destroys expired envs by TTL |
| `create_env.sh` | Creates network, container, Nginx config, state file, log shipper |
| `destroy_env.sh` | Tears down container, network, Nginx config, archives logs |
| `simulate_outage.sh` | Injects failures: crash / pause / network disconnect / recover / stress |

### Nginx Network Approach

Nginx runs as a Docker container with `extra_hosts: host.docker.internal:host-gateway`. Each app container is started with `-p HOST_PORT:3000`, and the generated Nginx upstream points to `host.docker.internal:HOST_PORT`. This avoids needing Nginx on the same Docker network as every env container, keeping routing simple and port-based.

---

## Prerequisites

- Docker ≥ 24 + Docker Compose v2
- Python 3.11+
- `bash`, `shuf`, `nohup` (standard on Linux)
- Port 80 and 5000 free on the host

---

## Quick Start (zero → first running env in 5 commands)

```bash
git clone https://github.com/<you>/devops-sandbox && cd devops-sandbox
cp .env.example .env
make build          # builds sandbox-demo-app + API image
make up             # starts Nginx, API, health poller, cleanup daemon
make create         # prompts for name + TTL, prints URL
```

Then visit `http://localhost:<PORT>` or `curl http://localhost:<PORT>/health`.

---

## Full Demo Walkthrough

### 1. Start the platform
```bash
make up
```

### 2. Create an environment
```bash
make create
# → name: myapp
# → TTL: 300
# [create] ENV_ID=env-myapp-123456
# [create] URL=http://env-myapp-123456.sandbox.local (or http://localhost:7342)
# [create] TTL=300s
```

### 3. Check health
```bash
make health
# === Environment Health Status ===
#   env-myapp-123456 | status=running | ttl_remaining=287s | port=7342
# === Last Health Check Results ===
# --- env-myapp-123456 ---
# 2025-01-01T12:00:30Z status=200 latency=4ms
```

### 4. Simulate an outage
```bash
make simulate ENV=env-myapp-123456 MODE=pause
# [simulate] mode=pause target=env-myapp-123456
# [simulate] Container paused. Use --mode recover to unpause.
```

### 5. Observe degradation (wait ~90s for 3 health failures)
```bash
make health
# env-myapp-123456 | status=degraded | ...
make logs ENV=env-myapp-123456
```

### 6. Recover
```bash
make simulate ENV=env-myapp-123456 MODE=recover
```

### 7. Destroy manually (or wait for TTL)
```bash
make destroy ENV=env-myapp-123456
# Logs archived to logs/archived/env-myapp-123456/
```

### 8. Auto-destroy
The cleanup daemon checks every 60s. When `now > created_at + ttl`, it calls `destroy_env.sh` automatically and logs to `logs/cleanup.log`.

---

## API Reference

| Method | Path | Description |
|---|---|---|
| `POST` | `/envs` | Create env — body: `{"name":"x","ttl":1800}` |
| `GET` | `/envs` | List active envs with TTL remaining |
| `DELETE` | `/envs/:id` | Destroy env |
| `GET` | `/envs/:id/logs` | Last 100 lines of app.log |
| `GET` | `/envs/:id/health` | Last 10 health check results |
| `POST` | `/envs/:id/outage` | Trigger simulation — body: `{"mode":"crash"}` |

```bash
# Examples
curl -X POST http://localhost:5000/envs -H 'Content-Type: application/json' -d '{"name":"demo","ttl":600}'
curl http://localhost:5000/envs
curl -X DELETE http://localhost:5000/envs/env-demo-123456
curl -X POST http://localhost:5000/envs/env-demo-123456/outage -H 'Content-Type: application/json' -d '{"mode":"crash"}'
```

---

## Makefile Targets

| Target | Description |
|---|---|
| `make up` | Build images, start Nginx + API + poller + daemon |
| `make down` | Destroy all envs, stop all containers, kill daemon |
| `make build` | Build demo-app and API Docker images |
| `make create` | Interactive: create new env |
| `make destroy ENV=…` | Destroy specific env |
| `make logs ENV=…` | Tail app.log for env |
| `make health` | Show all env statuses + last health checks |
| `make simulate ENV=… MODE=…` | Run outage simulation |
| `make clean` | Wipe all state, logs, archives, Nginx configs |

---

## Log Shipping

Uses **Approach A**: `docker logs -f $CONTAINER_ID >> logs/$ENV_ID/app.log &` at creation time. The PID is stored in the state file and killed on destroy to prevent zombie processes. Logs are archived to `logs/archived/$ENV_ID/` on destroy.

---

## Known Limitations

- Nginx routing uses `host.docker.internal` — requires Docker ≥ 20.10 with `host-gateway` support (standard on Linux; may need `--add-host` on older versions).
- `shuf` is used for random port selection — not guaranteed collision-free under very high concurrency (acceptable for a single-VM sandbox).
- The cleanup daemon runs as a host process (nohup bash); on `make down` it is killed by PID file. If the host reboots, it must be restarted with `make up`.
- `stress` mode requires `stress-ng` inside the app container; the script attempts to install it via `apk` (Alpine only).
- No TLS — all traffic is plain HTTP, suitable for local/internal use only.
