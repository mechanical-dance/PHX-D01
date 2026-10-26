// PHX-D01 front panels. Draws the LXR-02 desktop or the LXR-Drum module in SVG and sends commands to the
// native host (window.webkit.messageHandlers.lxr). Layouts follow the panel drawings in both owner's manuals.
'use strict';
const NS = 'http://www.w3.org/2000/svg';
const post = m => window.webkit?.messageHandlers?.lxr ? window.webkit.messageHandlers.lxr.postMessage(m) : console.log('post', m);

const DESKTOP = 0, MODULE = 1;
const TRIGGERS = ['DRUM1', 'DRUM2', 'DRUM3', 'SNARE', 'CLP/CYM', 'CL HH', 'OP HH'];
const ACCENT_OF = [0, 1, 2, 3, 4, 5, 5];   // the open hat shares the hihat voice, so accent 6
const state = {
  hw: DESKTOP, engine: 0, engines: ['LXR-2', 'LXR-1'], kits: [], kit: 0,
  vel: 100,           // desktop: velocity of hits (shift = 127)
  base: 64,           // module: velocity of an unaccented trigger (assumed; accented = 127)
  solo: 0,            // 0 = mix, 1-4 = jack
  accent: [0, 0, 0, 0, 0, 0],   // module: accent jack held high (patched)
  faders: [1, 1, 1, 1, 1, 1, 1],
  knobFocus: -1, paramUntil: 0,
};
const ui = {};   // live element references for the current panel

// ---------- SVG helpers ----------
function el(tag, attrs, parent) {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (parent) parent.appendChild(e);
  return e;
}
function label(parent, x, y, str, cls = 'lbl', anchor = 'middle') {
  const lines = String(str).split('\n');
  const t = el('text', { x, y, class: cls, 'text-anchor': anchor }, parent);
  lines.forEach((ln, i) => { const s = el('tspan', { x, dy: i ? '1.15em' : 0 }, t); s.textContent = ln; });
  return t;
}
function defs(svg) {
  const d = el('defs', {}, svg);
  const radial = (id, stops, cx = '35%', cy = '30%') => {
    const g = el('radialGradient', { id, cx, cy, r: '75%' }, d);
    stops.forEach(([o, c]) => el('stop', { offset: o, 'stop-color': c }, g));
  };
  const linear = (id, stops, x2 = '0', y2 = '1') => {
    const g = el('linearGradient', { id, x1: 0, y1: 0, x2, y2 }, d);
    stops.forEach(([o, c]) => el('stop', { offset: o, 'stop-color': c }, g));
  };
  radial('btnGrad', [[0, '#a9a8a4'], [0.7, '#77766f'], [1, '#55544f']]);
  radial('btnGradDim', [[0, '#6f6e6a'], [1, '#43423f']]);
  radial('knobGrad', [[0, '#f1f0ec'], [0.55, '#c4c3be'], [1, '#86857f']]);
  radial('nutGrad', [[0, '#e6e6e6'], [1, '#8f8f8f']]);
  linear('faderGrad', [[0, '#e8e8e8'], [0.5, '#9a9a9a'], [1, '#d0d0d0']]);
  linear('lcdGrad', [[0, '#e0473b'], [1, '#b8261f']]);
  const glow = el('filter', { id: 'glow', x: '-50%', y: '-50%', width: '200%', height: '200%' }, d);
  el('feGaussianBlur', { stdDeviation: 2.2, result: 'b' }, glow);
  const m = el('feMerge', {}, glow); el('feMergeNode', { in: 'b' }, m); el('feMergeNode', { in: 'SourceGraphic' }, m);
  const gr = el('filter', { id: 'glowRed', x: '-20%', y: '-50%', width: '140%', height: '200%' }, d);
  el('feGaussianBlur', { stdDeviation: 1.2, result: 'b' }, gr);
  const m2 = el('feMerge', {}, gr); el('feMergeNode', { in: 'b' }, m2); el('feMergeNode', { in: 'SourceGraphic' }, m2);
}

