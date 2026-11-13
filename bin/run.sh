#!/bin/sh
# Starts the bridge next to floci, then floci itself (the container lives as long as floci does).
rm -f /tmp/local-aws-ready

(
  while true; do
    python3 /opt/local-aws/bridge.py
    echo "[bridge] exited, restarting in 1 s" >&2
    sleep 1
  done
) &

exec /app/application -Dquarkus.http.host=0.0.0.0 "$@"
