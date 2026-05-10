"""
app/app.py — The demo application that runs inside each sandbox environment.
Each instance gets its ENV_ID and ENV_NAME injected via environment variables.
The /health endpoint is what the monitor polls every 30 seconds.
"""
import os
import time
import random
from flask import Flask, jsonify

app = Flask(__name__)

ENV_ID   = os.getenv("ENV_ID",   "unknown")
ENV_NAME = os.getenv("ENV_NAME", "unknown")
START    = time.time()

@app.get("/")
def root():
    return jsonify({
        "message": f"Hello from sandbox environment {ENV_NAME}",
        "env_id":  ENV_ID,
        "uptime":  round(time.time() - START, 1),
    })

@app.get("/health")
def health():
    return jsonify({
        "status":  "healthy",
        "env_id":  ENV_ID,
        "uptime":  round(time.time() - START, 1),
    }), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
