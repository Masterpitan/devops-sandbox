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
│  │  envs/<env_id>.json        (state)                       │  │
│  │  logs/<env_id>/app.log     (container stdout)            │  │
│  │  logs/<env_id>/health.log  (poll results)                │  │
│  │  nginx/conf.d/<env_id>.conf  (auto-generated)            │  │
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

## Repository Structure

```
devops-sandbox/
├── platform/
│   ├── api.py               # Flask control API
│   ├── create_env.sh        # Environment lifecycle — create
│   ├── destroy_env.sh       # Environment lifecycle — destroy
│   ├── cleanup_daemon.sh    # TTL-based auto-cleanup loop
│   └── simulate_outage.sh   # Chaos engineering modes
├── nginx/
│   ├── nginx.conf           # Main Nginx config
│   └── conf.d/              # Auto-generated per-env configs
├── monitor/
│   └── health_poller.py     # Health check poller
├── demo-app/
│   ├── Dockerfile
│   ├── package.json
│   └── server.js            # Minimal Express app
├── logs/                    # Runtime logs (gitignored)
├── envs/                    # Runtime state files (gitignored)
├── docker-compose.yml
├── Dockerfile.api
├── Makefile
├── requirements.txt
├── .env.example
└── README.md
```

---

## Prerequisites

- Docker ≥ 24 + Docker Compose v2
- Python 3.11+
- `bash`, `shuf`, `nohup` (standard on Linux / WSL2)
- Ports 80 and 5000 free on the host

> **Windows users:** Run everything inside WSL2. Docker Desktop with the WSL2 backend must be enabled.

---

## Quick Start

Zero to first running environment in 5 commands:

```bash
git clone https://github.com/<you>/devops-sandbox && cd devops-sandbox
cp .env.example .env
docker compose build
docker compose up -d
curl -X POST http://localhost:5000/envs -H "Content-Type: application/json" -d '{"name":"myapp","ttl":300}'
```

Then hit your app:
```bash
curl http://localhost:<PORT>/
curl http://localhost:<PORT>/health
```

---

## Full Demo Walkthrough

### 1. Start the platform
```bash
docker compose up -d
docker ps
# sandbox-nginx, sandbox-api, sandbox-health-poller all running
```

### 2. Confirm API is live
```bash
curl http://localhost:5000/envs
# []
```

### 3. Create an environment
```bash
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"myapp","ttl":300}'
# {"id":"env-myapp-21319","ttl":300,"url":"http://env-myapp-21319.sandbox.local (or http://localhost:5087)"}
```

### 4. Hit the app directly
```bash
curl http://localhost:5087/
# {"message":"Hello from sandbox!","env":"env-myapp-21319","time":"..."}

curl http://localhost:5087/health
# {"status":"ok","env":"env-myapp-21319","uptime":23.9}
```

### 5. Check health poller (after 30s)
```bash
curl http://localhost:5000/envs/env-myapp-21319/health
# {"results":["2026-05-10T13:55:51Z status=200 latency=33ms", ...]}

curl http://localhost:5000/envs
# [{"id":"env-myapp-21319","status":"running","ttl_remaining":261,...}]
```

### 6. Simulate an outage
```bash
curl -X POST http://localhost:5000/envs/env-myapp-21319/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"pause"}'
```

### 7. Observe degradation (wait ~90s for 3 health failures)
```bash
curl http://localhost:5000/envs
# "status":"degraded"

curl http://localhost:5000/envs/env-myapp-21319/health
# status=ERROR entries
```

### 8. Recover
```bash
curl -X POST http://localhost:5000/envs/env-myapp-21319/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"recover"}'

# wait 30s then:
curl http://localhost:5000/envs
# "status":"running"
```

### 9. View logs
```bash
curl http://localhost:5000/envs/env-myapp-21319/logs
```

### 10. Destroy manually
```bash
curl -X DELETE http://localhost:5000/envs/env-myapp-21319
# logs archived to logs/archived/env-myapp-21319/
```

### 11. Auto-destroy via TTL
```bash
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"autoclean","ttl":65}'

# wait 65-125s — cleanup daemon destroys it automatically
curl http://localhost:5000/envs
# []
```

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

### Outage Modes

| Mode | Effect | Recovery |
|---|---|---|
| `crash` | `docker kill` — container stops | `recover` restarts it |
| `pause` | `docker pause` — container frozen | `recover` unpauses it |
| `network` | Disconnects container from its network | `recover` reconnects it |
| `recover` | Restores from crash / pause / network | — |
| `stress` | Spikes CPU with `stress-ng` for 30s | Auto-recovers |

```bash
# Examples
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" -d '{"name":"demo","ttl":600}'

curl http://localhost:5000/envs

curl -X DELETE http://localhost:5000/envs/env-demo-123456

curl -X POST http://localhost:5000/envs/env-demo-123456/outage \
  -H "Content-Type: application/json" -d '{"mode":"crash"}'
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

> `make` targets require Linux or WSL2. On Windows use the `curl` API commands directly.

---

## Log Shipping

Uses **Approach A**: `docker logs -f $CONTAINER_ID >> logs/$ENV_ID/app.log &` at creation time. The PID is stored in the state file and killed on destroy to prevent zombie processes. Logs are archived to `logs/archived/$ENV_ID/` on destroy.

---

## Environment State File

Each env writes a JSON state file to `envs/<env_id>.json`:

```json
{
  "id": "env-myapp-21319",
  "name": "myapp",
  "created_at": 1778421319,
  "ttl": 300,
  "port": 5087,
  "network": "env-myapp-21319-net",
  "log_pid": 51,
  "status": "running"
}
```

State files are written atomically via a temp file + `mv` to prevent partial reads by the cleanup daemon or health poller.

---

## Known Limitations

- Nginx routing uses `host.docker.internal` — requires Docker ≥ 20.10 with `host-gateway` support (standard on Linux; Docker Desktop handles this automatically).
- `shuf` is used for random port selection — not guaranteed collision-free under very high concurrency (acceptable for a single-VM sandbox).
- The cleanup daemon runs as a host process (`nohup bash`); on `make down` it is killed by PID file. If the host reboots, it must be restarted with `make up`.
- `stress` mode requires `stress-ng` inside the app container; the script attempts to install it via `apk` (Alpine only).
- No TLS — all traffic is plain HTTP, suitable for local/internal use only.
- Windows users must use WSL2 or call the API directly via `curl` — bash scripts do not run natively on Windows.
