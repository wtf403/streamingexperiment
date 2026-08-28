#!/usr/bin/env bash
# start.sh — build (if needed) and launch all components
# Usage: ./start.sh [--window <id>] [--list]
set -euo pipefail
cd "$(dirname "$0")"

CAPTURE_BIN="swift/capture/.build/release/CaptureHelper"
INPUT_BIN="swift/input/.build/release/InputBridge"

# ── --list shortcut ───────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" ]]; then
  [[ ! -f "$CAPTURE_BIN" ]] && swift build -c release --package-path swift/capture 2>&1
  "$CAPTURE_BIN" --list
  exit 0
fi

# ── build Swift if binaries are missing ──────────────────────────────────────
if [[ ! -f "$CAPTURE_BIN" ]]; then
  echo "[start] Building capture…"
  swift build -c release --package-path swift/capture 2>&1
fi
if [[ ! -f "$INPUT_BIN" ]]; then
  echo "[start] Building input-bridge…"
  swift build -c release --package-path swift/input 2>&1
fi

# ── npm deps ──────────────────────────────────────────────────────────────────
if [[ ! -d node_modules/electron ]]; then
  echo "[start] Installing npm deps…"
  npm install --silent
fi

# ── kill stale instances ──────────────────────────────────────────────────────
pkill -f "CaptureHelper"  2>/dev/null || true
pkill -f "InputBridge"    2>/dev/null || true
sleep 0.3

# ── collect --window args ─────────────────────────────────────────────────────
WINDOW_ARGS=()
while [[ $# -gt 0 ]]; do
  WINDOW_ARGS+=("$1"); shift
done

# ── cleanup on exit ───────────────────────────────────────────────────────────
PIDS=()
cleanup() {
  echo ""
  echo "[start] Stopping…"
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── start input-bridge ────────────────────────────────────────────────────────
"$INPUT_BIN" &
PIDS+=($!)
sleep 0.2

# ── start capture-helper ──────────────────────────────────────────────────────
"$CAPTURE_BIN" "${WINDOW_ARGS[@]}" &
PIDS+=($!)
sleep 0.5

# ── start Electron (embeds broker + static server) ───────────────────────────
npx electron . &
PIDS+=($!)

echo "[start] All running. Browser canvas: the Electron window."
echo "[start] Press Ctrl+C to stop."
wait -n 2>/dev/null || wait
