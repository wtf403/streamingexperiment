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

const { app, BrowserWindow, ipcMain } = require('electron');
const path  = require('path');
const http  = require('http');
const fs    = require('fs');
const { spawn } = require('child_process');
const liquidGlass = require('electron-liquid-glass');

// ── Load .env from repo root (no extra dependency) ────────────────────────────
try {
  const envPath = path.join(__dirname, '..', '.env');
  const lines   = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2];
  }
} catch { /* no .env — fine */ }

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

let captureProcs = [];
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
  const showDevTools = Boolean(process.env.DEBUG_SHOW_DEVTOOLS);

  // Size to whichever display the cursor is on at launch
  const { screen } = require('electron');
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const { x, y, width, height } = display.workArea;

  mainWindow = new BrowserWindow({
    width, height,
    x, y,
    title: 'Window Stream',
    titleBarStyle: 'hiddenInset',  // native traffic lights, no title bar
    transparent: true,
    hasShadow: false,
    fullscreenable: false,  // disable fullscreen (green button on macOS)
    resizable: true,        // but allow manual resizing
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  mainWindow.loadURL(url);

  // Apply native Liquid Glass after window is ready
  mainWindow.once('ready-to-show', () => {
    try {
      liquidGlass.addView(mainWindow.getNativeWindowHandle(), {
        cornerRadius: 20,
        tintColor: { r: 255, g: 255, b: 255, a: 0.12 },
      });
    } catch (err) {
      console.log('[main] Liquid Glass not available (macOS < 26 or error):', err.message);
    }
    mainWindow.show();
  });

  if (showDevTools) {
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  }
  mainWindow.on('closed', () => { mainWindow = null; });
}

app.whenReady().then(() => {
  // Launch helpers after app is ready — they inherit the foreground session
  inputProc = launchHelper('input-bridge', 'swift/input/.build/release/InputBridge');

  // Launch capture helpers for each window with staggered startup
  const windowsEnv = process.env.CAPTURE_WINDOWS || process.env.CAPTURE_WINDOW || '61';
  const windowIDs = windowsEnv.split(',').map(s => s.trim()).filter(s => /^\d+$/.test(s));

  windowIDs.forEach((wid, idx) => {
    setTimeout(() => {
      const proc = launchHelper('capture', 'swift/capture/.build/release/CaptureHelper', ['--window', wid]);
      if (proc) captureProcs.push({ wid, proc });
    }, idx * 800);
  });

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
  for (const { proc } of captureProcs) proc?.kill();
  inputProc?.kill();
});
