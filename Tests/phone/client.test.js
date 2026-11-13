// Logic tests of the phone client with jsdom and a mock of the Mac API.
// Run:  cd Tests/phone && npm install jsdom && node client.test.js
// Layout, touch feel and real image rendering are not covered: those need a phone.
const fs = require('fs'), path = require('path');
const { JSDOM } = require('jsdom');
const RES = path.join(__dirname, '..', '..', 'Resources', 'phone');
const html = fs.readFileSync(path.join(RES, 'index.html'), 'utf8').replace(/<script src="\/app.js"><\/script>/, '');
const js = fs.readFileSync(path.join(RES, 'app.js'), 'utf8');

let pass = 0, fail = 0;
const ok = (c, name, extra) => { if (c) pass++; else { fail++; console.log('  FAIL', name, extra === undefined ? '' : JSON.stringify(extra)); } };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settle = async () => { for (let i = 0; i < 6; i++) await sleep(5); };

const QUALITY = [
  { id: 'good', name: 'Good', key: '1', color: '#4dff6a', shape: 'circle', exported: true },
  { id: 'maybe', name: 'Maybe', key: '2', color: '#ffd400', shape: 'circle', exported: true },
  { id: 'reject', name: 'Reject', key: '3', color: '#9a9a9a', shape: 'circle', exported: false } ];
const VIEWS = [
  { id: 'ring_top', name: 'Ring', key: '1', color: '#ff4d4d', shape: 'circle', exported: true },
  { id: 'side', name: 'Side', key: '2', color: '#ffd400', shape: 'circle', exported: true },
  { id: 'uncertain', name: 'Uncertain', key: '3', color: '#ff7bf5', shape: 'circle', exported: true },
  { id: 'reject', name: 'Reject', key: '4', color: '#9a9a9a', shape: 'circle', exported: false } ];

function mockMac() {
  const m = { online: true, auth: true, log: [], posts: [], labelsSet: [], levelCalls: [], autopicks: 0, undos: 0, force409: new Set(),
    scheme: { rev: 'r1', labels: QUALITY }, active: 'good', unsure: 'maybe', rev: 0,
    level: { key: 'm.mrc', name: 'm.mrc', index: 0, count: 3, empty: false, loading: false, autoBusy: false }, ids: ['a', 'b', 'c', 'd'], reviewed: 0, total: 4, undoStack: [] };
  m.state = () => ({
    v: 1, rev: ++m.rev, project: { name: 'P' }, scheme: m.scheme, activeLabel: m.active, unsureLabel: m.unsure,
    level: Object.assign({}, m.level, { total: m.total, reviewed: m.reviewed, done: m.ids.length === 0 && m.total > 0, candidates: m.ids.length }),
    card: m.ids.length && !m.level.empty && !m.level.loading ? { ref: m.level.key + '@' + m.ids[0], diameterFrac: .2, boxFrac: .5, cross: [.5, .5], windowNm: 45, view: 'raw' } : null,
    upcoming: m.ids.slice(1, 13).map(i => m.level.key + '@' + i), canUndo: m.undoStack.length > 0,
    stats: { level: { cards: m.reviewed, pick: m.log.filter(d => d.decision === 'pick').length, reject: 0, unsure: 0 }, all: { cards: m.reviewed, pick: 0, reject: 0, unsure: 0, pickRateReal: 0.4, pickRateDecoy: 0.0, decoySeen: 3, decoyPick: 0, realSeen: 5, realPick: 2 } } });
  m.fetch = async (url, opt = {}) => {
    if (!m.online) throw new TypeError('network');
    if (!m.auth) return { status: 401, json: async () => ({}) };
    const body = opt.body ? JSON.parse(opt.body) : null;
    const send = (j, status = 200) => ({ status, json: async () => j });
    if (url === '/api/state') return send(m.state());
    m.posts.push([url, body]);
    if (url === '/api/decision') {
      if (m.force409.has(body.ref)) return send({ applied: false, reason: 'level changed', state: m.state() }, 409);
      const id = body.ref.split('@').pop(); const i = m.ids.indexOf(id);
      if (i < 0) return send({ applied: false, reason: 'already decided', state: m.state() });
      m.ids.splice(i, 1); if (body.decision === 'later') m.ids.push(id); else { m.reviewed++; m.undoStack.push(id); }
      m.log.push(body); return send({ applied: true, state: m.state() });
    }
    if (url === '/api/label') { m.active = body.id; m.labelsSet.push(body.id); return send({ applied: true, state: m.state() }); }
    if (url === '/api/undo') { m.undos++; const id = m.undoStack.pop(); if (id) { m.ids.unshift(id); m.reviewed--; } return send({ applied: !!id, state: m.state() }); }
    if (url === '/api/autopick') { m.autopicks++; return send({ applied: true, state: m.state() }); }
    if (url === '/api/level') { m.levelCalls.push(body.action); if (body.action === 'next') { m.level = Object.assign({}, m.level, { key: 'n.mrc', name: 'n.mrc', index: 1, empty: false }); m.ids = ['x', 'y']; m.total = 2; m.reviewed = 0; }
      return send({ applied: true, state: m.state() }); }
    return send({}, 404);
  };
  return m;
}

