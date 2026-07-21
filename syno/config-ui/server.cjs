/**
 * Immich ML config UI — port 2284
 * Run: /var/packages/immich/target/node/bin/node server.cjs
 *
 * Reads/writes ML_ENABLED and MACHINE_LEARNING_URL in immich.conf.
 * Restarts immich-server process on save.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const PORT = 2284;
// Separate settings file owned by the running user (sourced by immich.conf)
const CONF = '/var/packages/immich/var/ml-settings.env';
const HTML = path.join(__dirname, 'index.html');
const DONATED_FILE = '/var/packages/immich/var/donated';

function readConf() {
  let text = '';
  try { text = fs.readFileSync(CONF, 'utf8'); } catch (_) {}
  const mlEnabled = /^export ML_ENABLED=true/m.test(text);
  const urlMatch = text.match(/^export IMMICH_MACHINE_LEARNING_URL=(.+)$/m);
  const mlUrl = urlMatch ? urlMatch[1].trim() : '';
  return { mlEnabled, mlUrl };
}

function writeConf(mlEnabled, mlUrl) {
  let text = `export ML_ENABLED=${mlEnabled ? 'true' : 'false'}\n`;
  if (mlEnabled && mlUrl) {
    text += `export IMMICH_MACHINE_LEARNING_URL=${mlUrl}\n`;
  }
  fs.writeFileSync(CONF, text);
}

function restartImmich() {
  try {
    execSync('/usr/syno/bin/synopkg restart immich', { timeout: 15000 });
  } catch (_) {}
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/') {
    try {
      const html = fs.readFileSync(HTML, 'utf8');
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(html);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'UI file missing: ' + e.message }));
    }
    return;
  }

  if (req.method === 'GET' && req.url === '/config') {
    const conf = readConf();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(conf));
    return;
  }

  if (req.method === 'POST' && req.url === '/save') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const { mlEnabled, mlUrl } = JSON.parse(body);
        writeConf(!!mlEnabled, (mlUrl || '').trim());
        restartImmich();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, message: 'Saved. Immich restarting...' }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'GET' && req.url === '/donated') {
    const donated = fs.existsSync(DONATED_FILE);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ donated }));
    return;
  }

  if (req.method === 'POST' && req.url === '/donate') {
    try {
      fs.writeFileSync(DONATED_FILE, '1');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: e.message }));
    }
    return;
  }

  res.writeHead(404);
  res.end();
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Immich config UI listening on http://0.0.0.0:${PORT}`);
});
