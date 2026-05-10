#!/usr/bin/env python3
import os
import time
import json
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

ROOT     = Path(__file__).parent.parent
ENVS_DIR = ROOT / "envs"
LOGS_DIR = ROOT / "logs"
INTERVAL = 30   # seconds between polls
FAIL_THRESHOLD = 3   # consecutive failures before marking degraded

NGINX_HOST = os.getenv("NGINX_HOST", "localhost")
NGINX_PORT = os.getenv("NGINX_PORT", "80")


def log(msg: str):
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[{ts}] {msg}", flush=True)


def load_envs() -> list[dict]:
    """Read all active state files from envs/."""
    envs = []
    for f in ENVS_DIR.glob("*.json"):
        try:
            with open(f) as fh:
                data = json.load(fh)
            if data.get("status") not in ("destroyed",):
                envs.append(data)
        except (json.JSONDecodeError, IOError):
            pass
    return envs


def poll_health(env: dict) -> dict:
    """
    Hit the /health endpoint for one environment.
    Returns a result dict with status, latency, and timestamp.
    """
    env_id = env["id"]
    url    = f"http://{NGINX_HOST}:{NGINX_PORT}/env/{env_id}/health"
    ts     = datetime.now(timezone.utc).isoformat()
    start  = time.time()

    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            latency_ms = round((time.time() - start) * 1000, 1)
            return {
                "timestamp":  ts,
                "env_id":     env_id,
                "status_code": resp.status,
                "latency_ms": latency_ms,
                "ok":         resp.status == 200,
            }
    except urllib.error.HTTPError as e:
        latency_ms = round((time.time() - start) * 1000, 1)
        return {
            "timestamp":   ts,
            "env_id":      env_id,
            "status_code": e.code,
            "latency_ms":  latency_ms,
            "ok":          False,
            "error":       str(e),
        }
    except Exception as e:
        latency_ms = round((time.time() - start) * 1000, 1)
        return {
            "timestamp":   ts,
            "env_id":      env_id,
            "status_code": 0,
            "latency_ms":  latency_ms,
            "ok":          False,
            "error":       str(e),
        }


def write_health_log(env_id: str, result: dict):
    """Append one health check result to logs/$ENV_ID/health.log."""
    log_dir  = LOGS_DIR / env_id
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "health.log"
    with open(log_file, "a") as f:
        f.write(json.dumps(result) + "\n")


def update_env_status(env_id: str, new_status: str, consecutive_failures: int):
    """
    Update the status field in the env's state file.
    Atomic write: write to .tmp then mv.
    """
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return
    try:
        with open(state_file) as f:
            data = json.load(f)
        data["status"]            = new_status
        data["health_failures"]   = consecutive_failures
        tmp = str(state_file) + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, str(state_file))
    except Exception as e:
        log(f"ERROR updating state for {env_id}: {e}")


def run():
    log("Health monitor started")
    # Track consecutive failures per env
    failure_counts: dict[str, int] = {}

    while True:
        envs = load_envs()
        if not envs:
            log("No active environments to poll")
        else:
            for env in envs:
                env_id = env["id"]
                result = poll_health(env)
                write_health_log(env_id, result)

                if result["ok"]:
                    if failure_counts.get(env_id, 0) > 0:
                        log(f"RECOVERED: {env_id} is healthy again")
                    failure_counts[env_id] = 0
                    if env.get("status") == "degraded":
                        update_env_status(env_id, "running", 0)
                    log(f"OK: {env_id} — {result['latency_ms']}ms")
                else:
                    failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
                    count = failure_counts[env_id]
                    log(f"FAIL [{count}/{FAIL_THRESHOLD}]: {env_id} — {result.get('error', result['status_code'])}")

                    if count >= FAIL_THRESHOLD:
                        log(f"!!! DEGRADED: {env_id} has failed {count} consecutive checks")
                        update_env_status(env_id, "degraded", count)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    run()
