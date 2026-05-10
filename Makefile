.PHONY: up down create destroy logs health simulate clean build

SHELL := /bin/bash

up: build
	docker compose up -d
	@echo "Platform is up. API at http://localhost:$${API_PORT:-5000}"
	@nohup bash platform/cleanup_daemon.sh > logs/cleanup.log 2>&1 & echo $$! > logs/daemon.pid
	@echo "Cleanup daemon started (PID=$$(cat logs/daemon.pid))"

down:
	@for f in envs/*.json; do \
	  [ -f "$$f" ] || continue; \
	  id=$$(python3 -c "import json; print(json.load(open('$$f'))['id'])"); \
	  bash platform/destroy_env.sh "$$id" || true; \
	done
	docker compose down
	@if [ -f logs/daemon.pid ]; then kill $$(cat logs/daemon.pid) 2>/dev/null || true; rm -f logs/daemon.pid; fi
	@echo "Platform stopped."

build:
	docker build -t sandbox-demo-app ./demo-app
	docker compose build

create:
	@read -p "Environment name: " name; \
	read -p "TTL in seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	bash platform/create_env.sh "$$name" "$$ttl"

destroy:
	@[ -n "$(ENV)" ] || (echo "Usage: make destroy ENV=<env_id>" && exit 1)
	bash platform/destroy_env.sh "$(ENV)"

logs:
	@[ -n "$(ENV)" ] || (echo "Usage: make logs ENV=<env_id>" && exit 1)
	@LOG=logs/$(ENV)/app.log; \
	[ -f "$$LOG" ] || LOG=logs/archived/$(ENV)/app.log; \
	[ -f "$$LOG" ] && tail -f "$$LOG" || echo "Log not found: $$LOG"

health:
	@echo "=== Environment Health Status ==="
	@for f in envs/*.json; do \
	  [ -f "$$f" ] || continue; \
	  python3 -c " \
import json, time; \
d=json.load(open('$$f')); \
remaining=max(0, d['created_at']+d['ttl']-int(time.time())); \
print(f\"  {d['id']} | status={d['status']} | ttl_remaining={remaining}s | port={d['port']}\")"; \
	done
	@echo ""
	@echo "=== Last Health Check Results ==="
	@for f in envs/*.json; do \
	  [ -f "$$f" ] || continue; \
	  id=$$(python3 -c "import json; print(json.load(open('$$f'))['id'])"); \
	  echo "--- $$id ---"; \
	  [ -f "logs/$$id/health.log" ] && tail -3 "logs/$$id/health.log" || echo "  (no data yet)"; \
	done

simulate:
	@[ -n "$(ENV)" ] || (echo "Usage: make simulate ENV=<env_id> MODE=<crash|pause|network|recover|stress>" && exit 1)
	@[ -n "$(MODE)" ] || (echo "Usage: make simulate ENV=<env_id> MODE=<crash|pause|network|recover|stress>" && exit 1)
	bash platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean:
	@if [ -f logs/daemon.pid ]; then kill $$(cat logs/daemon.pid) 2>/dev/null || true; fi
	@docker ps -aq --filter "label=sandbox.env" | xargs -r docker rm -f 2>/dev/null || true
	@docker network ls --filter "name=env-" -q | xargs -r docker network rm 2>/dev/null || true
	rm -rf envs/*.json logs/*/  logs/archived/ logs/cleanup.log logs/daemon.pid nginx/conf.d/*.conf
	@echo "All state, logs, and archives wiped."