// ---------- controls ----------
function button(parent, x, y, r, onPress, opts = {}) {
  const g = el('g', { class: 'btn' + (onPress ? '' : ' inert') }, parent);
  if (opts.square) el('rect', { class: 'cap', x: x - r, y: y - r, width: 2 * r, height: 2 * r, rx: r * 0.22 }, g);
  else el('circle', { class: 'cap', cx: x, cy: y, r }, g);
  if (opts.title || !onPress) el('title', {}, g).textContent = opts.title || 'Not modeled: this app auditions kits';
  if (onPress) {
    g.addEventListener('pointerdown', e => { g.classList.add('down'); onPress(e); });
    const up = () => g.classList.remove('down');
    g.addEventListener('pointerup', up); g.addEventListener('pointerleave', up);
  }
  return g;
}
function flash(node, ms = 110) {
  if (!node) return;
  node.classList.add('lit');
  clearTimeout(node._t);
  node._t = setTimeout(() => node.classList.remove('lit'), ms);
}
// Vertical drag or scroll turns a control in steps.
function turnable(node, onStep, px = 7) {
  node.addEventListener('pointerdown', e => {
    node.setPointerCapture(e.pointerId);
    let y0 = e.clientY;
    const move = ev => { const d = Math.trunc((y0 - ev.clientY) / px); if (d) { onStep(d); y0 -= d * px; } };
    const up = () => { node.removeEventListener('pointermove', move); node.removeEventListener('pointerup', up); };
    node.addEventListener('pointermove', move); node.addEventListener('pointerup', up);
  });
  let acc = 0;
  node.addEventListener('wheel', e => {
    e.preventDefault();
    acc -= e.deltaY;
    while (Math.abs(acc) >= 24) { onStep(Math.sign(acc)); acc -= Math.sign(acc) * 24; }
  }, { passive: false });
}
// Knobs show the value they edit: angle and arc over -135..135 degrees. In voice edit mode a drag of ~160 px sweeps
// the whole range (shift: fine), the wheel moves one step, double-click restores the kit's saved value.
// On the kit display they step through kit, engine, velocity and output like the hardware.
const ARC = 135;
function arcPath(x, y, r, a0, a1) {
  const p = a => [x + r * Math.sin(a * Math.PI / 180), y - r * Math.cos(a * Math.PI / 180)];
  const [x0, y0] = p(a0), [x1, y1] = p(a1);
  return `M${x0} ${y0} A${r} ${r} 0 ${a1 - a0 > 180 ? 1 : 0} 1 ${x1} ${y1}`;
}
function knob(parent, x, y, r, onStep, title, k) {
  const g = el('g', { class: 'knob' }, parent);
  el('path', { class: 'track', d: arcPath(x, y, r + 7, -ARC, ARC) }, g);
  const arc = el('path', { class: 'arc', d: '' }, g);
  el('circle', { class: 'body', cx: x, cy: y, r }, g);
  const mark = el('line', { class: 'mark', x1: x, y1: y - r * 0.35, x2: x, y2: y - r * 0.85 }, g);
  el('title', {}, g).textContent = title;
  const kn = { g, arc, mark, x, y, r, angle: 0 };
  (ui.knobs ||= [])[k] = kn;
  g.addEventListener('pointerdown', e => {
    g.setPointerCapture(e.pointerId);
    const info = knobInfo(k), y0 = e.clientY;
    let last = e.clientY;
    const move = ev => {
      if (info) {
        const span = info.hi - info.lo, px = ev.shiftKey ? 600 : 160;
        knobSet(k, Math.round(info.v + (y0 - ev.clientY) * span / px));
      } else {
        const d = Math.trunc((last - ev.clientY) / 12);
        if (d) { onStep(d); last -= d * 12; kn.angle += d * 18; drawKnobs(); }
      }
    };
    const up = () => { g.removeEventListener('pointermove', move); g.removeEventListener('pointerup', up); };
    g.addEventListener('pointermove', move); g.addEventListener('pointerup', up);
  });
  g.addEventListener('wheel', e => {
    e.preventDefault();
    kn.acc = (kn.acc || 0) - e.deltaY;
    while (Math.abs(kn.acc) >= 24) {
      const d = Math.sign(kn.acc); kn.acc -= d * 24;
      const info = knobInfo(k);
      if (info) knobSet(k, info.v + d); else { onStep(d); kn.angle += d * 18; drawKnobs(); }
    }
  }, { passive: false });
  g.addEventListener('dblclick', () => knobReset(k));
  return g;
}
function drawKnobs() {
  (ui.knobs || []).forEach((kn, k) => {
    if (!kn) return;
    const info = knobInfo(k);
    const a = info ? -ARC + 2 * ARC * (info.v - info.lo) / Math.max(1, info.hi - info.lo) : kn.angle;
    kn.mark.setAttribute('transform', `rotate(${a} ${kn.x} ${kn.y})`);
    kn.arc.setAttribute('d', info ? arcPath(kn.x, kn.y, kn.r + 7, -ARC, Math.max(a, -ARC + 0.5)) : '');
    kn.g.classList.toggle('idle', state.mode === 'edit' && !info);
  });
}
function encoder(parent, x, y, r, onStep) {
  const g = el('g', { class: 'knob enc' }, parent);
  for (let i = 0; i < 36; i++) {
    const a = (i / 36) * Math.PI * 2;
    el('line', { class: 'tick', x1: x + Math.cos(a) * (r + 4), y1: y + Math.sin(a) * (r + 4), x2: x + Math.cos(a) * (r + 9), y2: y + Math.sin(a) * (r + 9) }, g);
  }
  el('circle', { class: 'body', cx: x, cy: y, r }, g);
  const grip = el('g', {}, g);
  const pts = [];
  for (let i = 0; i < 16; i++) {
    const a = (i / 16) * Math.PI * 2, rr = i % 2 ? r * 0.78 : r * 0.92;
    pts.push(`${x + Math.cos(a) * rr},${y + Math.sin(a) * rr}`);
  }
  el('polygon', { class: 'grip', points: pts.join(' ') }, grip);
  el('circle', { cx: x, cy: y, r: r * 0.55, fill: '#202020' }, grip);
  el('title', {}, g).textContent = 'DATA: turn (drag or scroll) to browse kits';
  let angle = 0;
  turnable(g, d => { angle += d * 11; grip.setAttribute('transform', `rotate(${angle} ${x} ${y})`); onStep(d); }, 5);
  return g;
}
function jack(parent, x, y, onPress, title, opts = {}) {
  const g = el('g', { class: 'jack' + (onPress ? '' : ' inert') }, parent);
  const pts = [];
  for (let i = 0; i < 6; i++) { const a = Math.PI / 6 + (i * Math.PI) / 3; pts.push(`${x + Math.cos(a) * 15},${y + Math.sin(a) * 15}`); }
  el('circle', { class: 'glow', cx: x, cy: y, r: 17 }, g);
  el('polygon', { class: 'nut', points: pts.join(' ') }, g);
  el('circle', { class: 'ring', cx: x, cy: y, r: 9.5 }, g);
  el('circle', { class: 'hole', cx: x, cy: y, r: 5 }, g);
  const plug = el('g', { class: 'plug' }, g);   // a patch cable plug, shown when "patched"
  el('circle', { cx: x, cy: y, r: 10.5, fill: opts.plug || '#e4572e', stroke: '#111', 'stroke-width': 1 }, plug);
  el('circle', { cx: x, cy: y, r: 4.5, fill: '#111', opacity: 0.35 }, plug);
  el('title', {}, g).textContent = title;
  if (onPress) g.addEventListener('pointerdown', onPress);
  return g;
}
function fader(parent, x, top, bottom, i) {
  const g = el('g', { class: 'fader' }, parent);
  el('rect', { class: 'slot', x: x - 4, y: top, width: 8, height: bottom - top, rx: 3 }, g);
  for (let k = 0; k <= 10; k++) el('line', { x1: x - 16, x2: x - 10, y1: top + ((bottom - top) * k) / 10, y2: top + ((bottom - top) * k) / 10, stroke: '#555', 'stroke-width': 1 }, g);
  const cap = el('g', {}, g);
  el('rect', { class: 'capb', x: x - 15, y: -9, width: 30, height: 18, rx: 2 }, cap);
  el('line', { class: 'capl', x1: x - 13, x2: x + 13, y1: 0, y2: 0 }, cap);
  el('title', {}, g).textContent = i === 6 ? 'VOLUME (master)' : 'Voice fader';
  const place = v => cap.setAttribute('transform', `translate(0 ${bottom - v * (bottom - top)})`);
  place(state.faders[i]);
  const svg = parent.ownerSVGElement || parent;
  const setFromEvent = e => {
    const p = svg.createSVGPoint(); p.x = e.clientX; p.y = e.clientY;
    const loc = p.matrixTransform(svg.getScreenCTM().inverse());
    const v = Math.min(1, Math.max(0, (bottom - loc.y) / (bottom - top)));
    state.faders[i] = v; place(v); post({ cmd: 'fader', i, pos: v });
  };
  g.addEventListener('pointerdown', e => {
    g.setPointerCapture(e.pointerId); setFromEvent(e);
    const move = ev => setFromEvent(ev);
    const up = () => { g.removeEventListener('pointermove', move); g.removeEventListener('pointerup', up); };
    g.addEventListener('pointermove', move); g.addEventListener('pointerup', up);
  });
  return g;
}

