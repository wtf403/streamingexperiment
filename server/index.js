/**
 * server/index.js
 *
 * WebSocket broker with two roles:
 *   - port 8765: capture-helper connects here and sends H264 frames + meta JSON
 *   - port 8766: canvas clients (Electron, browser) connect here and receive frames/meta,
 *                and send back input events which are forwarded to input-bridge
 *
 * input-bridge connects on port 8767 to receive input events.
 */

'use strict';

const { WebSocketServer, WebSocket } = require('ws');

const CAPTURE_PORT  = 8765;  // capture-helper → server
const CLIENT_PORT   = 8766;  // canvas clients  ↔ server
const INPUT_PORT    = 8767;  // server → input-bridge

// ── state ────────────────────────────────────────────────────────────────────

let captureSocket = null;           // the one capture-helper connection
let inputBridgeSocket = null;       // the one input-bridge connection
const clientSockets = new Set();    // all canvas clients

let lastMeta = null;                // last window meta JSON string (resent on connect)
let frameCount = 0;
let fps = 0;
let fpsTimer = null;

// ── capture-helper server (port 8765) ────────────────────────────────────────

const captureServer = new WebSocketServer({ port: CAPTURE_PORT });
captureServer.on('listening', () => log(`capture  ws://127.0.0.1:${CAPTURE_PORT}`));

captureServer.on('connection', (ws) => {
    if (captureSocket) {
        log('warn: second capture-helper connected, replacing previous');
        captureSocket.close();
    }
    captureSocket = ws;
    log('capture-helper connected');

    ws.on('message', (data, isBinary) => {
        if (!isBinary) {
            // Text frame = meta JSON
            const str = data.toString();
            lastMeta = str;
            broadcast(str, false);   // relay as text to all clients
            return;
        }
        // Binary = H264 NAL unit chunk
        frameCount++;
        broadcastBinary(data);
    });

    ws.on('close', () => {
        log('capture-helper disconnected');
        captureSocket = null;
    });

    ws.on('error', (e) => log('capture error: ' + e.message));
});

// ── canvas client server (port 8766) ─────────────────────────────────────────

const clientServer = new WebSocketServer({ port: CLIENT_PORT });
clientServer.on('listening', () => log(`clients  ws://127.0.0.1:${CLIENT_PORT}`));

clientServer.on('connection', (ws) => {
    clientSockets.add(ws);
    log(`client connected (${clientSockets.size} total)`);

    // Immediately send last known meta so the client can set up coordinate mapping
    if (lastMeta) ws.send(lastMeta);

    ws.on('message', (data, isBinary) => {
        if (isBinary) return; // clients only send text (input events)
        const str = data.toString();
        // Forward input event to input-bridge
        if (inputBridgeSocket && inputBridgeSocket.readyState === WebSocket.OPEN) {
            inputBridgeSocket.send(str);
        } else {
            log('warn: input-bridge not connected, dropping: ' + str.slice(0, 80));
        }
    });

    ws.on('close', () => {
        clientSockets.delete(ws);
        log(`client disconnected (${clientSockets.size} remaining)`);
    });

    ws.on('error', (e) => {
        log('client error: ' + e.message);
        clientSockets.delete(ws);
    });
});

// ── input-bridge server (port 8767) ──────────────────────────────────────────

const inputServer = new WebSocketServer({ port: INPUT_PORT });
inputServer.on('listening', () => log(`input    ws://127.0.0.1:${INPUT_PORT}`));

inputServer.on('connection', (ws) => {
    if (inputBridgeSocket) {
        log('warn: second input-bridge connected, replacing');
        inputBridgeSocket.close();
    }
    inputBridgeSocket = ws;
    log('input-bridge connected');

    ws.on('close', () => {
        log('input-bridge disconnected');
        inputBridgeSocket = null;
    });
    ws.on('error', (e) => log('input-bridge error: ' + e.message));
});

// ── helpers ──────────────────────────────────────────────────────────────────

function broadcast(text, isBinary) {
    for (const ws of clientSockets) {
        if (ws.readyState === WebSocket.OPEN) ws.send(text);
    }
}

function broadcastBinary(data) {
    for (const ws of clientSockets) {
        if (ws.readyState === WebSocket.OPEN) ws.send(data, { binary: true });
    }
}

function log(msg) {
    process.stderr.write(`[server] ${msg}\n`);
}

// FPS counter
fpsTimer = setInterval(() => {
    fps = frameCount;
    frameCount = 0;
    if (fps > 0 || clientSockets.size > 0) {
        log(`fps=${fps} clients=${clientSockets.size} capture=${captureSocket ? 'yes' : 'no'} input=${inputBridgeSocket ? 'yes' : 'no'}`);
    }
}, 1000);

log('broker started');