async function boot(mac, search = '?t=tok') {
  const dom = new JSDOM(html, { url: 'http://thon.test/' + search, runScripts: 'outside-only', pretendToBeVisual: true,
    beforeParse(w) { w.THON_NO_ANIM = true; w.fetch = (u, o) => mac.fetch(u, o); w.Image = class { set src(v) { this._s = v; } get src() { return this._s; } }; } });
  dom.window.eval(js);
  await settle();
  return dom;
}
const q = (dom, s) => dom.window.document.querySelector(s);
const qa = (dom, s) => [...dom.window.document.querySelectorAll(s)];
function ptr(dom, type, x, y) { const e = new dom.window.Event(type, { bubbles: true }); e.clientX = x; e.clientY = y; e.pointerId = 1; q(dom, '#front').dispatchEvent(e); }
async function swipe(dom, dx, dy) { ptr(dom, 'pointerdown', 50, 50); ptr(dom, 'pointermove', 50 + dx, 50 + dy); ptr(dom, 'pointerup', 50 + dx, 50 + dy); await settle(); }

(async () => {
  // 1. first load: token handling, chips from scheme, card shown
  let mac = mockMac(), dom = await boot(mac);
  ok(dom.window.localStorage.getItem('thonPhone_v1_t') === '"tok"' && dom.window.location.search === '', 'token saved and removed from the URL');
  ok(qa(dom, '.chip').map(c => c.dataset.id).join() === 'good,maybe', 'chips show exported labels only', qa(dom, '.chip').map(c => c.dataset.id));
  ok(q(dom, '.chip.sel').dataset.id === 'good', 'active label selected');
  ok(q(dom, '#levelname').textContent === 'm.mrc' && q(dom, '#progress').textContent === '0 / 4', 'level name and progress', q(dom, '#progress').textContent);
  ok(!q(dom, '#deck').hidden && q(dom, '#frontimg').src.includes(encodeURIComponent('m.mrc@a')) && q(dom, '#frontimg').src.includes('t=tok'), 'current card image requested with token', q(dom, '#frontimg').src);
  ok(!JSON.stringify(mac.state().card).includes('decoy'), 'card state carries no decoy flag');

  // 2. pick with button
  q(dom, '#b-pick').click(); await settle(); await dom.window.__thon.flush(); await settle();
  let d = mac.log[0];
  ok(d && d.decision === 'pick' && d.ref === 'm.mrc@a' && d.label === 'good' && typeof d.cid === 'string' && d.ms >= 0 && d.u === undefined, 'pick sends ref, label, cid, dwell; no u,v when not recentered', d);
  ok(q(dom, '#frontimg').src.includes(encodeURIComponent('m.mrc@b')) && q(dom, '#progress').textContent === '1 / 4', 'next card and progress advance', q(dom, '#progress').textContent);
  ok(dom.window.__thon.queue().length === 0 && q(dom, '#queuebadge').hidden, 'queue empties after the Mac confirms');

  // 3. label switch by key, applied to the next pick
  dom.window.document.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: '2' })); await settle();
  ok(mac.labelsSet.join() === 'maybe' && q(dom, '.chip.sel').dataset.id === 'maybe', 'key 2 selects Maybe and tells the Mac');
  dom.window.document.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'ArrowRight' })); await settle(); await dom.window.__thon.flush();
  ok(mac.log[1].label === 'maybe', 'pick uses the selected label');

  // 4. recenter by tap, then swipe right
  q(dom, '#front').getBoundingClientRect = () => ({ left: 0, top: 0, width: 100, height: 100 });
  dom.window.__thon.tap({ clientX: 70, clientY: 30 });
  const c = dom.window.__thon.cross();
  ok(Math.abs(c.u - .7) < 1e-9 && Math.abs(c.v - .3) < 1e-9 && q(dom, '#overlay').innerHTML.includes('cx="70"'), 'tap moves the cross', c);
  await swipe(dom, 160, 5); await dom.window.__thon.flush();
  ok(mac.log[2].decision === 'pick' && Math.abs(mac.log[2].u - .7) < 1e-9 && Math.abs(mac.log[2].v - .3) < 1e-9, 'swipe right = pick, with recentered u,v', mac.log[2]);

  // 5. other gestures: need one card each; rebuild deck with more
  mac.ids = ['p', 'q', 'r', 's', 't']; mac.total = 9; await dom.window.__thon.poll(); await settle();
  await swipe(dom, -160, 0); await dom.window.__thon.flush(); ok(mac.log[3].decision === 'reject' && mac.log[3].label === undefined, 'swipe left = reject');
  await swipe(dom, 5, -150); await dom.window.__thon.flush(); ok(mac.log[4].decision === 'unsure', 'swipe up = unsure');
  await swipe(dom, 0, 150); await dom.window.__thon.flush(); ok(mac.log[5].decision === 'later', 'swipe down = later');
  await swipe(dom, 40, 10); ok(mac.log.length === 6, 'a short drag springs back without deciding');
  ptr(dom, 'pointerdown', 20, 20); ptr(dom, 'pointerup', 20, 20); await settle();
  ok(mac.log.length === 6 && Math.abs(dom.window.__thon.cross().u - .2) < 1e-9, 'a tap recenters without deciding');

  // 6. offline queue and replay
  const n0 = mac.log.length; mac.online = false;
  q(dom, '#b-reject').click(); await settle(); q(dom, '#b-pick').click(); await settle();
  ok(dom.window.__thon.queue().length === 2 && !q(dom, '#queuebadge').hidden && !q(dom, '#offdot').hidden && mac.log.length === n0, 'offline: decisions queued, badges shown, nothing sent');
  ok(JSON.parse(dom.window.localStorage.getItem('thonPhone_v1_queue')).length === 2, 'queue persisted in localStorage');
  ok(q(dom, '#b-undo').disabled, 'undo disabled while decisions are waiting');
  const qr = dom.window.__thon.queue().map(x => x.body.ref);
  mac.online = true; await dom.window.__thon.flush(); await settle();
  ok(dom.window.__thon.queue().length === 0 && mac.log.slice(n0).map(x => x.ref).join() === qr.join(), 'back online: replayed in order', mac.log.slice(n0).map(x => x.ref));
  ok(q(dom, '#offdot').hidden, 'offline badge cleared');

  // 7. reload keeps the queue (new page, same storage)
  mac.online = false; q(dom, '#b-reject').click(); await settle();
  const saved = dom.window.localStorage.getItem('thonPhone_v1_queue');
  const mac2 = mockMac(); mac2.ids = mac.ids.slice(); mac2.total = mac.total;
  const dom2 = new JSDOM(html, { url: 'http://thon.test/', runScripts: 'outside-only', pretendToBeVisual: true,
    beforeParse(w) { w.THON_NO_ANIM = true; w.fetch = (u, o) => mac2.fetch(u, o); w.Image = class { set src(v) {} }; w.localStorage.setItem('thonPhone_v1_queue', saved); w.localStorage.setItem('thonPhone_v1_t', '"tok"'); } });
  dom2.window.eval(js); await settle(); await dom2.window.__thon.flush(); await settle();
  ok(mac2.log.length === 1 && dom2.window.__thon.queue().length === 0, 'queued decision survives a page reload and is sent');
  dom2.window.close();

  // 8. conflicts are dropped and listed, not retried forever
  mac = mockMac(); dom.window.close(); dom = await boot(mac);
  mac.force409.add('m.mrc@a'); q(dom, '#b-pick').click(); await settle(); await dom.window.__thon.flush(); await settle();
  ok(dom.window.__thon.queue().length === 0 && dom.window.__thon.dropped().length === 1 && dom.window.__thon.dropped()[0].reason === 'level changed', 'a 409 decision is dropped and recorded');
  dom.window.__thon.openStats(); ok(q(dom, '#panelbody').textContent.includes('Dropped decisions') && q(dom, '#panelbody').textContent.includes('Picked, random-spot control'), 'stats panel shows control rate and dropped decisions'); q(dom, '#closepanel').click();

  // 9. scheme change on the Mac shows on the phone
  mac.scheme = { rev: 'r2', labels: VIEWS }; mac.active = 'ring_top'; await dom.window.__thon.poll(); await settle();
  ok(qa(dom, '.chip').map(c => c.dataset.id).join() === 'ring_top,side,uncertain' && q(dom, '.chip.sel').dataset.id === 'ring_top', 'scheme edit: chips and selection follow the Mac', qa(dom, '.chip').map(c => c.dataset.id));
  ok(q(dom, '.chip i').style.background !== '', 'chip colors come from the scheme');
  // Mac changes the active label: phone follows
  mac.active = 'side'; await dom.window.__thon.poll(); await settle(); ok(dom.window.__thon.sel() === 'side', 'active label changed on the Mac is adopted');

  // 10. finishing a level, next micrograph
  mac.ids = ['z']; mac.total = 4; mac.reviewed = 3; await dom.window.__thon.poll(); await settle();
  q(dom, '#b-pick').click(); await settle(); await dom.window.__thon.flush(); await settle();
  ok(!q(dom, '#msg').hidden && q(dom, '#msg').textContent.includes('Micrograph finished'), 'done screen after the last card');
  [...q(dom, '#msg').querySelectorAll('button')].find(b => b.textContent === 'Next micrograph').click(); await settle();
  ok(mac.levelCalls.join() === 'next' && q(dom, '#levelname').textContent === 'n.mrc' && !q(dom, '#deck').hidden, 'Next micrograph opens the next level and its first card', q(dom, '#levelname').textContent);

  // 11. undo
  q(dom, '#b-pick').click(); await settle(); await dom.window.__thon.flush(); await settle();
  ok(!q(dom, '#b-undo').disabled, 'undo enabled once synced');
  q(dom, '#b-undo').click(); await settle(); ok(mac.undos === 1 && q(dom, '#frontimg').src.includes(encodeURIComponent('n.mrc@x')), 'undo restores the card');

  // 12. empty level, loading, auth failure
  mac.level.empty = true; mac.ids = []; await dom.window.__thon.poll(); await settle();
  ok(q(dom, '#msg').textContent.includes('No candidates here'), 'empty level message');
  [...q(dom, '#msg').querySelectorAll('button')].find(b => b.textContent === 'Find particles').click(); await settle(); ok(mac.autopicks === 1, 'Find particles calls the auto-picker');
  mac.level.empty = false; mac.level.loading = true; await dom.window.__thon.poll(); await settle();
  ok(q(dom, '#msg').textContent.includes('Opening micrograph'), 'loading message');
  mac.auth = false; await dom.window.__thon.poll().catch(() => {}); await settle();
  ok(q(dom, '#msg').textContent.includes('Not paired'), 'wrong or reset token shows a pairing message');
  dom.window.close();

  console.log('client tests: ' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log('ERROR', e); process.exit(2); });