// ---------- actions ----------
function hit(t, accented) {
  let vel = accented ? 127 : state.vel;   // shift: an accent on the module, full velocity on the desktop
  if (state.hw === MODULE) vel = accented || state.accent[ACCENT_OF[t]] ? 127 : state.base;
  post({ cmd: 'hit', t, vel });
  (ui.trig?.[t] || []).forEach(n => flash(n));
  if (state.hw === MODULE && (accented || state.accent[ACCENT_OF[t]])) flash(ui.acc?.[ACCENT_OF[t]], 160);
}
function setKit(i) {
  if (!state.kits.length) return;
  state.kit = ((i % state.kits.length) + state.kits.length) % state.kits.length;
  post({ cmd: 'kit', i: state.kit });
  state.paramUntil = 0;
  refresh();
}
function setEngine(i) { state.engine = (i + state.engines.length) % state.engines.length; post({ cmd: 'engine', i: state.engine }); refresh(); }
function setSolo(j) { state.solo = ((j % 5) + 5) % 5; post({ cmd: 'solo', jack: state.solo }); refresh(); }
function setHw(h) {
  state.hw = h;
  post({ cmd: 'hw', v: h });
  if (state.solo) setSolo(0);
  build();
  if (typeof sendPattern === 'function') sendPattern();
}
function openFolder() { post({ cmd: 'open' }); }

