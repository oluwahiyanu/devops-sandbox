#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_NAME="${1:-sandbox}"
TTL_MINUTES="${2:-30}"

if [[ -z "$ENV_NAME" ]]; then
    echo "Usage: create_env.sh <name> [ttl_minutes]"
    exit 1
fi

# Use openssl for random ID (works on Windows/Git Bash)
ENV_ID="env-$(openssl rand -hex 4)"
CREATED_AT=$(date -u +%s)
TTL_SECONDS=$((TTL_MINUTES * 60))
EXPIRES_AT=$((CREATED_AT + TTL_SECONDS))

echo ">>> Creating environment: $ENV_NAME ($ENV_ID)"
echo "    TTL: ${TTL_MINUTES} minutes"

mkdir -p "$ROOT_DIR/logs/$ENV_ID"
mkdir -p "$ROOT_DIR/envs"

NETWORK_NAME="sandbox-net-$ENV_ID"
echo ">>> Creating Docker network: $NETWORK_NAME"
docker network create "$NETWORK_NAME" > /dev/null || {
    echo "!!! Failed to create network"
    exit 1
}

# Find free port using Python (cross-platform)
find_free_port() {
    python3 -c "
import socket
for p in range(10000, 20000):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(('', p))
        s.close()
        print(p)
        break
    except OSError:
        pass
"
}
HOST_PORT=$(find_free_port)
APP_PORT=5000

echo ">>> Allocated host port: $HOST_PORT"

CONTAINER_ID=$(docker run -d \
    --name "sandbox-app-$ENV_ID" \
    --network "$NETWORK_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.name=$ENV_NAME" \
    --label "sandbox.platform=devops-sandbox" \
    -e "ENV_ID=$ENV_ID" \
    -e "ENV_NAME=$ENV_NAME" \
    -p "$HOST_PORT:$APP_PORT" \
    --restart unless-stopped \
    sandbox-app:latest)

echo ">>> Container started: ${CONTAINER_ID:0:12}"

NGINX_CONTAINER=$(docker ps --filter "name=sandbox-nginx" --format "{{.ID}}" | head -1)
if [[ -n "$NGINX_CONTAINER" ]]; then
    docker network connect "$NETWORK_NAME" "$NGINX_CONTAINER" 2>/dev/null || true
    echo ">>> Nginx connected to network $NETWORK_NAME"
fi

NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80;
    server_name localhost 127.0.0.1 host.docker.internal nginx;

    location /env/$ENV_ID/ {
        rewrite ^/env/$ENV_ID/(.*)$ /$1 break;
        proxy_pass http://sandbox-app-$ENV_ID:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Env-ID $ENV_ID;
        proxy_read_timeout 30s;
        proxy_intercept_errors on;
        error_page 502 503 504 = @env_error_$ENV_ID;
    }

    location /env/$ENV_ID {
        return 301 /env/$ENV_ID/;
    }

    location @env_error_$ENV_ID {
        default_type application/json;
        return 502 '{"error":"environment unreachable","env_id":"$ENV_ID"}';
    }
}
NGINXEOF

echo ">>> Nginx config written: $NGINX_CONF"

if [[ -n "$NGINX_CONTAINER" ]]; then
    docker exec "$NGINX_CONTAINER" nginx -t 2>/dev/null && \
        docker exec "$NGINX_CONTAINER" nginx -s reload && \
        echo ">>> Nginx reloaded" || echo "!!! Nginx reload failed"
fi

LOG_FILE="$ROOT_DIR/logs/$ENV_ID/app.log"
docker logs -f "sandbox-app-$ENV_ID" >> "$LOG_FILE" 2>&1 &
LOG_SHIPPER_PID=$!
echo ">>> Log shipping started (PID: $LOG_SHIPPER_PID)"

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
TEMP_FILE="$STATE_FILE.tmp"

cat > "$TEMP_FILE" << EOF
{
  "id":               "$ENV_ID",
  "name":             "$ENV_NAME",
  "created_at":       $CREATED_AT,
  "ttl_seconds":      $TTL_SECONDS,
  "expires_at":       $EXPIRES_AT,
  "status":           "running",
  "container_id":     "$CONTAINER_ID",
  "network_name":     "$NETWORK_NAME",
  "host_port":        $HOST_PORT,
  "app_port":         $APP_PORT,
  "log_shipper_pid":  $LOG_SHIPPER_PID,
  "log_file":         "$LOG_FILE",
  "nginx_conf":       "$NGINX_CONF",
  "health_failures":  0
}
EOF

mv "$TEMP_FILE" "$STATE_FILE"
echo ">>> State file written: $STATE_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Environment Ready                                   ║"
echo "║  ID:    $ENV_ID                          ║"
echo "║  Name:  $ENV_NAME"
echo "║  URL:   http://localhost/env/$ENV_ID/    ║"
echo "║  Port:  http://localhost:$HOST_PORT               ║"
echo "║  TTL:   ${TTL_MINUTES} minutes                              ║"
echo "╚══════════════════════════════════════════════════════╝"

echo "$ENV_ID"