'use strict';

/**
 * src/main.js — Electron main process
 *
 * Responsibilities:
 *   1. Start the WebSocket broker in-process
 *   2. Launch CaptureHelper and InputBridge as child processes so they
 *      inherit Electron's window-server session (required for CGEvent posting)
 *   3. Serve src/client/ over http://127.0.0.1 (secure context for WebCodecs)
 *   4. Create the BrowserWindow
 */

const { app, BrowserWindow } = require('electron');
const path  = require('path');
const http  = require('http');
const fs    = require('fs');
const { spawn } = require('child_process');

// ── 1. Start broker ───────────────────────────────────────────────────────────
require('./broker');

// ── 2. Launch Swift helpers as child processes ────────────────────────────────

const ROOT = path.join(__dirname, '..');

function launchHelper(name, bin, args = []) {
  const binPath = path.join(ROOT, bin);
  if (!fs.existsSync(binPath)) {
    console.log(`[main] ${name} binary not found at ${binPath} — skipping`);
    return null;
  }
  const proc = spawn(binPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  proc.stdout.on('data', d => process.stdout.write(`[${name}] ${d}`));
  proc.stderr.on('data', d => process.stderr.write(`[${name}] ${d}`));
  proc.on('exit', (code, sig) => console.log(`[main] ${name} exited (${code ?? sig})`));
  console.log(`[main] launched ${name} (pid ${proc.pid})`);
  return proc;
}

let captureProc = null;
let inputProc   = null;

// ── 3. Static HTTP server ─────────────────────────────────────────────────────

const CLIENT_DIR = path.join(__dirname, 'client');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.png':  'image/png',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
};

function startStaticServer(callback) {
  const server = http.createServer((req, res) => {
    const relPath = req.url === '/' ? 'index.html' : req.url.replace(/^\//, '');
    const filePath = path.join(CLIENT_DIR, relPath);
    if (!filePath.startsWith(CLIENT_DIR)) { res.writeHead(403); res.end(); return; }
    fs.readFile(filePath, (err, data) => {
      if (err) { res.writeHead(404); res.end('Not found'); return; }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
      res.end(data);
    });
  });
  server.listen(0, '127.0.0.1', () => callback(`http://127.0.0.1:${server.address().port}`));
}

// ── 4. BrowserWindow ──────────────────────────────────────────────────────────

let mainWindow   = null;
let clientBaseURL = null;

function createWindow(url) {
  mainWindow = new BrowserWindow({
    width: 1280, height: 900,
    title: 'Window Stream',
    backgroundColor: '#0C0E11',
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });
  mainWindow.loadURL(url);
  mainWindow.on('closed', () => { mainWindow = null; });
}

app.whenReady().then(() => {
  // Launch helpers after app is ready — they inherit the foreground session
  inputProc = launchHelper('input-bridge', 'swift/input/.build/release/InputBridge');

  // Read window ID from env or use default
  const windowArg = process.env.CAPTURE_WINDOW ? ['--window', process.env.CAPTURE_WINDOW] : [];
  captureProc = launchHelper('capture', 'swift/capture/.build/release/CaptureHelper', windowArg);

  startStaticServer((url) => {
    clientBaseURL = url;
    createWindow(url);
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (!mainWindow && clientBaseURL) createWindow(clientBaseURL);
});

app.on('before-quit', () => {
  captureProc?.kill();
  inputProc?.kill();
});