// The 4 knobs edit what the display shows, like the hardware's menu pages.
const KNOBS = [
  { name: 'kit', step: d => setKit(state.kit + d) },
  { name: 'eng', step: d => setEngine(state.engine + d) },
  { name: () => (state.hw === DESKTOP ? 'vel' : 'bas'),
    step: d => { if (state.hw === DESKTOP) state.vel = Math.min(127, Math.max(1, state.vel + d * 4)); else { state.base = Math.min(127, Math.max(1, state.base + d * 4)); if (typeof sendPattern === 'function') sendPattern(); } } },
  { name: 'out', step: d => setSolo(state.solo + d) },
];
function turnKnob(k, d) {
  state.knobFocus = k; state.paramUntil = Date.now() + 2500;
  if (state.mode === 'edit') editKnob(k, d); else KNOBS[k].step(d);
  refresh(); setTimeout(refresh, 2600);
}

// ---------- display ----------
const pad = (s, n) => String(s).slice(0, n).padEnd(n);
const OUT_NAMES = [['mix', 'mnL', 'mnR', 'o2L', 'o2R'], ['mix', 'o1', 'o2', 'o3', 'o4']];
function displayRows() {
  if (state.mode === 'edit') return editRows();
  if (state.mode === 'perf') return perfRows();
  const k = state.kits[state.kit];
  if (Date.now() < state.paramUntil) {
    const names = KNOBS.map((kn, i) => { const n = typeof kn.name === 'function' ? kn.name() : kn.name; return i === state.knobFocus ? n.toUpperCase() : n; });
    const vals = [String(state.kit + 1), state.engine === 0 ? 'LX2' : 'LX1', String(state.hw === DESKTOP ? state.vel : state.base), OUT_NAMES[state.hw][state.solo]];
    return [names.map(n => pad(n, 4)).join(''), vals.map(v => pad(v, 4)).join('')];
  }
  if (!k) return ['Load: Kit', 'no kits: LOAD'];
  return [pad(pad(k.bank, 12), 12) + (state.engine === 0 ? 'LX2' : 'LX1'), `[${String(bankNumber(state.kit) - 1).padStart(2, '0')}] ${k.name}`];
}
// Kits grouped by bank (one bank per folder), numbered within their bank.
// A kit's number is the NN- slot in its file name (1-based here, as the callers subtract 1), not its place in the list.
function bankNumber(i) { const n = parseInt(state.kits[i]?.file, 10); return Number.isNaN(n) ? 0 : n + 1; }
function sharesSlot(i) { const k = state.kits[i]; return state.kits.some((o, j) => j !== i && o.bank === k.bank && parseInt(o.file, 10) === parseInt(k.file, 10)); }
function bankNames() { return [...new Set(state.kits.map(k => k.bank || 'Kits'))]; }
// Kit menus: one bank at a time in the kit menu, every bank (grouped) for the morph target.
function fillKits(s, bank) {
  s.replaceChildren();
  let group = null;
  state.kits.forEach((k, i) => {
    if (bank !== undefined && k.bank !== bank) return;
    if (bank === undefined && (!group || group.label !== (k.bank || 'Kits'))) { group = document.createElement('optgroup'); group.label = k.bank || 'Kits'; s.appendChild(group); }
    const o = document.createElement('option');
    o.value = i; o.textContent = `${String(bankNumber(i) - 1).padStart(2, '0')}  ${k.name}${k.virtual ? '' : '  (' + k.file + ')'}${sharesSlot(i) ? '  ⚠ same slot' : ''}`;
    (group || s).appendChild(o);
  });
}
function fillBanks() {
  const b = document.getElementById('bank'), names = bankNames(), cur = state.kits[state.kit]?.bank;
  if (b.dataset.names !== names.join('|')) {
    b.replaceChildren(...names.map(n => Object.assign(document.createElement('option'), { value: n, textContent: n })));
    b.dataset.names = names.join('|');
  }
  b.value = cur ?? '';
  const sel = document.getElementById('kits');
  if (sel.dataset.bank !== cur || sel.dataset.n !== String(state.kits.length)) { fillKits(sel, cur); sel.dataset.bank = cur; sel.dataset.n = state.kits.length; }
  sel.value = state.kit;
}
function sendMorph() {
  post({ cmd: 'morph', amount: +document.getElementById('morph').value, target: +document.getElementById('mtg').value || 0 });
}

