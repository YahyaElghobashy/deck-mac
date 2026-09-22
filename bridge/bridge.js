#!/usr/bin/env node
'use strict';
/**
 * Deck ↔ Alexa bridge.
 *
 * Small localhost HTTP server in front of alexa-remote2 (the same private endpoints the Alexa app
 * uses). The Deck app and its widget extension talk to it; it keeps a JSON cache the widget can
 * read directly. Loopback only, shared-token protected.
 *
 *   node bridge.js            (Deck.app spawns it; also fine to run by hand)
 *
 * Files (~/Library/Application Support/Deck):
 *   bridge-config.json   amazonPage, defaultDevice, ports, refreshSeconds
 *   alexa-cookie.json    registration data from the one-time proxy login (keep private)
 *   alexa-state.json     cache: devices, smart-home states, timers, now playing, last exchange
 *   bridge-token         random secret every request must carry (X-Deck-Token header)
 *   bridge.log           breadcrumbs
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const Alexa = require('alexa-remote2');

const DIR = path.join(os.homedir(), 'Library', 'Application Support', 'Deck');
fs.mkdirSync(DIR, { recursive: true });
const P = {
  config: path.join(DIR, 'bridge-config.json'),
  cookie: path.join(DIR, 'alexa-cookie.json'),
  state: path.join(DIR, 'alexa-state.json'),
  token: path.join(DIR, 'bridge-token'),
  log: path.join(DIR, 'bridge.log'),
  former: path.join(DIR, 'alexa-former.json'),
};

const REGION_HOST = {
  'amazon.com': 'pitangui.amazon.com',
  'amazon.de': 'layla.amazon.de',
  'amazon.co.uk': 'alexa.amazon.co.uk',
  'amazon.it': 'alexa.amazon.it',
  'amazon.fr': 'alexa.amazon.fr',
  'amazon.es': 'alexa.amazon.es',
  'amazon.ca': 'alexa.amazon.ca',
  'amazon.com.au': 'alexa.amazon.com.au',
  'amazon.co.jp': 'alexa.amazon.co.jp',
  'amazon.in': 'alexa.amazon.in',
  'amazon.ae': 'alexa.amazon.ae',
  'amazon.sa': 'alexa.amazon.sa',
};

// ── helpers ─────────────────────────────────────────────────────────────────
function log(...a) {
  const line = `${new Date().toISOString()} ${a.map(x => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ')}`;
  console.log(line);
  try {
    if (fs.existsSync(P.log) && fs.statSync(P.log).size > 400_000) fs.renameSync(P.log, P.log + '.1');
    fs.appendFileSync(P.log, line + '\n');
  } catch {}
}
function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}
function writeJSON(file, obj) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 1));
  fs.renameSync(tmp, file);
}
function pcall(fn, ...args) {
  return new Promise((resolve, reject) => fn.call(alexa, ...args, (err, res) => (err ? reject(err) : resolve(res))));
}

const config = Object.assign(
  { amazonPage: 'amazon.de', port: 47831, proxyPort: 47832, defaultDevice: '', refreshSeconds: 180 },
  readJSON(P.config, {})
);
writeJSON(P.config, config);

let token = '';
try { token = fs.readFileSync(P.token, 'utf8').trim(); } catch {}
if (!token) {
  token = crypto.randomBytes(24).toString('hex');
  fs.writeFileSync(P.token, token, { mode: 0o600 });
}

// ── state cache ─────────────────────────────────────────────────────────────
const state = Object.assign({
  updatedAt: 0,
  authenticated: false,
  loginUrl: null,
  loginError: null,
  amazonPage: config.amazonPage,
  defaultDevice: config.defaultDevice,
  devices: [],
  smarthome: [],
  notifications: [],
  player: null,
  lastExchange: null,
  routines: [],
  pending: null,          // { text, at } while we wait for Alexa's reply text
}, readJSON(P.state, {}));
state.authenticated = false; // proven again on init
function saveState() {
  state.updatedAt = Date.now();
  state.amazonPage = config.amazonPage;
  state.defaultDevice = config.defaultDevice;
  writeJSON(P.state, state);
}
saveState();

// ── alexa-remote2 ───────────────────────────────────────────────────────────
let alexa = null;
let initInFlight = false;
let refreshTimer = null;

function initAlexa(reason) {
  if (initInFlight) return;
  initInFlight = true;
  log('init alexa:', reason, 'page=', config.amazonPage);
  const former = readJSON(P.cookie, null);
  alexa = new Alexa();
  alexa.on('cookie', (cookie, csrf, macDms) => {
    try {
      if (alexa.cookieData) writeJSON(P.cookie, alexa.cookieData);
      log('cookie stored');
    } catch (e) { log('cookie store failed', e.message); }
  });
  const opts = {
    proxyOnly: true,
    setupProxy: true,
    proxyOwnIp: '127.0.0.1',
    proxyPort: config.proxyPort,
    proxyListenBind: '127.0.0.1',
    proxyLogLevel: 'warn',
    amazonPage: config.amazonPage,
    alexaServiceHost: REGION_HOST[config.amazonPage] || `alexa.${config.amazonPage}`,
    acceptLanguage: config.acceptLanguage || 'en-US',
    bluetooth: false,
    useWsMqtt: false,
    cookieRefreshInterval: 6 * 24 * 60 * 60 * 1000,
    formerDataStorePath: P.former,
    logger: msg => log('[alexa]', String(msg).slice(0, 300)),
  };
  // The library only reuses a stored session when it arrives as the `cookie` option (object with
  // localCookie); formerRegistrationData alone still opens the login proxy.
  if (former) { opts.cookie = former; opts.formerRegistrationData = former; }
  let settled = false;
  alexa.init(opts, err => {
    if (err) {
      const msg = String(err.message || err);
      if (/Please open/i.test(msg)) {
        state.loginUrl = `http://127.0.0.1:${config.proxyPort}/`;
        state.loginError = null;
        state.authenticated = false;
        saveState();
        log('login needed →', state.loginUrl);
        // alexa-cookie2 keeps the proxy running and calls back again after a successful login.
        return;
      }
      state.loginError = msg;
      state.authenticated = false;
      saveState();
      log('init error:', msg);
      initInFlight = false;
      return;
    }
    if (settled) return;
    settled = true;
    initInFlight = false;
    state.authenticated = true;
    state.loginUrl = null;
    state.loginError = null;
    try { if (alexa.cookieData) writeJSON(P.cookie, alexa.cookieData); } catch {}
    log('alexa ready');
    loadDeviceLocales();
    saveState();
    scheduleRefresh(0);
  });
}

// ── refresh loop ────────────────────────────────────────────────────────────
let lastEntities = 0;
let entities = [];

function normalizeDevice(d) {
  return {
    name: d.accountName,
    serial: d.serialNumber,
    family: d.deviceFamily,
    type: d.deviceType,
    online: !!d.online,
    capabilities: (d.capabilities || []).slice(0, 12),
  };
}

function parseCapabilityStates(caps) {
  const out = { power: null, brightness: null, percentage: null, temperature: null, targetTemp: null, mode: null, reachable: null, extras: {} };
  for (const raw of caps || []) {
    let c = raw;
    if (typeof raw === 'string') { try { c = JSON.parse(raw); } catch { continue; } }
    const ns = c.namespace || '', name = c.name || '';
    const v = c.value;
    if (ns.endsWith('PowerController') && name === 'powerState') out.power = v;
    else if (ns.endsWith('BrightnessController')) out.brightness = v;
    else if (ns.endsWith('PercentageController')) out.percentage = v;
    else if (ns.endsWith('PowerLevelController')) out.percentage = v;
    else if (ns.endsWith('TemperatureSensor')) out.temperature = v && v.value !== undefined ? v.value : v;
    else if (ns.endsWith('ThermostatController') && name === 'targetSetpoint') out.targetTemp = v && v.value !== undefined ? v.value : v;
    else if (ns.endsWith('ThermostatController') && name === 'thermostatMode') out.mode = v;
    else if (ns.endsWith('EndpointHealth')) out.reachable = !(v && v.value === 'UNREACHABLE');
    else if (ns.endsWith('RangeController') || ns.endsWith('ModeController') || ns.endsWith('ToggleController')) {
      out.extras[`${ns.split('.').pop()}${c.instance ? ':' + c.instance : ''}`] = v;
    }
  }
  return out;
}

async function refreshSmarthome(force) {
  if (force || Date.now() - lastEntities > 10 * 60 * 1000 || entities.length === 0) {
    const res = await pcall(alexa.getSmarthomeEntities);
    entities = (Array.isArray(res) ? res : []).map(e => ({
      id: e.id,
      name: e.displayName || e.description || e.id,
      description: e.description || '',
      category: (e.providerData && e.providerData.categoryType) || (e.type) || '',
      operations: e.supportedOperations || [],
      properties: e.supportedProperties || [],
      entityType: e.entityType || 'ENTITY',
    }));
    lastEntities = Date.now();
  }
  const ids = entities.map(e => e.id);
  let states = {};
  if (ids.length) {
    try {
      const q = await pcall(alexa.querySmarthomeDevices, ids, 'ENTITY');
      for (const ds of (q && q.deviceStates) || []) {
        const id = ds.entity && (ds.entity.entityId || ds.entity.id);
        if (id) states[id] = parseCapabilityStates(ds.capabilityStates);
      }
    } catch (e) { log('smarthome query failed', e.message); }
  }
  state.smarthome = entities.map(e => Object.assign({}, e, states[e.id] || {}));
}

async function refreshNotifications() {
  const res = await pcall(alexa.getNotifications, false);
  const list = (res && res.notifications) || (Array.isArray(res) ? res : []);
  const now = Date.now();
  state.notifications = list
    .filter(n => n.status === 'ON')
    .map(n => ({
      id: n.notificationIndex || n.id,
      type: n.type,                                   // Timer | Alarm | Reminder | MusicAlarm
      label: n.reminderLabel || n.timerLabel || n.alarmLabel || '',
      device: n.deviceName || n.deviceSerialNumber,
      endsAt: n.type === 'Timer' ? now + (n.remainingTime || 0) : (n.alarmTime || null),
      remainingMs: n.remainingTime || null,
      recurring: n.recurringPattern || null,
    }))
    .sort((a, b) => (a.endsAt || 0) - (b.endsAt || 0));
}

function serialFor(name) {
  const d = state.devices.find(x => x.name === name || x.serial === name);
  return d ? d.serial : name;
}
async function refreshPlayer() {
  const dev = config.defaultDevice;
  if (!dev) { state.player = null; return; }
  const res = await pcall(alexa.getPlayerInfo, serialFor(dev));
  const p = res && res.playerInfo;
  if (!p) { state.player = null; return; }
  state.player = {
    device: dev,
    state: p.state,                                   // PLAYING | PAUSED | IDLE
    title: p.infoText && p.infoText.title,
    artist: p.infoText && p.infoText.subText1,
    album: p.infoText && p.infoText.subText2,
    imageURL: p.mainArt && p.mainArt.url,
    provider: p.provider && p.provider.providerName,
    progress: p.progress && p.progress.mediaProgress,
    length: p.progress && p.progress.mediaLength,
    volume: p.volume && p.volume.volume,
    muted: p.volume && p.volume.muted,
  };
}

async function refreshDevices() {
  const res = await pcall(alexa.getDevices);
  const list = (res && res.devices) || [];
  state.devices = list.filter(d => d.deviceFamily !== 'WHA').map(normalizeDevice);
  if (!config.defaultDevice) {
    const echo = state.devices.find(d => d.online && /ECHO|KNIGHT|ROOK/.test(d.family)) || state.devices[0];
    if (echo) { config.defaultDevice = echo.name; writeJSON(P.config, config); }
  }
}

let lastRoutines = 0;
async function refreshRoutines() {
  if (Date.now() - lastRoutines < 10 * 60 * 1000 && state.routines.length) return;
  const res = await pcall(alexa.getAutomationRoutines, 100);
  state.routines = (Array.isArray(res) ? res : []).map(r => ({
    id: r.automationId,
    name: (r.name) || (r.triggers && r.triggers[0] && r.triggers[0].payload && r.triggers[0].payload.utterance) || r.automationId,
    raw: r,
  }));
  lastRoutines = Date.now();
}

let refreshing = false;
async function refreshAll(reason) {
  if (!alexa || !state.authenticated || refreshing) return;
  refreshing = true;
  const started = Date.now();
  for (const [name, fn] of [['devices', refreshDevices], ['smarthome', refreshSmarthome], ['notifications', refreshNotifications], ['player', refreshPlayer], ['routines', refreshRoutines]]) {
    try { await fn(); } catch (e) { log(`refresh ${name} failed:`, e.message); }
  }
  refreshing = false;
  saveState();
  log(`refresh (${reason}) in ${Date.now() - started} ms: ${state.devices.length} devices, ${state.smarthome.length} smart-home, ${state.notifications.length} timers`);
}
function scheduleRefresh(delayMs) {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(async () => {
    await refreshAll('timer');
    scheduleRefresh(config.refreshSeconds * 1000);
  }, delayMs);
}

// ── conversations: text → Echo, then fetch Alexa's reply text from voice history ──
function pickTime(r) {
  return r.creationTimestamp || r.timestamp || (r.data && (r.data.creationTimestamp || r.data.timestamp)) || 0;
}
async function fetchReply(sinceMs, utterance, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  await new Promise(r => setTimeout(r, 3000));
  while (Date.now() < deadline) {
    try {
      const recs = await pcall(alexa.getCustomerHistoryRecords, { startTime: sinceMs - 15000, endTime: Date.now() + 60000 });
      const list = Array.isArray(recs) ? recs : [];
      const norm = t => String(t || '').toLowerCase().replace(/[^a-z0-9 ]/g, '').replace(/\s+/g, ' ').trim();
      const want = norm(utterance);
      const cands = list.filter(r => pickTime(r) >= sinceMs - 15000);
      cands.sort((a, b) => pickTime(b) - pickTime(a));
      // prefer the record whose transcript matches what we typed; Alexa's own ASR may differ a bit ("a. c." vs "ac")
      const hit = cands.find(r => {
        const said = norm(r.description && r.description.summary);
        return want && said && (said.includes(want.slice(0, 10)) || want.includes(said.slice(0, 10)));
      }) || cands.find(r => (r.alexaResponse || '').trim());
      if (hit) {
        const text = (hit.alexaResponse || '').trim();
        return {
          utterance: (hit.description && hit.description.summary) || utterance,
          response: text || '✓ Done',
          note: text ? null : 'Alexa acted without a spoken reply',
          at: pickTime(hit) || Date.now(),
          device: hit.name || hit.deviceName || config.defaultDevice,
        };
      }
    } catch (e) { log('history fetch failed', e.message); }
    await new Promise(r => setTimeout(r, 3000));
  }
  return null;
}

// ── sequences with the device's real locale ──────────────────────────────────
// alexa-remote2 hard-codes "locale":"de-DE" into every sequence (amazon.de accounts). Amazon
// validates the locale against the device (this Echo is en-US) and answers
// {"message":"Input failed to validate."} — the command silently never runs. So we build the
// sequence ourselves.
const deviceLocales = {};
function normLocale(l) {
  const [a, b] = String(l || '').split(/[-_]/);
  return b ? `${a.toLowerCase()}-${b.toUpperCase()}` : (l || 'en-US');
}
async function loadDeviceLocales() {
  try {
    const r = await new Promise((resolve, reject) => alexa.httpsGet('/api/device-preferences', (e, d) => (e ? reject(e) : resolve(d))));
    for (const p of (r && r.devicePreferences) || []) if (p.deviceSerialNumber && p.locale) deviceLocales[p.deviceSerialNumber] = normLocale(p.locale);
    log('device locales', deviceLocales);
  } catch (e) { log('device prefs failed', e.message); }
}
function sendNode(deviceName, node) {
  return new Promise((resolve, reject) => {
    const dev = alexa.find(serialFor(deviceName || config.defaultDevice));
    if (!dev || !dev.deviceType) return reject(new Error(`unknown device ${deviceName || config.defaultDevice}`));
    const locale = deviceLocales[dev.serialNumber] || config.locale || 'en-US';
    const payload = Object.assign({ deviceType: dev.deviceType, deviceSerialNumber: dev.serialNumber, locale, customerId: dev.deviceOwnerCustomerId }, node.operationPayload || {});
    const startNode = { '@type': 'com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode', type: node.type, operationPayload: payload };
    if (node.skillId) startNode.skillId = node.skillId;
    const seq = { '@type': 'com.amazon.alexa.behaviors.model.Sequence', startNode };
    const body = JSON.stringify({ behaviorId: 'PREVIEW', sequenceJson: JSON.stringify(seq), status: 'ENABLED' });
    alexa.httpsGet('/api/behaviors/preview', (err, res) => {
      if (err) return reject(err);
      if (res && res.message) return reject(new Error(`Alexa refused: ${res.message}`));
      resolve(res || {});
    }, { method: 'POST', data: body });
  });
}

async function sendText(text, device) {
  const dev = device || config.defaultDevice;
  if (!dev) throw new Error('no default Echo configured');
  const at = Date.now();
  state.pending = { text, at, device: dev };
  state.lastExchange = { utterance: text, response: null, at, device: dev };
  saveState();
  await sendNode(dev, { type: 'Alexa.TextCommand', skillId: 'amzn1.ask.1p.tellalexa', operationPayload: { text: text.toLowerCase() } });
  log('text →', dev, ':', text, `(serial ${serialFor(dev)}, locale ${deviceLocales[serialFor(dev)] || 'en-US'})`);
  fetchReply(at, text).then(reply => {
    state.pending = null;
    if (reply) {
      state.lastExchange = reply;
      log('alexa ←', reply.response);
    } else {
      state.lastExchange = { utterance: text, response: null, at, device: dev, note: 'no reply text in history' };
      log('no reply text found');
    }
    saveState();
    refreshAll('after-text');
  });
  return { sent: true, at, device: dev };
}

// ── HTTP ────────────────────────────────────────────────────────────────────
function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}
function readBody(req) {
  return new Promise(resolve => {
    let b = '';
    req.on('data', c => { b += c; if (b.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch { resolve({}); } });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const route = `${req.method} ${url.pathname}`;
  const authed = (req.headers['x-deck-token'] || url.searchParams.get('token')) === token;
  if (route !== 'GET /status' && !authed) return send(res, 401, { error: 'bad token' });
  try {
    if (route === 'GET /status') {
      return send(res, 200, { ok: true, authenticated: state.authenticated, loginUrl: state.loginUrl, loginError: state.loginError,
        amazonPage: config.amazonPage, defaultDevice: config.defaultDevice, devices: state.devices.length, updatedAt: state.updatedAt, pid: process.pid });
    }
    if (route === 'GET /state') return send(res, 200, state);
    if (route === 'POST /login') {
      if (state.authenticated) return send(res, 200, { authenticated: true });
      if (!initInFlight) initAlexa('login requested');
      return send(res, 200, { url: `http://127.0.0.1:${config.proxyPort}/`, note: 'open in Safari/Chrome on this Mac, log in to Amazon, then close the tab' });
    }
    if (route === 'POST /logout') {
      try { fs.unlinkSync(P.cookie); } catch {}
      try { fs.unlinkSync(P.former); } catch {}
      state.authenticated = false; state.loginUrl = null; saveState();
      setTimeout(() => process.exit(0), 200);   // supervisor restarts us clean
      return send(res, 200, { ok: true });
    }
    if (route === 'POST /config') {
      const b = await readBody(req);
      const pageChanged = b.amazonPage && b.amazonPage !== config.amazonPage;
      for (const k of ['amazonPage', 'defaultDevice', 'refreshSeconds', 'acceptLanguage']) if (b[k] !== undefined) config[k] = b[k];
      writeJSON(P.config, config);
      if (pageChanged) {
        try { fs.unlinkSync(P.cookie); } catch {}
        state.authenticated = false; saveState();
        setTimeout(() => process.exit(0), 200);
      } else if (state.authenticated) refreshAll('config');
      saveState();
      return send(res, 200, { ok: true, config, restarting: !!pageChanged });
    }
    if (!state.authenticated) return send(res, 409, { error: 'not logged in', loginUrl: state.loginUrl });

    if (route === 'POST /refresh') { await refreshAll('manual'); return send(res, 200, { ok: true, updatedAt: state.updatedAt }); }
    if (route === 'GET /devices') return send(res, 200, state.devices);
    if (route === 'GET /smarthome') { await refreshSmarthome(url.searchParams.get('force') === '1'); saveState(); return send(res, 200, state.smarthome); }
    if (route === 'POST /smarthome') {
      const b = await readBody(req);
      const ent = state.smarthome.find(e => e.id === b.id || e.name === b.name);
      if (!ent) return send(res, 404, { error: 'unknown entity' });
      let params;
      switch (b.action) {
        case 'on': params = { action: 'turnOn' }; break;
        case 'off': params = { action: 'turnOff' }; break;
        case 'toggle': params = { action: ent.power === 'ON' ? 'turnOff' : 'turnOn' }; break;
        case 'brightness': params = { action: 'setBrightness', brightness: Number(b.value) }; break;
        case 'percentage': params = { action: 'setPercentage', percentage: Number(b.value) }; break;
        default: params = b.parameters || null;
      }
      if (!params) return send(res, 400, { error: 'unknown action' });
      await pcall(alexa.executeSmarthomeDeviceAction, [ent.id], params, ent.entityType || 'ENTITY');
      if (params.action === 'turnOn') ent.power = 'ON';
      if (params.action === 'turnOff') ent.power = 'OFF';
      saveState();
      setTimeout(() => refreshSmarthome(false).then(saveState).catch(e => log('post-action refresh failed', e.message)), 2500);
      return send(res, 200, { ok: true, entity: ent.name, params });
    }
    if (route === 'POST /text') { const b = await readBody(req); return send(res, 200, await sendText(String(b.text || '').trim(), b.device)); }
    if (route === 'GET /reply') {
      const after = Number(url.searchParams.get('after') || 0);
      const ex = state.lastExchange;
      return send(res, 200, { pending: !!state.pending, exchange: ex && ex.at >= after ? ex : null });
    }
    if (route === 'GET /history') {
      const minutes = Number(url.searchParams.get('minutes') || 120);
      const recs = await pcall(alexa.getCustomerHistoryRecords, { startTime: Date.now() - minutes * 60000, endTime: Date.now() + 60000 });
      const raw = url.searchParams.get('raw') === '1';
      const list = (Array.isArray(recs) ? recs : []).map(r => ({ at: pickTime(r), utterance: r.description && r.description.summary, response: r.alexaResponse, device: r.name || r.deviceName,
        ...(raw ? { status: r.data && r.data.activityStatus, utteranceType: r.data && r.data.utteranceType, intent: r.data && r.data.intent, items: r.data && (r.data.voiceHistoryRecordItems || []).map(i => ({ type: i.recordItemType, text: i.transcriptText })), recordKey: r.data && r.data.recordKey } : {}) }));
      return send(res, 200, list.sort((a, b) => b.at - a.at).slice(0, 30));
    }
    if (route === 'GET /debug/history-raw') {
      const recs = await pcall(alexa.getCustomerHistoryRecords, { startTime: Date.now() - 20 * 60000, endTime: Date.now() + 60000 });
      return send(res, 200, (Array.isArray(recs) ? recs : []).slice(0, 4));
    }
    if (route === 'GET /debug/device-prefs') {
      const r = await new Promise((resolve, reject) => alexa.httpsGet('/api/device-preferences', (e, d) => e ? reject(e) : resolve(d)));
      return send(res, 200, r);
    }
    if (route === 'GET /notifications') { await refreshNotifications(); saveState(); return send(res, 200, state.notifications); }
    if (route === 'GET /routines') { await refreshRoutines(); saveState(); return send(res, 200, state.routines.map(r => ({ id: r.id, name: r.name }))); }
    if (route === 'POST /routine') {
      const b = await readBody(req);
      const r = state.routines.find(x => x.id === b.id || x.name === b.name);
      if (!r) return send(res, 404, { error: 'unknown routine' });
      await pcall(alexa.executeAutomationRoutine, serialFor(b.device || config.defaultDevice), r.raw);
      return send(res, 200, { ok: true, routine: r.name });
    }
    if (route === 'GET /player') { await refreshPlayer(); saveState(); return send(res, 200, state.player); }
    if (route === 'POST /command') {
      const b = await readBody(req);
      await pcall(alexa.sendCommand, serialFor(b.device || config.defaultDevice), b.command, b.value);
      setTimeout(() => refreshPlayer().then(saveState).catch(() => {}), 1500);
      return send(res, 200, { ok: true });
    }
    if (route === 'POST /speak') { const b = await readBody(req); await sendNode(b.device || config.defaultDevice, { type: 'Alexa.Speak', operationPayload: { textToSpeak: String(b.text || '') } }); return send(res, 200, { ok: true }); }
    if (route === 'POST /announce') { const b = await readBody(req); await pcall(alexa.sendSequenceCommand, b.device || config.defaultDevice, 'announcement', String(b.text || '')); return send(res, 200, { ok: true }); }
    return send(res, 404, { error: 'no such route', route });
  } catch (e) {
    log('route error', route, e.message);
    return send(res, 500, { error: e.message });
  }
});

server.listen(config.port, '127.0.0.1', () => {
  log(`bridge listening on http://127.0.0.1:${config.port} (pid ${process.pid})`);
  initAlexa('startup');
});
process.on('uncaughtException', e => log('uncaught', e.stack || e.message));
process.on('unhandledRejection', e => log('unhandled', (e && e.stack) || String(e)));
