#!/usr/bin/env bash
# platform/simulate_outage.sh
#
# Simulates various outage conditions for an environment.
#
# Usage:
#   ./platform/simulate_outage.sh --env <env_id> --mode <mode>


set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse arguments ────────────────────────────────────────────────────
ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)    ENV_ID="$2"; shift 2 ;;
        --mode)   MODE="$2";   shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
    echo "Usage: simulate_outage.sh --env <env_id> --mode <crash|pause|network|recover|stress>"
    exit 1
fi

# ── Safety guard ──────────────────────────────────────────────────────────
# NEVER run simulation against platform infrastructure containers.
# This check looks at container names and labels.
PROTECTED_PATTERNS=("sandbox-nginx" "sandbox-api" "sandbox-cleanup" "sandbox-monitor")
CONTAINER_NAME="sandbox-app-$ENV_ID"

for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if [[ "$CONTAINER_NAME" == *"$pattern"* ]]; then
        echo "!!! SAFETY VIOLATION: Cannot simulate outage against protected container: $CONTAINER_NAME"
        exit 1
    fi
done

# Verify it's a real sandbox container with our label
LABEL_CHECK=$(docker inspect "$CONTAINER_NAME" \
    --format '{{index .Config.Labels "sandbox.platform"}}' 2>/dev/null || echo "")
if [[ "$LABEL_CHECK" != "devops-sandbox" ]]; then
    echo "!!! Container $CONTAINER_NAME is not a sandbox environment container"
    exit 1
fi

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
    echo "!!! State file not found for $ENV_ID"
    exit 1
fi

NETWORK_NAME=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('network_name',''))")

echo ">>> Simulating outage: $MODE on $ENV_ID"

case "$MODE" in

    crash)
        # docker kill sends SIGKILL — immediate, no graceful shutdown
        # The health monitor should detect failure within 90 seconds
        docker kill "sandbox-app-$ENV_ID"
        echo ">>> Container killed. Health monitor should flag degraded within 90s"
        ;;

    pause)
        # docker pause freezes all processes using SIGSTOP
        # The container still exists but responds to nothing
        # Useful for simulating a hung service
        docker pause "sandbox-app-$ENV_ID"
        echo ">>> Container paused. Use --mode recover to unpause"
        ;;

    network)
        # Disconnect from the sandbox network
        # Nginx loses route to the container → 502 errors
        docker network disconnect "$NETWORK_NAME" "sandbox-app-$ENV_ID"
        echo ">>> Container disconnected from network $NETWORK_NAME"
        echo ">>> Nginx will return 502. Use --mode recover to reconnect"
        ;;

    recover)
        # Figure out what's broken and fix it
        CONTAINER_STATUS=$(docker inspect "sandbox-app-$ENV_ID" \
            --format '{{.State.Status}}' 2>/dev/null || echo "missing")

        case "$CONTAINER_STATUS" in
            paused)
                docker unpause "sandbox-app-$ENV_ID"
                echo ">>> Container unpaused"
                ;;
            exited|dead)
                docker start "sandbox-app-$ENV_ID"
                echo ">>> Container restarted"
                ;;
            running)
                # May have lost network connection — reconnect
                docker network connect "$NETWORK_NAME" "sandbox-app-$ENV_ID" 2>/dev/null || true
                echo ">>> Network reconnected"
                ;;
            *)
                echo ">>> Unknown status: $CONTAINER_STATUS — manual intervention needed"
                ;;
        esac

        # Reload Nginx to pick up restored connectivity
        NGINX_CONTAINER=$(docker ps --filter "name=sandbox-nginx" --format "{{.ID}}" | head -1)
        if [[ -n "$NGINX_CONTAINER" ]]; then
            docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
        fi
        echo ">>> Recovery complete"
        ;;

    stress)
        # Spike CPU inside the container
        # Requires stress-ng to be available (added to app Dockerfile optionally)
        if docker exec "sandbox-app-$ENV_ID" which stress-ng > /dev/null 2>&1; then
            docker exec -d "sandbox-app-$ENV_ID" \
                stress-ng --cpu 2 --timeout 60s
            echo ">>> CPU stress started (60 seconds)"
        else
            echo "!!! stress-ng not installed in container"
            echo "    Add it to app/Dockerfile: RUN apt-get install -y stress-ng"
            exit 1
        fi
        ;;

    *)
        echo "Unknown mode: $MODE"
        echo "Valid modes: crash, pause, network, recover, stress"
        exit 1
        ;;
esac
