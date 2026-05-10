# Makefile — All platform operations as make targets
# Usage: make <target> [ENV=env-abc123] [MODE=crash] [NAME=myenv] [TTL=30]

SHELL := /bin/bash
ROOT  := $(shell pwd)

# ── Platform lifecycle ─────────────────────────────────────────────────
.PHONY: up down create destroy logs health simulate clean status

up:
	@echo ">>> Starting platform..."
	docker compose up -d
	@echo ">>> Starting cleanup daemon..."
	nohup ./platform/cleanup_daemon.sh >> logs/cleanup.log 2>&1 & echo $$! > envs/cleanup_daemon.pid
	@echo ">>> Platform ready. API: http://localhost:8000"

down:
	@echo ">>> Stopping platform and destroying all environments..."
	@for f in envs/env-*.json; do \
	    [ -f "$$f" ] || continue; \
	    id=$$(basename $$f .json); \
	    echo "  Destroying $$id..."; \
	    ./platform/destroy_env.sh "$$id" 2>/dev/null || true; \
	done
	@[ -f envs/cleanup_daemon.pid ] && kill $$(cat envs/cleanup_daemon.pid) 2>/dev/null || true
	@rm -f envs/cleanup_daemon.pid
	docker compose down -v
	@echo ">>> Platform stopped"

create:
	@read -p "Environment name [sandbox]: " name; \
	 name=$${name:-sandbox}; \
	 read -p "TTL in minutes [30]: " ttl; \
	 ttl=$${ttl:-30}; \
	 ./platform/create_env.sh "$$name" "$$ttl"

destroy:
	@[ -n "$(ENV)" ] || (echo "Usage: make destroy ENV=env-abc123" && exit 1)
	./platform/destroy_env.sh $(ENV)

logs:
	@[ -n "$(ENV)" ] || (echo "Usage: make logs ENV=env-abc123" && exit 1)
	@LOG_FILE="logs/$(ENV)/app.log"; \
	 [ -f "$$LOG_FILE" ] || (echo "No log file: $$LOG_FILE" && exit 1); \
	 tail -f "$$LOG_FILE"

health:
	@echo "=== Environment Health Status ==="
	@for f in envs/env-*.json; do \
	    [ -f "$$f" ] || continue; \
	    id=$$(python3 -c "import json; d=json.load(open('$$f')); print(d['id'])"); \
	    name=$$(python3 -c "import json; d=json.load(open('$$f')); print(d['name'])"); \
	    status=$$(python3 -c "import json; d=json.load(open('$$f')); print(d['status'])"); \
	    expires=$$(python3 -c "import json,time; d=json.load(open('$$f')); print(max(0,d['expires_at']-int(time.time())))"); \
	    echo "  $$id ($$name): $$status | TTL remaining: $${expires}s"; \
	done

simulate:
	@[ -n "$(ENV)" ]  || (echo "Usage: make simulate ENV=env-abc123 MODE=crash" && exit 1)
	@[ -n "$(MODE)" ] || (echo "Usage: make simulate ENV=env-abc123 MODE=crash" && exit 1)
	./platform/simulate_outage.sh --env $(ENV) --mode $(MODE)

clean:
	@echo ">>> Wiping all state, logs, and archives..."
	@for f in envs/env-*.json; do \
	    [ -f "$$f" ] || continue; \
	    id=$$(basename $$f .json); \
	    ./platform/destroy_env.sh "$$id" 2>/dev/null || true; \
	done
	rm -rf logs/archived/* logs/env-* envs/env-*.json
	find logs/ -name "*.log" -not -path "*/archived/*" -delete
	@echo ">>> Clean complete"

status:
	@echo "=== Platform Status ==="
	@echo "--- Docker containers ---"
	@docker ps --filter "label=sandbox.platform=devops-sandbox" \
	    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
	@echo ""
	@echo "--- Active environments ---"
	@for f in envs/env-*.json; do \
	    [ -f "$$f" ] || continue; \
	    python3 -c "import json,time; d=json.load(open('$$f')); \
	        remaining=max(0,d['expires_at']-int(time.time())); \
	        print(f\"  {d['id']} | {d['name']} | {d['status']} | TTL: {remaining}s | Port: {d['host_port']}\")"; \
	done
