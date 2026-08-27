'use strict';

const { app, BrowserWindow } = require('electron');
const path = require('path');
const http = require('http');
const fs = require('fs');

let mainWindow = null;

// Serve canvas-client over http://localhost so WebCodecs (VideoDecoder) is
// available. file:// URLs are not a secure context in Chromium, which means
// VideoDecoder / VideoFrame are undefined and the stream never renders.
function startStaticServer(dir, callback) {
    const mimeTypes = {
        '.html': 'text/html; charset=utf-8',
        '.js':   'application/javascript',
        '.css':  'text/css',
        '.png':  'image/png',
        '.svg':  'image/svg+xml',
    };

    const server = http.createServer((req, res) => {
        // Only serve index.html (single-page client)
        const filePath = path.join(dir, req.url === '/' ? 'index.html' : req.url);
        const ext = path.extname(filePath);
        fs.readFile(filePath, (err, data) => {
            if (err) {
                res.writeHead(404);
                res.end('Not found');
                return;
            }
            res.writeHead(200, { 'Content-Type': mimeTypes[ext] || 'application/octet-stream' });
            res.end(data);
        });
    });

    // Port 0 = OS picks a free port
    server.listen(0, '127.0.0.1', () => {
        const { port } = server.address();
        callback(`http://127.0.0.1:${port}`);
    });
}

function createWindow(baseURL) {
    mainWindow = new BrowserWindow({
        width: 1280,
        height: 900,
        title: 'Window Stream',
        backgroundColor: '#0C0E11',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
        },
    });

    mainWindow.loadURL(baseURL);

    mainWindow.on('closed', () => { mainWindow = null; });
}

const clientDir = path.join(__dirname, '..', 'canvas-client');
let serverBaseURL = null;

app.whenReady().then(() => {
    startStaticServer(clientDir, (url) => {
        serverBaseURL = url;
        createWindow(url);
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
    if (mainWindow === null && serverBaseURL) createWindow(serverBaseURL);
});
