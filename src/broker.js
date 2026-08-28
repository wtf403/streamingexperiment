'use strict';

/**
 * broker.js — multi-window WebSocket broker
 *
 * Port 8765: capture-helpers → broker (H264 NAL chunks + meta JSON)
 *            Each capture sends a JSON meta first: { type:'meta', windowID, ... }
 *            Subsequent binary frames are tagged to the last-seen windowID for that socket.
 * Port 8766: canvas clients  ↔ broker (frames out, input events in)
 *            Clients can send { type:'subscribe', windowID } to switch streams.
 *            Default: receive frames from all windows (multiplexed with 4-byte windowID prefix).
 * Port 8767: input-bridge    ← broker (input events forwarded)
 */

const { WebSocketServer, WebSocket } = require('ws');

const CAPTURE_PORT = 8765;
const CLIENT_PORT  = 8766;
const INPUT_PORT   = 8767;

// Map windowID (number) → { socket, meta, lastFrameTime }
const captureWindows = new Map();
let inputBridgeSocket = null;
const clientSockets  = new Set();

let frameCount = 0;

function log(msg) { process.stderr.write(`[broker] ${msg}\n`); }

// ── frame broadcasting ────────────────────────────────────────────────────────
// Each binary frame is prefixed with a 4-byte little-endian windowID so clients
// know which window it belongs to.

function broadcastFrame(windowID, data) {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32LE(windowID, 0);
  for (const ws of clientSockets) {
    if (ws.readyState !== WebSocket.OPEN) continue;
    // If client subscribed to a specific window, only send that one
    if (ws.subscribedWindowID != null && ws.subscribedWindowID !== windowID) continue;
    ws.send(Buffer.concat([prefix, data]), { binary: true });
  }
}

function broadcastText(text) {
  for (const ws of clientSockets) {
    if (ws.readyState === WebSocket.OPEN) ws.send(text);
  }
}

function broadcastWindowList() {
  const windows = [];
  for (const [id, w] of captureWindows) {
    if (w.meta) windows.push(w.meta);
  }
  broadcastText(JSON.stringify({ type: 'windowList', windows }));
}

// ── capture server ────────────────────────────────────────────────────────────

const captureServer = new WebSocketServer({ port: CAPTURE_PORT });
captureServer.on('listening', () => log(`capture  ws://127.0.0.1:${CAPTURE_PORT}`));
captureServer.on('error', (e) => { log(`FATAL: capture port ${CAPTURE_PORT} — ${e.message}`); process.exit(1); });

captureServer.on('connection', (ws) => {
  log('capture-helper connected');
  let windowID = null;

  ws.on('message', (data, isBinary) => {
    if (!isBinary) {
      // Meta JSON — extract windowID and store
      try {
        const meta = JSON.parse(data.toString());
        if (meta.type === 'meta' && meta.windowID) {
          windowID = meta.windowID;
          captureWindows.set(windowID, { socket: ws, meta, lastFrameTime: Date.now() });
          log(`window ${windowID}: ${meta.title || '?'} ${meta.width}x${meta.height}`);
          broadcastText(data.toString());
          broadcastWindowList();
        }
      } catch {}
      return;
    }
    if (windowID == null) return;
    frameCount++;
    const w = captureWindows.get(windowID);
    if (w) w.lastFrameTime = Date.now();
    broadcastFrame(windowID, data);
  });

  ws.on('close', () => {
    if (windowID != null) {
      log(`capture-helper disconnected (window ${windowID})`);
      captureWindows.delete(windowID);
      broadcastWindowList();
    }
  });
  ws.on('error', (e) => log('capture error: ' + e.message));
});

// ── client server ─────────────────────────────────────────────────────────────

const clientServer = new WebSocketServer({ port: CLIENT_PORT });
clientServer.on('listening', () => log(`clients  ws://127.0.0.1:${CLIENT_PORT}`));

clientServer.on('connection', (ws) => {
  ws.subscribedWindowID = null; // null = receive all
  clientSockets.add(ws);
  log(`client connected (${clientSockets.size} total)`);

  // Send current window list immediately
  const windows = [];
  for (const [, w] of captureWindows) { if (w.meta) windows.push(w.meta); }
  if (windows.length) ws.send(JSON.stringify({ type: 'windowList', windows }));

  ws.on('message', (data, isBinary) => {
    if (isBinary) return;
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'subscribe') {
        ws.subscribedWindowID = msg.windowID ?? null;
        log(`client subscribed to window ${ws.subscribedWindowID}`);
        return;
      }
    } catch {}
    // Forward input events to input-bridge
    if (inputBridgeSocket?.readyState === WebSocket.OPEN) {
      inputBridgeSocket.send(data.toString());
    }
  });

  ws.on('close', () => { clientSockets.delete(ws); log(`client disconnected (${clientSockets.size} remaining)`); });
  ws.on('error', (e) => { clientSockets.delete(ws); log('client error: ' + e.message); });
});

// ── input-bridge server ───────────────────────────────────────────────────────

const inputServer = new WebSocketServer({ port: INPUT_PORT });
inputServer.on('listening', () => log(`input    ws://127.0.0.1:${INPUT_PORT}`));

inputServer.on('connection', (ws) => {
  if (inputBridgeSocket) { log('warn: replacing stale input-bridge'); inputBridgeSocket.close(); }
  inputBridgeSocket = ws;
  log('input-bridge connected');
  ws.on('close', () => { log('input-bridge disconnected'); inputBridgeSocket = null; });
  ws.on('error', (e) => log('input error: ' + e.message));
});

// ── fps ticker ────────────────────────────────────────────────────────────────

setInterval(() => {
  const fps = frameCount; frameCount = 0;
  const wins = [...captureWindows.keys()].join(',') || 'none';
  log(`fps=${fps} clients=${clientSockets.size} windows=[${wins}] input=${inputBridgeSocket ? 'yes' : 'no'}`);
}, 1000);

log('broker started');
