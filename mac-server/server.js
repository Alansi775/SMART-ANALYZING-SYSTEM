require('dotenv').config();
const express = require('express');
const cors    = require('cors');
const path    = require('path');

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, '..', 'web_client', 'web')));

// ── State ──
let lastImage       = null;
let lastAnalysis    = null;
let analysisVersion = 0;
let shouldCapture   = false;
let pendingCapture  = null;

// ── iPhone: trigger screenshot ──
app.post('/capture', (req, res) => {
  console.log('📱 /capture called');

  if (pendingCapture) {
    console.log('⚠️  Already pending, rejecting');
    return res.json({ status: 'error', message: 'Busy' });
  }

  shouldCapture  = true;
  pendingCapture = res;
  console.log('✅ shouldCapture = true, waiting for Windows...');

  setTimeout(() => {
    if (pendingCapture === res) {
      console.log('⏰ Capture timeout - Windows did not respond');
      pendingCapture = null;
      shouldCapture  = false;
      res.json({ status: 'timeout' });
    }
  }, 15000);
});

// ── Windows: poll for capture command ──
app.get('/poll', (req, res) => {
  const capture = shouldCapture;
  if (capture) {
    shouldCapture = false;
    console.log('🖥️  Windows got capture command');
  }
  res.json({ status: 'ok', shouldCapture: capture });
});

// ── Windows: submit screenshot ──
app.post('/screenshot', (req, res) => {
  const { image } = req.body;
  if (!image) return res.json({ status: 'error' });

  console.log('📸 Screenshot received (' + Math.round(image.length / 1024) + ' KB)');
  lastImage = image;

  if (pendingCapture) {
    console.log('✅ Responding to iPhone: screenshot ok');
    pendingCapture.json({ status: 'ok' });
    pendingCapture = null;
  }

  res.json({ status: 'ok' });
});

// ── Admin: save answer ──
app.post('/answer', (req, res) => {
  const { answer } = req.body;
  if (!answer) return res.json({ status: 'error' });

  lastAnalysis = answer.trim().toLowerCase().charAt(0);
  analysisVersion++;
  console.log('📝 Answer saved:', lastAnalysis, 'v' + analysisVersion);
  res.json({ status: 'ok', answer: lastAnalysis, version: analysisVersion });
});

// ── iPhone: get last answer + version ──
app.get('/last', (req, res) => {
  res.json({ status: 'ok', analysis: lastAnalysis, version: analysisVersion });
});

// ── Admin: get last screenshot ──
app.get('/last-image', (req, res) => {
  res.json({ status: 'ok', image: lastImage });
});

// ── iPhone: sync version (to avoid stale local version) ──
app.get('/sync', (req, res) => {
  res.json({ status: 'ok', version: analysisVersion });
});

// ── Health check ──
app.get('/ping', (req, res) => {
  res.json({ status: 'ok' });
});

// ── Start ──
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Version starts at: ${analysisVersion}`);
});