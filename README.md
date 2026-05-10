# DevOps Sandbox Platform

A self-service platform for spinning up isolated temporary environments,
deploying apps, simulating outages, and monitoring health — automatically.

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  Nginx :80   (single entry point for all envs)      │
│  /env/env-abc123/ → sandbox-app-env-abc123:5000     │
│  /env/env-xyz789/ → sandbox-app-env-xyz789:5000     │
└──────────────┬──────────────────────────────────────┘
               │ Docker network per env
               │
┌──────────────▼──────────────────────────────────────┐
│  sandbox-net-env-abc123 (isolated Docker network)   │
│  ┌──────────────────────┐                           │
│  │  sandbox-app-env-abc │  Flask app :5000          │
│  └──────────────────────┘                           │
└─────────────────────────────────────────────────────┘

Platform services (always running):
  sandbox-nginx    — Nginx router
  sandbox-api      — REST control plane :8000
  sandbox-monitor  — Health poller (every 30s)
  cleanup_daemon   — TTL expiry checker (every 60s)
```

## Prerequisites

- Docker 24+ and Docker Compose v2
- Python 3.11+
- `pip install flask`

## Quick Start (5 commands)

```bash
git clone https://github.com/yourname/devops-sandbox.git
cd devops-sandbox
docker build -t sandbox-app:latest ./app
make up
make create
```

## Full Demo Walkthrough

```bash
# 1. Start the platform
make up

# 2. Create an environment with 10 minute TTL
./platform/create_env.sh myapp 10

# 3. Check health
make health

# 4. Simulate a crash
make simulate ENV=env-abc123 MODE=crash

# 5. Watch monitor detect degradation (within 90s)
make logs ENV=env-abc123

# 6. Recover
make simulate ENV=env-abc123 MODE=recover

# 7. Wait for auto-destroy (or force it)
make destroy ENV=env-abc123

# 8. Clean everything
make clean
```

## API Reference

```
POST   /envs                     create env
GET    /envs                     list all envs
DELETE /envs/:id                 destroy env
GET    /envs/:id/logs            last 100 log lines
GET    /envs/:id/health          last 10 health checks
POST   /envs/:id/outage          {mode: crash|pause|network|recover}
```

## Known Limitations

- Nginx path routing (not subdomain) — no DNS changes needed but paths include env ID
- Log shipping via docker logs -f — process-based, killed on destroy
- Single VM only — not designed for multi-host deployments
- stress mode requires stress-ng installed in the app image