function refresh() {
  const [r1, r2] = displayRows();
  if (ui.row1) { ui.row1.textContent = pad(r1, 16); ui.row2.textContent = pad(r2, 16); }
  document.querySelectorAll('#hw button').forEach(b => b.setAttribute('aria-checked', String(+b.dataset.v === state.hw)));
  document.querySelectorAll('#engine button').forEach(b => b.setAttribute('aria-checked', String(+b.dataset.v === state.engine)));
  const mtg = document.getElementById('mtg');
  fillBanks();
  if (mtg.dataset.n !== String(state.kits.length)) { fillKits(mtg); mtg.dataset.n = state.kits.length; }
  if (mtg.value === '' && state.kits.length) mtg.value = 0;
  (ui.outs || []).forEach((n, j) => n.classList.toggle('patched', state.solo === j + 1));
  (ui.acc || []).forEach((n, j) => n.classList.toggle('patched', !!state.accent[j]));
  markButtons();
  drawKnobs();
  document.getElementById('hint').textContent = state.hw === DESKTOP
    ? '1–7 trigger · space play · [ ] velocity · ←/→ kit · e engine · o jack · m hardware'
    : '1–7 trigger · shift accent · click ACC to hold · space play · ←/→ kit · o jack · m hardware';
}

function display(g, x, y, w, h, kind) {
  if (kind === 'lcd') {
    el('rect', { class: 'lcd-bg', x, y, width: w, height: h, rx: 4 }, g);
    ui.row1 = label(g, x + 14, y + 33, '', 'lcd', 'start');
    ui.row2 = label(g, x + 14, y + 66, '', 'lcd', 'start');
  } else {
    el('rect', { class: 'seg-bg', x, y, width: w, height: h, rx: 3 }, g);
    label(g, x + 10, y + 30, '8'.repeat(16), 'seg-ghost', 'start');
    label(g, x + 10, y + 61, '8'.repeat(16), 'seg-ghost', 'start');
    ui.row1 = label(g, x + 10, y + 30, '', 'seg-txt', 'start');
    ui.row2 = label(g, x + 10, y + 61, '', 'seg-txt', 'start');
  }
  for (const r of [ui.row1, ui.row2]) { r.setAttribute('xml:space', 'preserve'); r.style.whiteSpace = 'pre'; }
}

