#!/bin/bash
# Serve Windows Patch Automation documentation from docs/ on the internal network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="${ROOT}/docs"
HOST="${PATCH_DOCS_HOST:-0.0.0.0}"
PORT="${PATCH_DOCS_PORT:-8080}"
PID_FILE="${HOME}/.windows-patch-docs-server.pid"
LOG_FILE="${ROOT}/output/docs-server.log"

mkdir -p "$(dirname "$LOG_FILE")"

stop_server() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$PID_FILE"
  fi
}

case "${1:-start}" in
  start)
    stop_server
    echo "Starting docs server on http://${HOST}:${PORT}/"
    echo "  Document root: ${DOCS}"
    nohup python3 -m http.server "$PORT" --bind "$HOST" --directory "$DOCS" \
      >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    echo "PID $(cat "$PID_FILE") — log: ${LOG_FILE}"
    ;;
  stop)
    stop_server
    echo "Docs server stopped."
    ;;
  status)
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Running (PID $(cat "$PID_FILE")) — http://${HOST}:${PORT}/"
    else
      echo "Not running."
      exit 1
    fi
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  foreground)
    exec python3 -m http.server "$PORT" --bind "$HOST" --directory "$DOCS"
    ;;
  *)
    echo "Usage: $0 {start|stop|status|restart|foreground}"
    exit 1
    ;;
esac
