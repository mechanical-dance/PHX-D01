// Voice editing and mutes, as on the hardware: pick a voice, pick a page (OSC ... MIX), the 4 knobs edit the 4
// parameters on the display; pressing the page again shows its second row. SHIFT + voice mutes a voice.
// Page layouts come from the firmware's menu tables (pages.js).
'use strict';
const PAGE_NAMES = ['OSC', 'AEG', 'MOD', 'FM', 'CLICK', 'FILTER', 'LFO', 'MIX'];
const KIT_PARAMS = 247;
const MOD_TARGETS = 229;   // LXR2_NUM_MODTARGETS
Object.assign(state, { mode: 'load', voice: 0, page: 0, sub: 0, shift: false, drum: false, mutes: [0, 0, 0, 0, 0, 0, 0], params: [] });

// The 4 (or 8) slots of a page for a voice: [short, long, param, dtype]. The open hat edits the hihat voice,
// with its own decay in place of the closed one.
function pageSlots(voice, page) {
  const v = Math.min(voice, 5);
  return LXR_PAGES.pages[v][page].map(([s, , l, p, t]) => {
    if (voice === 6 && p === 60) return ['d2', 'Decay open', 61, t];
    return p > 0 && p < KIT_PARAMS ? [s, l, p, t] : null;
  });
}
function rowSlots() { return pageSlots(state.voice, state.page).slice(state.sub * 4, state.sub * 4 + 4); }

function range(t) {
  const kind = t & 0xff, menu = t >> 8;
  if (kind === 3) return [0, (LXR_PAGES.menus[menu]?.length || 1) - 1];
  if (kind === 6 || kind === 11) return [0, 1];
  if (kind === 7 || kind === 8) return [0, MOD_TARGETS - 1];
  if (kind === 9) return [1, 6];
  if (kind === 0) return [0, 255];
  return [0, 127];
}
function showValue(v, t) {
  const kind = t & 0xff, menu = t >> 8;
  if (kind === 3) return LXR_PAGES.menus[menu]?.[v] ?? String(v);
  if (kind === 4) return (v - 63 > 0 ? '+' : '') + (v - 63);
  if (kind === 6 || kind === 11) return v ? 'on' : 'off';
  if (kind === 9) return 'v' + v;
  if (kind === 7 || kind === 8) return 't' + v;
  return String(v);
}

function editRows() {
  const slots = rowSlots(), voice = TRIGGERS[state.voice];
  const names = slots.map((s, i) => !s ? '' : i === state.knobFocus && Date.now() < state.paramUntil ? s[0].toUpperCase() : s[0]);
  const vals = slots.map(s => (s ? showValue(state.params[s[2]] ?? 0, s[3]) : ''));
  const head = pad(`${voice} ${PAGE_NAMES[state.page]}${pageSlots(state.voice, state.page).slice(4).some(Boolean) ? (state.sub ? ' 2/2' : ' 1/2') : ''}`, 16);
  return Date.now() < state.paramUntil
    ? [names.map(n => pad(n, 4)).join(''), vals.map(v => pad(v, 4)).join('')]
    : [head, names.map(n => pad(n, 4)).join('')];
}

function editKnob(k, d) {
  const s = rowSlots()[k];
  if (!s || !state.params.length) return;
  const [lo, hi] = range(s[3]);
  const v = Math.min(hi, Math.max(lo, (state.params[s[2]] ?? 0) + d));
  if (v === state.params[s[2]]) return;
  state.params[s[2]] = v;
  const kit = state.kits[state.kit];
  if (kit) kit.edited = true;
  post({ cmd: 'param', i: s[2], v });
  if (typeof drawSide === 'function') drawSide();
}

function setMode(m) { state.mode = m; state.paramUntil = 0; refresh(); }
function selectPage(p) {
  if (state.mode === 'edit' && state.page === p && pageSlots(state.voice, p).slice(4).some(Boolean)) state.sub ^= 1;
  else { state.page = p; state.sub = 0; }
  state.mode = 'edit'; state.paramUntil = 0;
  refresh();
}
function toggleShift() { state.shift = !state.shift; refresh(); }
function toggleMute(t) {
  state.mutes[t] ^= 1;
  post({ cmd: 'mute', t, on: state.mutes[t] });
  refresh();
}
// Desktop voice button: SHIFT + voice mutes; in PERF mode the voice buttons mute on their own (manual p.14).
// Otherwise it plays the voice and selects it for editing.
function voicePress(t, e) {
  if (state.shift || e?.altKey || (state.hw === DESKTOP && state.mode === 'perf')) { toggleMute(t); return; }
  hit(t, e?.shiftKey);
  if (state.voice !== t) { state.voice = t; state.sub = 0; if (state.mode === 'edit') refresh(); }
}
// Module select buttons (manual p.14): with DRUM held they pick the voice, in edit mode they pick the page, in
// perform mode they play. A mouse can't hold two buttons, so DRUM and SHIFT latch, and shift-click works too.
const MODULE_PAGES = [0, 1, 2, 3, 4, 5, 7];
function modulePress(i, e) {
  if (state.mode === 'edit' && (state.drum || state.shift || e?.shiftKey)) {
    state.voice = i; state.sub = 0; state.drum = false; state.shift = false; state.paramUntil = 0;
    hit(i);
    refresh(); return;
  }
  if (state.mode === 'edit') { selectPage(MODULE_PAGES[i]); return; }
  if (state.shift || e?.altKey) { toggleMute(i); return; }
  hit(i, e?.shiftKey);
}
function perfRows() {
  return ['Perf: mutes', TRIGGERS.map((_, t) => (state.mutes[t] ? '-' : String(t + 1))).join(' ')];
}

function markButtons() {
  (ui.trig || []).forEach((nodes, t) => nodes.forEach(n => n.classList.toggle('muted', !!state.mutes[t])));
  (ui.pages || []).forEach((n, p) => n.classList.toggle('on', state.mode === 'edit' && state.page === p));
  ui.shift?.classList.toggle('on', state.shift);
  ui.drum?.classList.toggle('on', state.drum);
  ui.edit?.classList.toggle('on', state.mode === 'edit');
  ui.perf?.classList.toggle('on', state.mode === 'perf' || (state.hw === MODULE && state.mode !== 'edit'));
}

// Option + 1-7 mutes from the keyboard.
document.addEventListener('keydown', e => {
  if (!e.altKey || e.metaKey || /SELECT|INPUT/.test(e.target.tagName)) return;
  const n = e.code.startsWith('Digit') ? +e.code.slice(5) : 0;
  if (n >= 1 && n <= 7) { toggleMute(n - 1); e.preventDefault(); e.stopImmediatePropagation(); }
}, true);

// Absolute knob access in voice edit mode (null on the kit display or an empty slot).
function knobInfo(k) {
  if (state.mode !== 'edit') return null;
  const s = rowSlots()[k];
  if (!s || !state.params.length) return null;
  const [lo, hi] = range(s[3]);
  return { v: state.params[s[2]] ?? 0, lo, hi };
}
function knobSet(k, v) {
  const info = knobInfo(k);
  if (!info) return;
  state.knobFocus = k; state.paramUntil = Date.now() + 2500;
  editKnob(k, Math.min(info.hi, Math.max(info.lo, v)) - info.v);
  refresh(); clearTimeout(knobSet.t); knobSet.t = setTimeout(refresh, 2600);
}
function knobReset(k) {
  const s = rowSlots()[k];
  if (s && state.savedParams) knobSet(k, state.savedParams[s[2]]);
}
