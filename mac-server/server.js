require('dotenv').config();
const express = require('express');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, '..', 'web_client', 'web')));

let windowsClient  = null;
let lastImage      = null;
let lastAnalysis   = null;
let analysisVersion = 0;   // يزيد كل مرة تتغير الإجابة
let pendingCapture = null;

const server = app.listen(3000, () => {
    console.log('Server running on port 3000');
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
    console.log('Windows connected');
    windowsClient = ws;

    ws.on('message', (data) => {
        try {
            const msg = JSON.parse(data);
            if (msg.type === 'screenshot') {
                console.log('Screenshot received');
                lastImage = msg.image;
                if (pendingCapture) {
                    pendingCapture.json({ status: 'ok' });
                    pendingCapture = null;
                }
            }
        } catch (e) {
            console.log('Error:', e.message);
        }
    });

    ws.on('close', () => {
        console.log('Windows disconnected');
        windowsClient = null;
    });
});

// iPhone: trigger screenshot
app.post('/capture', (req, res) => {
    if (!windowsClient) {
        return res.json({ status: 'error', message: 'Windows not connected' });
    }
    if (pendingCapture) {
        return res.json({ status: 'error', message: 'Busy' });
    }
    pendingCapture = res;
    windowsClient.send(JSON.stringify({ type: 'capture' }));
    setTimeout(() => {
        if (pendingCapture) {
            pendingCapture.json({ status: 'timeout' });
            pendingCapture = null;
        }
    }, 15000);
});

// Windows: poll for capture command
app.get('/poll', (req, res) => {
    res.json({
        status: 'ok',
        shouldCapture: pendingCapture !== null
    });
});

// Windows: submit screenshot via HTTP (for polling mode)
app.post('/screenshot', (req, res) => {
    const { image } = req.body;
    if (!image) return res.json({ status: 'error' });
    console.log('Screenshot received (HTTP)');
    lastImage = image;
    if (pendingCapture) {
        pendingCapture.json({ status: 'ok' });
        pendingCapture = null;
    }
    res.json({ status: 'ok' });
});

// Admin: save answer
app.post('/answer', (req, res) => {
    const { answer } = req.body;
    if (!answer) return res.json({ status: 'error' });
    lastAnalysis = answer.trim().toLowerCase().charAt(0);
    analysisVersion++;
    console.log('Answer saved:', lastAnalysis);
    res.json({ status: 'ok', answer: lastAnalysis, version: analysisVersion });
});

// iPhone: get last answer (with version for change detection)
app.get('/last', (req, res) => {
    res.json({ status: 'ok', analysis: lastAnalysis, version: analysisVersion });
});

// Admin: get last screenshot
app.get('/last-image', (req, res) => {
    res.json({ status: 'ok', image: lastImage });
});

// Health check
app.get('/ping', (req, res) => {
    res.json({ status: 'ok', windows: windowsClient ? 'connected' : 'disconnected' });
});