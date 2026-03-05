require('dotenv').config();
const express   = require('express');
const WebSocket = require('ws');
const cors      = require('cors');
const path      = require('path');

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, '..', 'web_client', 'web')));

// ── State ──
let lastImage       = null;
let lastAnalysis    = null;
let analysisVersion = 0;

// ── WebSocket clients ──
let windowsWS = null;   // the Windows browser (code "w")
let iphoneWS  = null;   // the iPhone app
let pendingCaptureRes = null;  // HTTP response waiting for screenshot

const server = app.listen(process.env.PORT || 3000, () => {
  console.log(`Server running on port ${server.address().port}`);
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (ws, req) => {
  console.log('🔌 New WebSocket connection');

  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw);

      // ── Register as Windows or iPhone ──
      if (msg.type === 'register') {
        if (msg.role === 'windows') {
          windowsWS = ws;
          ws._role = 'windows';
          console.log('🖥️  Windows registered');
          ws.send(JSON.stringify({ type: 'registered', role: 'windows' }));
        } else if (msg.role === 'iphone') {
          iphoneWS = ws;
          ws._role = 'iphone';
          console.log('📱 iPhone registered');
          ws.send(JSON.stringify({
            type: 'registered',
            role: 'iphone',
            version: analysisVersion,
            analysis: lastAnalysis
          }));
        } else if (msg.role === 'admin') {
          ws._role = 'admin';
          console.log('👨‍💼 Admin registered');
          ws.send(JSON.stringify({ type: 'registered', role: 'admin' }));
        }
      }

      // ── Windows sends screenshot ──
      if (msg.type === 'screenshot' && msg.image) {
        console.log('📸 Screenshot received (' + Math.round(msg.image.length / 1024) + ' KB)');
        lastImage = msg.image;

        // Respond to pending iPhone HTTP request
        if (pendingCaptureRes) {
          pendingCaptureRes.json({ status: 'ok' });
          pendingCaptureRes = null;
        }
      }

    } catch (e) {
      console.log('WS parse error:', e.message);
    }
  });

  ws.on('close', () => {
    if (ws._role === 'windows') {
      console.log('🖥️  Windows disconnected');
      windowsWS = null;
    } else if (ws._role === 'iphone') {
      console.log('📱 iPhone disconnected');
      iphoneWS = null;
    }
  });
});

// ── Heartbeat: keep connections alive (every 15 seconds) ──
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      console.log('❌ Connection dead - terminating');
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 15000);

// ── Admin/iPhone HTTP: trigger screenshot and notify iPhone ──
app.post('/capture', (req, res) => {
  console.log('📱 /capture called');

  // Notify iPhone that capture happened (just vibrate)
  if (iphoneWS && iphoneWS.readyState === WebSocket.OPEN) {
    iphoneWS.send(JSON.stringify({ type: 'admin_captured' }));
    console.log('📳 Sent vibrate notification to iPhone');
  }

  if (!windowsWS || windowsWS.readyState !== WebSocket.OPEN) {
    return res.json({ status: 'ok' });
  }

  if (pendingCaptureRes) {
    return res.json({ status: 'ok' });
  }

  pendingCaptureRes = res;

  // Tell Windows to capture NOW
  windowsWS.send(JSON.stringify({ type: 'capture' }));
  console.log('✅ Sent capture command to Windows');

  // Timeout
  setTimeout(() => {
    if (pendingCaptureRes === res) {
      console.log('⏰ Capture timeout');
      pendingCaptureRes = null;
      res.json({ status: 'ok' });
    }
  }, 15000);
});

// ── Admin: save answer → push to iPhone instantly via WS ──
app.post('/answer', (req, res) => {
  const { answer } = req.body;
  if (!answer) return res.json({ status: 'error' });

  lastAnalysis = answer.trim().toLowerCase().charAt(0);
  analysisVersion++;
  console.log('📝 Answer saved:', lastAnalysis, 'v' + analysisVersion);

  // Push answer to iPhone instantly via WebSocket!
  if (iphoneWS && iphoneWS.readyState === WebSocket.OPEN) {
    iphoneWS.send(JSON.stringify({
      type: 'answer',
      analysis: lastAnalysis,
      version: analysisVersion
    }));
    console.log('📤 Answer pushed to iPhone via WS');
  }

  res.json({ status: 'ok', answer: lastAnalysis, version: analysisVersion });
});

// ── iPhone: get last answer (fallback if WS missed it) ──
app.get('/last', (req, res) => {
  res.json({ status: 'ok', analysis: lastAnalysis, version: analysisVersion });
});

// ── Admin: get last screenshot ──
app.get('/last-image', (req, res) => {
  res.json({ status: 'ok', image: lastImage });
});

// ── Health check ──
app.get('/ping', (req, res) => {
  res.json({ status: 'ok', windows: windowsWS ? 'connected' : 'disconnected' });
});