// ---------- LXR-02 desktop ----------
function buildDesktop(svg) {
  svg.setAttribute('viewBox', '0 0 1000 585');
  el('rect', { class: 'face', x: 0, y: 0, width: 1000, height: 585, rx: 10 }, svg);
  const g = el('g', {}, svg);
  ui.trig = TRIGGERS.map(() => []);

  // back-panel connectors along the top edge; the four audio outs are clickable to solo
  [['12V DC', 70], ['OFF / ON', 140], ['CLK IN', 205], ['CLK OUT', 258], ['RST IN', 312], ['SD CARD', 366], ['USB', 425], ['MIDI IN', 520], ['MIDI OUT', 590]]
    .forEach(([t, x]) => label(g, x, 30, t, 'lbl small dim'));
  label(g, 727, 22, 'OUT 2', 'lbl small'); label(g, 885, 22, 'MAIN OUT', 'lbl small'); label(g, 965, 30, 'PHONES', 'lbl small dim');
  ui.outs = [];
  [[850, 'L', 1], [920, 'R', 2], [692, 'L', 3], [762, 'R', 4]].forEach(([x, side, j]) => {
    const n = jack(g, x, 46, () => setSolo(state.solo === j ? 0 : j), `${j <= 2 ? 'MAIN OUT' : 'OUT 2'} ${side}: click to hear only this jack`, { plug: '#3fb6c9' });
    n.setAttribute('transform', `translate(${x} 46) scale(.62) translate(${-x} -46)`);
    label(g, x, 30, side, 'lbl small');
    ui.outs[j - 1] = n;
  });

  // logo and display
  label(g, 240, 128, 'PHX-D01', 'logo'); label(g, 240, 162, 'KIT AUDITIONER', 'logo sub');
  display(g, 88, 182, 304, 86, 'lcd');
  [115, 195, 275, 355].forEach((x, k) => knob(g, x, 330, 27, d => turnKnob(k, d), 'Knob ' + (k + 1) + ': drag or scroll; double-click resets', k));
  encoder(g, 505, 205, 50, d => setKit(state.kit + d));
  label(g, 505, 282, 'DATA', 'lbl');

  // faders: six voices and master volume
  ['DRUM1', 'DRUM2', 'DRUM3', 'SNARE', 'CLP/CYM', 'HIHATS', 'VOLUME'].forEach((t, i) => {
    const x = 640 + i * 50;
    label(g, x, 120, t, 'lbl small');
    fader(g, x, 140, 295, i);
  });

  // BAR arrows browse kits
  label(g, 525, 330, 'BAR', 'lbl small');
  button(g, 505, 350, 10, () => setKit(state.kit - 1), { title: 'Previous kit' });
  button(g, 545, 350, 10, () => setKit(state.kit + 1), { title: 'Next kit' });
  label(g, 505, 375, '◄', 'lbl small'); label(g, 545, 375, '►', 'lbl small');
  // voice buttons under the faders
  TRIGGERS.forEach((t, i) => {
    const x = 640 + i * 50;
    label(g, x, 330, t, 'lbl small');
    ui.trig[i].push(button(g, x, 350, 10, e => voicePress(i, e), { title: `${t}: play and select for editing · SHIFT (or ⌥) mutes` }));
  });

  // menu rows
  const row = (items, y) => items.map(([t, x, fn, title]) => { const b = button(g, x, y, 10, fn, { title }); label(g, x, y + 24, t, 'lbl small'); return b; });
  [ui.shift] = row([['SHIFT', 75, toggleShift, 'Latch SHIFT: voice buttons then mute/unmute'], ['PLAY', 135, () => window.seqToggle?.(), 'Play/stop the sequencer'], ['REC', 180], ['COPY', 232]], 420);
  [ui.edit, ui.perf] = row([['VOICE', 300, () => setMode('edit'), 'Edit the selected voice'], ['PERF', 355, () => setMode('perf'), 'Performance: voice buttons mute/unmute'], ['LOAD', 410, () => state.mode !== 'load' ? setMode('load') : openFolder(), 'Kit display; again to open a kit folder'], ['SAVE', 465, () => phx.save(), 'Save the kit and the project (⌘S)']], 420);
  ui.pages = row(PAGE_NAMES.slice(0, 8).map((t, i) => [t, 560 + i * 55, () => selectPage(i), `${t} page of the selected voice; again for its second row`]), 420);
  // the 16 step buttons; the first seven are the voices
  ['DRUM1', 'DRUM2', 'DRUM3', 'SNARE', 'CLP/CYM', 'CL HH', 'OP HH', 'KIT', 'MORPH', 'SONG', 'PROJECT', 'CONFIG', 'RELOAD', 'LAST STEP', 'FX', 'PATTERN']
    .forEach((t, i) => {
      const x = 72 + i * 57.2;
      const fx = i === 14 ? e => { if (state.shift || e?.shiftKey) fxPress(); } : null;
      const b = button(g, x, 498, 22, i < 7 ? e => voicePress(i, e) : fx,
        { square: true, title: i < 7 ? `${t}: play and select · SHIFT (or ⌥) mutes` : i === 14 ? "SHIFT + FX: the kit's effect" : undefined });
      if (i < 7) ui.trig[i].push(b);
      label(g, x, 536, t, 'lbl small');
    });
  label(g, 50, 570, 'PHX-D01', 'model', 'start');
  label(g, 950, 568, 'LXR-02 DESKTOP LAYOUT', 'brand', 'end');
}

