'use strict';

/**
 * broker.js — WebSocket broker
 *
 * Port 8765: capture-helper → broker (H264 NAL chunks + meta JSON)
 * Port 8766: canvas clients  ↔ broker (frames out, input events in)
 * Port 8767: input-bridge    ← broker (input events forwarded)
 */

const { WebSocketServer, WebSocket } = require('ws');

const CAPTURE_PORT = 8765;
const CLIENT_PORT  = 8766;
const INPUT_PORT   = 8767;

let captureSocket    = null;
let inputBridgeSocket = null;
const clientSockets  = new Set();

let lastMeta  = null;
let frameCount = 0;
let fps = 0;

// ── helpers ───────────────────────────────────────────────────────────────────

function log(msg) { process.stderr.write(`[broker] ${msg}\n`); }

function broadcast(data, isBinary) {
  for (const ws of clientSockets) {
    if (ws.readyState === WebSocket.OPEN) ws.send(data, { binary: isBinary });
  }
}

// ── capture server ────────────────────────────────────────────────────────────

const captureServer = new WebSocketServer({ port: CAPTURE_PORT });
captureServer.on('listening', () => log(`capture  ws://127.0.0.1:${CAPTURE_PORT}`));
captureServer.on('error', (e) => { log(`FATAL: capture port ${CAPTURE_PORT} — ${e.message}`); process.exit(1); });

captureServer.on('connection', (ws) => {
  if (captureSocket) { log('warn: replacing stale capture connection'); captureSocket.close(); }
  captureSocket = ws;
  log('capture-helper connected');

  ws.on('message', (data, isBinary) => {
    if (!isBinary) {
      lastMeta = data.toString();
      broadcast(lastMeta, false);
      return;
    }
    frameCount++;
    broadcast(data, true);
  });

  ws.on('close', () => { log('capture-helper disconnected'); captureSocket = null; });
  ws.on('error', (e) => log('capture error: ' + e.message));
});

// ── client server ─────────────────────────────────────────────────────────────

const clientServer = new WebSocketServer({ port: CLIENT_PORT });
clientServer.on('listening', () => log(`clients  ws://127.0.0.1:${CLIENT_PORT}`));

clientServer.on('connection', (ws) => {
  clientSockets.add(ws);
  log(`client connected (${clientSockets.size} total)`);
  if (lastMeta) ws.send(lastMeta);

  ws.on('message', (data, isBinary) => {
    if (isBinary) return;
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
  fps = frameCount;
  frameCount = 0;
  log(`fps=${fps} clients=${clientSockets.size} capture=${captureSocket ? 'yes' : 'no'} input=${inputBridgeSocket ? 'yes' : 'no'}`);
}, 1000);

log('broker started');
