#!/usr/bin/env bash
# platform/cleanup_daemon.sh
#
# Background daemon that destroys environments when their TTL expires.
#
# Run with:
#   nohup ./platform/cleanup_daemon.sh >> logs/cleanup.log 2>&1 &
#
# Checks every 60 seconds. For each envs/*.json file:
#   - Reads created_at and ttl_seconds
#   - If now > created_at + ttl_seconds → destroy
#
# Why 60 second loop not a cron job?
# Cron has 1-minute minimum resolution and adds setup complexity.
# A simple while loop is self-contained, easier to test, and visible in ps.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP_LOG="$ROOT_DIR/logs/cleanup.log"

log() {
    # All cleanup actions are timestamped for the audit trail
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$CLEANUP_LOG"
}

log "=== Cleanup daemon started (PID: $$) ==="

while true; do
    NOW=$(date +%s)

    # Find all active state files
    for STATE_FILE in "$ROOT_DIR"/envs/*.json; do
        [[ -f "$STATE_FILE" ]] || continue

        ENV_ID=$(basename "$STATE_FILE" .json)

        # Read expiry using python3 (safe JSON, no jq dependency)
        EXPIRES_AT=$(python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('expires_at', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

        STATUS=$(python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('status', 'unknown'))
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

        if [[ "$EXPIRES_AT" -gt 0 && "$NOW" -gt "$EXPIRES_AT" ]]; then
            log "TTL expired for $ENV_ID (status=$STATUS) — destroying"
            "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >> "$CLEANUP_LOG" 2>&1
            log "Destroyed: $ENV_ID"
        fi
    done

    sleep 60
done