// ---------- LXR-Drum module ----------
function buildModule(svg) {
  svg.setAttribute('viewBox', '0 0 640 595');
  el('rect', { class: 'face module', x: 0, y: 0, width: 640, height: 595, rx: 6 }, svg);
  const g = el('g', {}, svg);
  [[14, 14], [626, 14], [14, 581], [626, 581]].forEach(([x, y]) => el('circle', { cx: x, cy: y, r: 4.5, fill: '#0c0c0c', stroke: '#3a3a3a' }, g));
  ui.trig = TRIGGERS.map(() => []);
  ui.acc = []; ui.outs = [];
  const xs = i => 62 + i * 51.6;

  // jack row 1: 7 trigger inputs, 4 audio outs
  TRIGGERS.forEach((t, i) => {
    label(g, xs(i), 68, t, 'lbl small');
    ui.trig[i].push(jack(g, xs(i), 92, e => hit(i, e.shiftKey), `Trigger in ${i + 1} (${t}): click to fire, shift-click for an accented hit`));
  });
  ['OUT1', 'OUT2', 'OUT3', 'OUT4'].forEach((t, j) => {
    label(g, xs(7 + j), 68, t, 'lbl small');
    ui.outs[j] = jack(g, xs(7 + j), 92, () => setSolo(state.solo === j + 1 ? 0 : j + 1), `${t}: click to hear only this jack`, { plug: '#3fb6c9' });
  });
  // jack row 2: 6 accent inputs, 5 CV inputs
  for (let a = 0; a < 6; a++) {
    label(g, xs(a), 126, 'ACC' + (a + 1), 'lbl small');
    ui.acc[a] = jack(g, xs(a), 150, () => { state.accent[a] ^= 1; refresh(); }, `Accent in ${a + 1}: click to hold the accent gate high${a === 5 ? ' (hihat: both CL HH and OP HH)' : ''}`);
  }
  for (let c = 0; c < 5; c++) {
    label(g, xs(6 + c), 126, 'CV' + (c + 1), 'lbl small');
    jack(g, xs(6 + c), 150, null, `CV in ${c + 1}: not modeled yet (it feeds the kit's mod matrix)`);
  }

  // mode buttons
  const mode = (t, x, y, fn, title) => { label(g, x, y - 20, t, 'lbl small'); return button(g, x, y, 12, fn, { title }); };
  ui.edit = mode('EDIT', 66, 222, () => setMode('edit'), 'Edit voices: select buttons pick the page'); ui.perf = mode('PERFORM', 120, 222, () => setMode('load'), 'Perform: select buttons play the voices');
  ui.mod = mode('MOD', 66, 278, modPress, 'MOD: modulation page of the voice · SHIFT + MOD (or shift-click): its LFO'); ui.fx = mode('FX', 120, 278, fxPress, "FX: the kit's effect");
  ui.shift = mode('SHIFT', 66, 334, toggleShift, 'Latch SHIFT: select buttons then mute (perform mode)'); mode('SAVE/LOAD', 120, 334, openFolder, 'Open a folder of .SND kits');
  el('path', { d: 'M54 352 v8 h78 v-8', fill: 'none', stroke: '#9a9893', 'stroke-width': 1 }, g);
  label(g, 93, 374, 'CONFIG', 'lbl small dim');

  display(g, 180, 238, 290, 76, 'seg');
  label(g, 560, 210, 'DATA', 'lbl small');
  encoder(g, 560, 272, 40, d => setKit(state.kit + d));
  [205, 300, 395, 490].forEach((x, k) => knob(g, x, 395, 27, d => turnKnob(k, d), 'Knob ' + (k + 1) + ': drag or scroll; double-click resets', k));

  // DRUM + select buttons; in perform mode the select buttons fire the voices
  el('rect', { x: 38, y: 440, width: 64, height: 88, rx: 4, fill: '#2b2b2d' }, g);
  label(g, 70, 460, 'DRUM', 'lbl small');
  ui.drum = button(g, 70, 498, 17, () => { state.drum = !state.drum; refresh(); }, { title: 'DRUM, then a select button: choose the voice to edit' });
  [['OSC', 'DRUM1'], ['AEG', 'DRUM2'], ['MOD', 'DRUM3'], ['FM', 'SNARE'], ['CLICK', 'CLP/CYM'], ['FILTER', 'CL HH'], ['MIX', 'OP HH']]
    .forEach(([a, b], i) => {
      const x = 150 + i * 68;
      label(g, x, 452, a + '\n' + b, 'lbl small');
      ui.trig[i].push(button(g, x, 498, 17, e => modulePress(i, e), { title: `${b}: fire (perform), ${a} page (edit), voice (after DRUM); shift-click accent` }));
    });
  label(g, 40, 566, 'PHX-D01', 'model', 'start');
  label(g, 604, 564, 'LXR-DRUM MODULE LAYOUT', 'brand', 'end');
}

