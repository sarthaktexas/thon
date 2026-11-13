(() => {
'use strict';
// Thon phone swiper client. Talks to the Mac over its JSON API; holds no scheme or deck of its own.
const $ = id => document.getElementById(id);
const LS = 'thonPhone_v1_';
const store = {
  get(k, d) { try { const v = localStorage.getItem(LS + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem(LS + k, JSON.stringify(v)); } catch (e) {} },
};
const ANIM = window.THON_NO_ANIM ? 0 : 170;
const THRESH = 100;

const qs = new URLSearchParams(location.search);
let TOKEN = qs.get('t') || store.get('t', '');
if (qs.get('t')) { store.set('t', TOKEN); try { history.replaceState(null, '', location.pathname); } catch (e) {} }

let S = null;                       // last server state
let queue = store.get('queue', []); // decisions not yet confirmed by the Mac: [{cid, body}]
let dropped = store.get('dropped', []);
const pending = new Set(queue.map(x => x.body.ref));
let sel = null, lastServerActive = null, schemeRev = null;
let geom = { dia: 0.2, box: 0.5 };
let cross = { u: 0.5, v: 0.5 };
let curRef = null, shownAt = Date.now();
let online = true, authBad = false, busy = false, retryTimer = null, panelOpen = false, animating = false;
const imgs = new Map();

function uid() { return (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }
function save() { store.set('queue', queue); store.set('dropped', dropped.slice(-100)); }
function toast(msg) { const t = $('toast'); t.textContent = msg; t.hidden = false; clearTimeout(toast.h); toast.h = setTimeout(() => { t.hidden = true; }, 2200); }
function imgURL(ref) { return '/api/card/' + encodeURIComponent(ref) + '.jpg?out=480&t=' + encodeURIComponent(TOKEN); }

class HttpError extends Error { constructor(status) { super('HTTP ' + status); this.status = status; } }
async function api(path, body) {
  const opt = { headers: { 'X-Thon-Token': TOKEN } };
  if (body !== undefined) { opt.method = 'POST'; opt.body = JSON.stringify(body); opt.headers['Content-Type'] = 'application/json'; }
  const r = await fetch(path, opt);
  if (r.status === 401) { authBad = true; render(); throw new HttpError(401); }
  authBad = false;
  let j = {}; try { j = await r.json(); } catch (e) {}
  return { status: r.status, json: j };
}
function setOnline(v) { if (online !== v) { online = v; renderTop(); } }

// ---------- state ----------
function labels() { return S ? S.scheme.labels.filter(l => l.exported) : []; }
function selLabel() { return sel; }
function deck() { return S && S.card ? [S.card.ref, ...S.upcoming].filter(r => !pending.has(r)) : []; }

function applyState(s) {
  S = s;
  if (s.card) geom = { dia: s.card.diameterFrac, box: s.card.boxFrac };
  if (s.activeLabel !== lastServerActive) { lastServerActive = s.activeLabel; sel = s.activeLabel; }
  if (!labels().some(l => l.id === sel)) sel = s.activeLabel;
  render();
}

async function poll() {
  if (document.hidden || busy || queue.length || animating) return;
  try { const r = await api('/api/state'); setOnline(true); if (r.status === 200) applyState(r.json); }
  catch (e) { if (e.status !== 401) setOnline(false); }
}

// ---------- rendering ----------
function renderTop() {
  const L = S && S.level;
  $('levelname').textContent = L && L.name ? L.name : 'Thon';
  $('progress').textContent = L && L.total ? Math.min(L.reviewed + localDone, L.total) + ' / ' + L.total : '';
  $('barfill').style.width = L && L.total ? (100 * Math.min(1, (L.reviewed + localDone) / L.total)) + '%' : '0';
  const qb = $('queuebadge'); qb.hidden = !queue.length; qb.textContent = queue.length + ' to sync';
  $('offdot').hidden = online;
}
let localDone = 0;      // decisions made locally and not yet reflected in the state

function renderChips() {
  const nav = $('chips'); const ls = labels();
  const sig = JSON.stringify([schemeRev, sel]);
  if (nav.dataset.sig === sig) return; nav.dataset.sig = sig;
  nav.textContent = '';
  for (const l of ls) {
    const b = document.createElement('button');
    b.className = 'chip' + (l.id === sel ? ' sel' : ''); b.dataset.id = l.id;
    const dot = document.createElement('i'); dot.style.background = l.color;
    b.appendChild(dot); b.appendChild(document.createTextNode(l.key + ' ' + l.name));
    b.addEventListener('click', () => chooseLabel(l.id));
    nav.appendChild(b);
  }
}
async function chooseLabel(id) {
  sel = id; $('chips').dataset.sig = ''; renderChips(); drawOverlay();
  try { const r = await api('/api/label', { id }); if (r.json && r.json.state) lastServerActive = r.json.state.activeLabel; } catch (e) {}
}

function showMsg(html, buttons) {
  const m = $('msg'); $('deck').hidden = true; m.hidden = false; m.textContent = '';
  const wrap = document.createElement('div'); wrap.innerHTML = html; m.appendChild(wrap);
  for (const [label, fn, primary] of buttons || []) {
    const b = document.createElement('button'); b.textContent = label; if (primary) b.className = 'primary'; b.addEventListener('click', fn); m.appendChild(b);
  }
}

function render() {
  if (!S) { renderTop(); showMsg(authBad ? '<b>Not paired</b>Scan the QR code in Thon\'s Phone panel again.' : '<b>Connecting&hellip;</b>', []); return; }
  if (schemeRev !== S.scheme.rev) { schemeRev = S.scheme.rev; $('chips').dataset.sig = ''; }
  renderChips(); renderTop();
  const L = S.level, refs = deck();
  const nav = [['Next micrograph', () => level('next'), true]];
  $('b-undo').disabled = queue.length > 0 || busy || !S.canUndo;
  for (const id of ['b-reject', 'b-later', 'b-unsure', 'b-pick']) $(id).disabled = !refs.length;
  if (authBad) { showMsg('<b>Not paired</b>Scan the QR code in Thon\'s Phone panel again.', []); return; }
  if (L.loading) { showMsg('<b>Opening micrograph&hellip;</b>The Mac is loading it.', []); return; }
  if (!L.key) { showMsg('<b>No micrograph open</b>Open a micrograph in Thon, then run Find particles.', []); return; }
  if (L.empty) {
    showMsg('<b>No candidates here</b>' + (L.autoBusy ? 'Finding particles on the Mac&hellip;' : 'Run the auto-picker on this micrograph, or skip it.'),
      [['Find particles', () => post('/api/autopick'), !L.autoBusy], ['Next micrograph', () => level('next')], ['Previous', () => level('prev')]]);
    return;
  }
  if (!refs.length) {
    if (queue.length) { showMsg('<b>Syncing&hellip;</b>' + queue.length + ' decisions waiting for the Mac.', []); return; }
    const l = S.stats.level;
    showMsg('<b>Micrograph finished</b>' + l.pick + ' picked, ' + l.reject + ' rejected, ' + l.unsure + ' unsure (' + l.cards + ' cards).', [...nav, ['Stats', openStats]]);
    return;
  }
  $('msg').hidden = true; $('deck').hidden = false;
  const cur = refs[0], nxt = refs[1];
  if (cur !== curRef) {
    curRef = cur; shownAt = Date.now();
    cross = (S.card && S.card.ref === cur) ? { u: S.card.cross[0], v: S.card.cross[1] } : { u: 0.5, v: 0.5 };
    $('frontimg').src = imgURL(cur);
  } else if (S.card && S.card.ref === cur && (Math.abs(S.card.cross[0] - 0.5) > 1e-6 || Math.abs(S.card.cross[1] - 0.5) > 1e-6) && !moved()) {
    cross = { u: S.card.cross[0], v: S.card.cross[1] };
  }
  $('backimg').src = nxt ? imgURL(nxt) : '';
  $('back').style.visibility = nxt ? 'visible' : 'hidden';
  for (const r of refs.slice(0, 8)) if (!imgs.has(r)) { const im = new Image(); im.src = imgURL(r); imgs.set(r, im); if (imgs.size > 40) imgs.delete(imgs.keys().next().value); }
  drawOverlay();
}
function moved() { return Math.abs(cross.u - 0.5) > 1e-6 || Math.abs(cross.v - 0.5) > 1e-6; }

function drawOverlay() {
  const svg = $('overlay'); if (!S) return;
  const l = labels().find(x => x.id === sel); const col = l ? l.color : '#fff';
  const cx = cross.u * 100, cy = cross.v * 100, r = geom.dia * 50, b = geom.box * 50;
  svg.innerHTML =
    '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="#000" stroke-opacity=".6" stroke-width="1.1" vector-effect="non-scaling-stroke"/>' +
    '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="' + col + '" stroke-width="2" vector-effect="non-scaling-stroke"/>' +
    '<rect x="' + (cx - b) + '" y="' + (cy - b) + '" width="' + (2 * b) + '" height="' + (2 * b) + '" fill="none" stroke="#fff" stroke-opacity=".7" stroke-dasharray="4 3" stroke-width="1" vector-effect="non-scaling-stroke"/>' +
    '<path d="M' + (cx - 3) + ' ' + cy + 'H' + (cx + 3) + 'M' + cx + ' ' + (cy - 3) + 'V' + (cy + 3) + '" stroke="#ff4d4d" stroke-width="1.6" vector-effect="non-scaling-stroke"/>';
}

// ---------- decisions ----------
function decide(kind) {
  if (animating || !curRef) return;
  const ref = curRef;
  const body = { ref, decision: kind, ms: Date.now() - shownAt };
  if (kind === 'pick') body.label = selLabel();
  if ((kind === 'pick' || kind === 'unsure') && moved()) { body.u = cross.u; body.v = cross.v; }
  const fly = { pick: [1, 0], reject: [-1, 0], unsure: [0, -1], later: [0, 1] }[kind];
  const front = $('front');
  animating = true;
  front.style.transition = ANIM ? 'transform ' + ANIM + 'ms ease-out, opacity ' + ANIM + 'ms' : 'none';
  front.style.transform = 'translate(' + fly[0] * 130 + '%,' + fly[1] * 130 + '%) rotate(' + fly[0] * 12 + 'deg)'; front.style.opacity = '0';
  setTimeout(() => {
    front.style.transition = 'none'; front.style.transform = ''; front.style.opacity = '1'; $('tint').style.opacity = 0;
    animating = false;
    body.cid = uid(); queue.push({ cid: body.cid, body }); pending.add(ref); localDone++; save();
    render(); flush();
  }, ANIM);
}

async function flush() {
  if (busy) return; busy = true; clearTimeout(retryTimer);
  try {
    while (queue.length) {
      const it = queue[0]; let r;
      try { r = await api('/api/decision', it.body); }
      catch (e) { if (e.status !== 401) setOnline(false); break; }
      setOnline(true);
      if (r.status >= 400) dropped.push({ ref: it.body.ref, decision: it.body.decision, reason: (r.json && r.json.reason) || ('error ' + r.status), t: Date.now() });
      queue.shift(); pending.delete(it.body.ref); localDone = Math.max(0, localDone - 1); save();
      if (r.json && r.json.state) applyState(r.json.state);
    }
  } finally { busy = false; }
  if (queue.length) retryTimer = setTimeout(flush, 3000); else render();
}

async function post(path, body) {
  try { const r = await api(path, body || {}); setOnline(true); if (r.json && r.json.state) applyState(r.json.state); return r; }
  catch (e) { if (e.status !== 401) { setOnline(false); toast('Not connected to the Mac'); } }
}
async function level(action) {
  if (queue.length) { toast('Syncing first'); return; }
  const r = await post('/api/level', { action });
  if (r && r.status === 409) toast('No further micrograph');
  if (panelOpen) closePanel();
}
async function undo() {
  if (queue.length || busy) { toast('Syncing first'); return; }
  const r = await post('/api/undo', {});
  if (r && r.json && r.json.applied === false) toast('Nothing to undo');
}

// ---------- gestures ----------
let drag = null;
function bindGestures() {
  const f = $('front');
  f.addEventListener('pointerdown', e => { if (animating) return; drag = { x0: e.clientX, y0: e.clientY, t0: Date.now(), dx: 0, dy: 0 }; try { f.setPointerCapture(e.pointerId); } catch (_) {} f.style.transition = 'none'; });
  f.addEventListener('pointermove', e => {
    if (!drag) return; drag.dx = e.clientX - drag.x0; drag.dy = e.clientY - drag.y0;
    f.style.transform = 'translate(' + drag.dx + 'px,' + drag.dy + 'px) rotate(' + drag.dx / 25 + 'deg)';
    const horiz = Math.abs(drag.dx) >= Math.abs(drag.dy);
    const col = horiz ? (drag.dx > 0 ? '77,255,106' : '255,90,82') : (drag.dy < 0 ? '255,212,0' : '150,150,150');
    const strength = Math.min(1, Math.max(Math.abs(drag.dx), Math.abs(drag.dy)) / 140);
    const t = $('tint'); t.style.background = 'rgb(' + col + ')'; t.style.opacity = 0.35 * strength;
  });
  const end = e => {
    if (!drag) return; const d = drag; drag = null;
    const dist = Math.hypot(d.dx, d.dy);
    if (dist < 8 && Date.now() - d.t0 < 450) { tap(e); reset(); return; }
    if (Math.abs(d.dx) > THRESH && Math.abs(d.dx) >= Math.abs(d.dy)) { d.dx > 0 ? decide('pick') : decide('reject'); }
    else if (d.dy < -THRESH) decide('unsure');
    else if (d.dy > THRESH) decide('later');
    else reset();
  };
  const reset = () => { f.style.transition = 'transform .15s'; f.style.transform = ''; $('tint').style.opacity = 0; };
  f.addEventListener('pointerup', end); f.addEventListener('pointercancel', () => { drag = null; reset(); });
}
function tap(e) {
  const r = $('front').getBoundingClientRect(); if (!r.width) return;
  const u = (e.clientX - r.left) / r.width, v = (e.clientY - r.top) / r.height;
  if (u >= 0 && u <= 1 && v >= 0 && v <= 1) { cross = { u, v }; drawOverlay(); }
}

// ---------- stats and micrographs panel ----------
function pct(x) { return x == null ? '–' : Math.round(100 * x) + '%'; }
function openStats() {
  panelOpen = true; const p = $('panel'); p.hidden = false; const b = $('panelbody'); b.textContent = '';
  const st = S ? S.stats : null, L = S ? S.level : null;
  const row = (a, v) => '<tr><td>' + a + '</td><td>' + v + '</td></tr>';
  b.innerHTML = '<h2>Stats</h2>' + (st ?
    '<h3>This micrograph</h3><table>' + row('Picked', st.level.pick) + row('Rejected', st.level.reject) + row('Unsure', st.level.unsure) + '</table>' +
    '<h3>All micrographs</h3><table>' + row('Cards decided', st.all.cards) + row('Picked, real candidates', pct(st.all.pickRateReal)) +
    row('Picked, random-spot control', pct(st.all.pickRateDecoy) + ' (' + st.all.decoySeen + ' seen)') + '</table>' +
    '<p class="note">About 8% of cards are random positions. A pick rate near the real-candidate rate means the candidates are not much better than random spots.</p>' : '') +
    '<h3>Micrograph</h3><div id="navbtns"></div>' +
    '<h3>Connection</h3><table>' + row('Mac', online ? 'connected' : 'offline') + row('Waiting to sync', queue.length) + row('Dropped decisions', dropped.length) + '</table>' +
    (dropped.length ? '<p class="note">Dropped: ' + dropped.slice(-8).map(d => d.decision + ' (' + d.reason + ')').join(', ') + '</p>' : '') +
    '<div><button class="btn" id="closepanel">Close</button></div>';
  const nb = $('navbtns');
  for (const [lbl, fn] of [['Previous micrograph', () => level('prev')], ['Next micrograph', () => level('next')], ['Rebuild deck', () => { post('/api/level', { action: 'rebuild' }); closePanel(); }]]) {
    const x = document.createElement('button'); x.className = 'btn'; x.textContent = lbl; x.addEventListener('click', fn); nb.appendChild(x);
  }
  $('closepanel').addEventListener('click', closePanel);
}
function closePanel() { panelOpen = false; $('panel').hidden = true; }

// ---------- wiring ----------
function key(e) {
  if (panelOpen || e.metaKey || e.ctrlKey) return;
  const k = e.key;
  if (k === 'ArrowRight') decide('pick'); else if (k === 'ArrowLeft') decide('reject'); else if (k === 'ArrowUp') decide('unsure'); else if (k === 'ArrowDown') decide('later');
  else if (k === 'z' || k === 'Z') undo();
  else { const l = labels().find(x => x.key === k); if (l) chooseLabel(l.id); }
}
let wake = null;
async function keepAwake() { try { if (navigator.wakeLock && !wake) { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; }); } } catch (e) {} }

function init() {
  bindGestures();
  $('b-pick').addEventListener('click', () => decide('pick')); $('b-reject').addEventListener('click', () => decide('reject'));
  $('b-unsure').addEventListener('click', () => decide('unsure')); $('b-later').addEventListener('click', () => decide('later'));
  $('b-undo').addEventListener('click', undo); $('statsbtn').addEventListener('click', openStats);
  document.addEventListener('keydown', key);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { keepAwake(); poll(); flush(); } });
  document.addEventListener('pointerdown', keepAwake, { once: true });
  render(); poll().then(() => flush());
  setInterval(poll, 2000);
}
window.__thon = { S: () => S, queue: () => queue, dropped: () => dropped, pending, decide, undo, poll, flush, level, chooseLabel, deck, sel: () => sel, cross: () => cross, tap, openStats };
init();
})();
