#!/usr/bin/env python3
"""
platform/api.py — REST API that wraps the platform shell scripts.


Endpoints:
  POST   /envs              create env
  GET    /envs              list active envs + TTL remaining
  DELETE /envs/:id          destroy env
  GET    /envs/:id/logs     last 100 lines of app.log
  GET    /envs/:id/health   last 10 health check results
  POST   /envs/:id/outage   trigger simulation
"""

import os
import json
import subprocess
import time
from pathlib import Path
from flask import Flask, request, jsonify

app = Flask(__name__)

ROOT         = Path(__file__).parent.parent
ENVS_DIR     = ROOT / "envs"
LOGS_DIR     = ROOT / "logs"
PLATFORM_DIR = ROOT / "platform"


def load_state(env_id: str) -> dict | None:
    f = ENVS_DIR / f"{env_id}.json"
    if not f.exists():
        return None
    try:
        with open(f) as fh:
            return json.load(fh)
    except Exception:
        return None


def list_envs() -> list[dict]:
    envs = []
    now  = int(time.time())
    for f in ENVS_DIR.glob("*.json"):
        try:
            with open(f) as fh:
                data = json.load(fh)
            data["ttl_remaining_seconds"] = max(0, data["expires_at"] - now)
            envs.append(data)
        except Exception:
            pass
    return sorted(envs, key=lambda x: x["created_at"], reverse=True)


# ── POST /envs ─────────────────────────────────────────────────────────
@app.post("/envs")
def create_env():
    body     = request.get_json(silent=True) or {}
    name     = body.get("name", "sandbox")
    ttl      = str(body.get("ttl_minutes", 30))

    try:
        result = subprocess.run(
            [str(PLATFORM_DIR / "create_env.sh"), name, ttl],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return jsonify({"error": result.stderr}), 500

        # Last line of output is the env ID
        env_id = result.stdout.strip().split("\n")[-1].strip()
        state  = load_state(env_id)
        return jsonify({"env_id": env_id, "state": state, "output": result.stdout}), 201
    except subprocess.TimeoutExpired:
        return jsonify({"error": "create_env.sh timed out"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── GET /envs ──────────────────────────────────────────────────────────
@app.get("/envs")
def get_envs():
    return jsonify(list_envs())


# ── DELETE /envs/:id ───────────────────────────────────────────────────
@app.delete("/envs/<env_id>")
def destroy_env(env_id: str):
    if not load_state(env_id):
        return jsonify({"error": f"Environment {env_id} not found"}), 404
    try:
        result = subprocess.run(
            [str(PLATFORM_DIR / "destroy_env.sh"), env_id],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return jsonify({"error": result.stderr}), 500
        return jsonify({"destroyed": env_id, "output": result.stdout})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── GET /envs/:id/logs ─────────────────────────────────────────────────
@app.get("/envs/<env_id>/logs")
def get_logs(env_id: str):
    log_file = LOGS_DIR / env_id / "app.log"
    if not log_file.exists():
        return jsonify({"error": "Log file not found", "env_id": env_id}), 404
    lines = log_file.read_text().splitlines()[-100:]
    return jsonify({"env_id": env_id, "lines": len(lines), "log": lines})


# ── GET /envs/:id/health ───────────────────────────────────────────────
@app.get("/envs/<env_id>/health")
def get_health(env_id: str):
    health_file = LOGS_DIR / env_id / "health.log"
    if not health_file.exists():
        return jsonify({"env_id": env_id, "checks": [], "message": "No health data yet"})
    lines = health_file.read_text().splitlines()[-10:]
    checks = []
    for line in lines:
        try:
            checks.append(json.loads(line))
        except Exception:
            pass
    return jsonify({"env_id": env_id, "checks": checks})


# ── POST /envs/:id/outage ──────────────────────────────────────────────
@app.post("/envs/<env_id>/outage")
def trigger_outage(env_id: str):
    if not load_state(env_id):
        return jsonify({"error": f"Environment {env_id} not found"}), 404
    body = request.get_json(silent=True) or {}
    mode = body.get("mode", "")
    if mode not in ("crash", "pause", "network", "recover", "stress"):
        return jsonify({"error": f"Invalid mode: {mode}"}), 400
    try:
        result = subprocess.run(
            [str(PLATFORM_DIR / "simulate_outage.sh"), "--env", env_id, "--mode", mode],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return jsonify({"error": result.stderr, "output": result.stdout}), 500
        return jsonify({"env_id": env_id, "mode": mode, "output": result.stdout})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    port = int(os.getenv("API_PORT", 8000))
    app.run(host="0.0.0.0", port=port, debug=False)