function build() {
  const svg = document.getElementById('panel');
  svg.replaceChildren();
  for (const k of Object.keys(ui)) delete ui[k];
  defs(svg);
  (state.hw === DESKTOP ? buildDesktop : buildModule)(svg);
  refresh();
}

// ---------- toolbar and keys ----------
function initToolbar() {
  document.querySelectorAll('#hw button').forEach(b => b.addEventListener('click', () => setHw(+b.dataset.v)));
  const eng = document.getElementById('engine');
  eng.replaceChildren();
  state.engines.forEach((n, i) => {
    const b = document.createElement('button');
    b.dataset.v = i;
    b.textContent = n === 'LXR-2' ? 'LXR-2 engine (Erica fw)' : n === 'LXR-1' ? 'LXR-1 engine (open fw)' : n;
    b.addEventListener('click', () => setEngine(i));
    eng.appendChild(b);
  });
  document.getElementById('kits').onchange = e => setKit(+e.target.value);
  document.getElementById('bank').onchange = e => setKit(state.kits.findIndex(k => k.bank === e.target.value));
  document.getElementById('open').onclick = openFolder;
  document.getElementById('morph').oninput = sendMorph;
  document.getElementById('mtg').onchange = sendMorph;
  const showSeq = on => {
    document.getElementById('seq').hidden = !on;
    document.getElementById('seqbtn').setAttribute('aria-pressed', String(on));
    try { localStorage.setItem('seqShown', on ? '1' : '0'); } catch (e) { /* per-viewer nicety only */ }
  };
  let shown = true;
  try { shown = localStorage.getItem('seqShown') !== '0'; } catch (e) { /* default: shown */ }
  showSeq(shown);
  document.getElementById('seqbtn').onclick = () => showSeq(document.getElementById('seq').hidden);
}
document.addEventListener('keydown', e => {
  if (/SELECT|INPUT/.test(e.target.tagName) || e.metaKey || e.ctrlKey) return;
  const n = e.code.startsWith('Digit') ? +e.code.slice(5) : 0;
  if (n >= 1 && n <= 7) { if (!e.repeat) hit(n - 1, e.shiftKey); }
  else if (e.key === 'ArrowRight' || e.key === 'l') setKit(state.kit + 1);
  else if (e.key === 'ArrowLeft' || e.key === 'h') setKit(state.kit - 1);
  else if (e.key === 'e') setEngine(state.engine + 1);
  else if (e.key === 'm') setHw(1 - state.hw);
  else if (e.key === 'o') turnKnob(3, 1);
  else if (e.key === ']') turnKnob(2, 1);
  else if (e.key === '[') turnKnob(2, -1);
  else if (e.code === 'Space') window.seqToggle?.();
  else return;
  e.preventDefault();
});

// Called by the host with {engines, kits: [{name, file}], kit, folder}.
window.lxrState = s => {
  if (s.params) { state.params = s.params.slice(); state.savedParams = s.params.slice(); }
  const enginesChanged = s.engines && s.engines.join() !== state.engines.join();
  Object.assign(state, s);
  if (enginesChanged) initToolbar();
  refresh();
};

// Start once every script (edit, sequencer, files) has loaded.
document.addEventListener('DOMContentLoaded', () => {
  initToolbar();
  build();
  post({ cmd: 'ready' });
});
