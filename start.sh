#!/usr/bin/env bash
# start.sh — launch all components of the window streaming demo
# Usage: ./start.sh [--window <id>] [--list]
#
# Starts:
#   1. Node broker server       (server/index.js)
#   2. Swift input-bridge       (input-bridge/.build/release/InputBridge)
#   3. Swift capture-helper     (capture-helper/.build/release/CaptureHelper)
#   4. Electron shell           (electron-shell/)
#
# Press Ctrl+C to stop everything.

set -euo pipefail
cd "$(dirname "$0")"

# Kill any stale instances from a previous run
pkill -f "node.*server/index.js"      2>/dev/null || true
pkill -f "InputBridge"                2>/dev/null || true
pkill -f "CaptureHelper"              2>/dev/null || true
sleep 0.3

WINDOW_ARGS=""
if [[ "${1:-}" == "--list" ]]; then
  echo "Listing available windows..."
  ./capture-helper/.build/release/CaptureHelper --list 2>&1
  exit 0
fi

for arg in "$@"; do
  WINDOW_ARGS="$WINDOW_ARGS $arg"
done

# Cleanup on exit
PIDS=()
cleanup() {
  echo ""
  echo "Stopping all components..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "Done."
}
trap cleanup EXIT INT TERM

# ── 1. Node server ───────────────────────────────────────────────────────────
echo "[start] Starting Node broker..."
(cd server && node index.js) &
PIDS+=($!)
sleep 0.5

# ── 2. Input bridge ──────────────────────────────────────────────────────────
INPUT_BIN="./input-bridge/.build/release/InputBridge"
if [[ ! -f "$INPUT_BIN" ]]; then
  echo "[start] Building input-bridge..."
  swift build -c release --package-path ./input-bridge 2>&1
fi
echo "[start] Starting input-bridge..."
$INPUT_BIN &
PIDS+=($!)
sleep 0.3

# ── 3. Capture helper ────────────────────────────────────────────────────────
CAPTURE_BIN="./capture-helper/.build/release/CaptureHelper"
if [[ ! -f "$CAPTURE_BIN" ]]; then
  echo "[start] Building capture-helper..."
  swift build -c release --package-path ./capture-helper 2>&1
fi
echo "[start] Starting capture-helper..."
# shellcheck disable=SC2086
$CAPTURE_BIN $WINDOW_ARGS &
PIDS+=($!)
sleep 1

# ── 4. Electron shell ────────────────────────────────────────────────────────
if [[ ! -d "electron-shell/node_modules/electron" ]]; then
  echo "[start] Installing Electron..."
  (cd electron-shell && npm install --silent)
fi
echo "[start] Starting Electron..."
(cd electron-shell && npx electron .) &
PIDS+=($!)

echo ""
echo "All components running. Open http://127.0.0.1:8766 in a browser for web canvas."
echo "Press Ctrl+C to stop."
echo ""

# Wait for any component to exit unexpectedly
wait -n 2>/dev/null || wait
