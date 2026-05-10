#!/usr/bin/env bash
# platform/destroy_env.sh
#
# Destroys a sandbox environment completely.
#
# Usage:
#   ./platform/destroy_env.sh <env_id>


set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
    echo "Usage: destroy_env.sh <env_id>"
    exit 1
fi

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "!!! State file not found: $STATE_FILE"
    echo "    Environment may already be destroyed"
    exit 1
fi

echo ">>> Destroying environment: $ENV_ID"

# ── Read state ────────────────────────────────────────────────────────────
# python3 -c is safe JSON parsing without needing jq installed
get_field() {
    python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('$1',''))" 2>/dev/null || echo ""
}

LOG_SHIPPER_PID=$(get_field log_shipper_pid)
NETWORK_NAME=$(get_field network_name)
NGINX_CONF=$(get_field nginx_conf)
LOG_FILE=$(get_field log_file)

# ── Step 1: Kill log shipper ──────────────────────────────────────────────
# Why first? If the container is removed while docker logs -f is running,
# it becomes a zombie process eating file descriptors.
if [[ -n "$LOG_SHIPPER_PID" && "$LOG_SHIPPER_PID" != "0" ]]; then
    if kill -0 "$LOG_SHIPPER_PID" 2>/dev/null; then
        kill "$LOG_SHIPPER_PID" 2>/dev/null && echo ">>> Log shipper killed (PID $LOG_SHIPPER_PID)"
    else
        echo ">>> Log shipper already gone (PID $LOG_SHIPPER_PID)"
    fi
fi

# ── Step 2: Stop and remove container ────────────────────────────────────
# Use label filter — robust even if container was renamed
CONTAINERS=$(docker ps -aq --filter "label=sandbox.env=$ENV_ID")
if [[ -n "$CONTAINERS" ]]; then
    echo ">>> Stopping containers: $CONTAINERS"
    docker stop $CONTAINERS 2>/dev/null || true
    docker rm   $CONTAINERS 2>/dev/null || true
    echo ">>> Containers removed"
else
    echo ">>> No containers found for $ENV_ID (may be already removed)"
fi

# ── Step 3: Disconnect Nginx from env network ─────────────────────────────
NGINX_CONTAINER=$(docker ps --filter "name=sandbox-nginx" --format "{{.ID}}" | head -1)
if [[ -n "$NGINX_CONTAINER" && -n "$NETWORK_NAME" ]]; then
    docker network disconnect "$NETWORK_NAME" "$NGINX_CONTAINER" 2>/dev/null || true
    echo ">>> Nginx disconnected from $NETWORK_NAME"
fi

# ── Step 4: Remove Docker network ────────────────────────────────────────
if [[ -n "$NETWORK_NAME" ]]; then
    docker network rm "$NETWORK_NAME" 2>/dev/null && \
        echo ">>> Network removed: $NETWORK_NAME" || \
        echo ">>> Network already gone: $NETWORK_NAME"
fi

# ── Step 5: Delete Nginx config and reload ────────────────────────────────
NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
if [[ -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF"
    echo ">>> Nginx config deleted: $NGINX_CONF"
else
    echo ">>> Nginx config already gone or path issue"
    # Fallback: try to find and delete any matching config
    rm -f "$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
fi

# ── Step 6: Archive logs ──────────────────────────────────────────────────
ARCHIVE_DIR="$ROOT_DIR/logs/archived/$ENV_ID"
LOG_DIR="$ROOT_DIR/logs/$ENV_ID"

if [[ -d "$LOG_DIR" ]]; then
    mkdir -p "$ARCHIVE_DIR"
    cp -r "$LOG_DIR/." "$ARCHIVE_DIR/"
    echo ">>> Logs archived to: $ARCHIVE_DIR"
fi

# ── Step 7: Delete state file ─────────────────────────────────────────────
rm -f "$STATE_FILE"
echo ">>> State file deleted"
echo ">>> Environment $ENV_ID destroyed successfully"
