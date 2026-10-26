// Voice editing and mutes, as on the hardware: pick a voice, pick a page (OSC ... MIX), the 4 knobs edit the 4
// parameters on the display; pressing the page again shows its second row. SHIFT + voice mutes a voice.
// Page layouts come from the firmware's menu tables (pages.js).
'use strict';
const PAGE_NAMES = ['OSC', 'AEG', 'MOD', 'FM', 'CLICK', 'FILTER', 'LFO', 'MIX', 'FX'];
const MOD_PAGE = 2, LFO_PAGE = 6, FX_PAGE = 8;   // LFO n belongs to voice n; FX is the kit's one effect
const MATRIX_PAGE = 9;   // module: the voice's 3-slot mod matrix (MOD button), slots a/b/c as sub pages
const FX_TYPE = 234;
const KIT_PARAMS = 247;
const MOD_TARGETS = 229;   // LXR2_NUM_MODTARGETS
Object.assign(state, { mode: 'load', voice: 0, page: 0, sub: 0, shift: false, drum: false, mutes: [0, 0, 0, 0, 0, 0, 0], params: [] });

// ---------- the module's mod matrix ----------
// Stored after the 247 kit params: 18 targets, 18 amounts, 18 sources, slot = voice * 3 + a/b/c. A target is an index
// into MODULE_TARGETS (modtargets.js, from the module firmware), whose voice blocks run v/o ... mrp (morph).
const MATRIX = KIT_PARAMS, SRC_KIND = 100, DST_KIND = 101;
const SOURCES = ['cv1', 'cv2', 'cv3', 'cv4', 'cv5', 'lf1', 'lf2', 'lf3', 'lf4', 'lf5', 'lf6', 'ac1', 'ac2', 'ac3', 'ac4', 'ac5', 'ac6'];
const TARGET_BLOCKS = (() => {   // per voice: [0 (off), its target indexes]
  const blocks = [];
  let cur = [0];
  MODULE_TARGETS.forEach(([, par], i) => { if (i < 2) return; cur.push(i); if (par === 302) { blocks.push(cur); cur = [0]; } });
  return blocks;
})();
const targetName = i => i === 0 ? 'off' : MODULE_TARGETS[i]?.[0] === 113 ? 'v/o' : LXR_PAGES.names[MODULE_TARGETS[i]?.[0]]?.[0] || String(i);
function matrixSlots(voice) {
  const s = Math.min(voice, 5) * 3 + state.sub;
  return [['src', 'Mod source', MATRIX + 36 + s, SRC_KIND], ['amt', 'Mod amount %', MATRIX + 18 + s, 15], ['dst', 'Mod destination', MATRIX + s, DST_KIND], null];
}
// The module's pages show fewer parameters than the desktop's (module manual 4.4): no MIDI or track length on MIX, no
// velocity routing on MOD, and the LFOs have no own target (the matrix routes them).
const MODULE_KEEP = { [MOD_PAGE]: ['dec', 'slp', 'mod', 'vol'], [LFO_PAGE]: ['frq', 'ofs', 'wav', 'rtg'] };
const MODULE_DROP = { 7: ['len', 'ch', 'nte'] };

// The 4 (or 8) slots of a page for a voice: [short, long, param, dtype]. The open hat edits the hihat voice,
// with its own decay in place of the closed one.
function pageSlots(voice, page) {
  const v = Math.min(voice, 5);
  if (page === MATRIX_PAGE) return matrixSlots(voice);
  // the FX page has one layout per effect type, so it changes as you change the type
  const slots = page === FX_PAGE ? LXR_PAGES.fx[Math.min(state.params[FX_TYPE] ?? 0, LXR_PAGES.fx.length - 1)] : LXR_PAGES.pages[v][page];
  let out = slots.map(([s, , l, p, t]) => {
    if (voice === 6 && p === 60) return ['d2', 'Decay open', 61, t];
    return p > 0 && p < KIT_PARAMS ? [s, l, p, t] : null;
  });
  if (state.hw === MODULE && (MODULE_KEEP[page] || MODULE_DROP[page])) {
    out = out.filter(s => s && (MODULE_KEEP[page] ? MODULE_KEEP[page].includes(s[0]) : !MODULE_DROP[page].includes(s[0])));
    out = out.concat(Array(8 - out.length).fill(null));
  }
  return out;
}
function rowSlots() {
  const s = pageSlots(state.voice, state.page);
  return state.page === MATRIX_PAGE ? s : s.slice(state.sub * 4, state.sub * 4 + 4);   // the matrix's sub page is the slot
}

function range(t) {
  const kind = t & 0xff, menu = t >> 8;
  if (kind === 3) return [0, (LXR_PAGES.menus[menu]?.length || 1) - 1];
  if (kind === 6 || kind === 11) return [0, 1];
  if (kind === 7 || kind === 8) return [0, MOD_TARGETS - 1];
  if (kind === 9) return [1, 6];
  if (kind === 15) return [0, 100];
  if (t === SRC_KIND) return [0, SOURCES.length - 1];
  if (t === DST_KIND) return [0, (TARGET_BLOCKS[Math.min(state.voice, 5)]?.length || 1) - 1];   // a position in the voice's list
  if (kind === 0) return [0, 255];
  return [0, 127];
}
function showValue(v, t) {
  const kind = t & 0xff, menu = t >> 8;
  if (t === SRC_KIND) return SOURCES[v] ?? String(v);
  if (t === DST_KIND) return targetName(v);
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
  // which page of the menu: > first, * middle, < last (module manual 4.2); none for a one-page menu
  const pages = state.page === MATRIX_PAGE ? 3 : pageSlots(state.voice, state.page).slice(4).some(Boolean) ? 2 : 1;
  const mark = pages === 1 ? ' ' : state.sub === 0 ? '>' : state.sub === pages - 1 ? '<' : '*';
  const what = state.page === MATRIX_PAGE ? `${voice} MOD` : state.page === FX_PAGE ? 'FX ' + (LXR_PAGES.menus[18]?.[state.params[FX_TYPE] ?? 0] ?? '')
    : state.page === LFO_PAGE ? `LFO${Math.min(state.voice, 5) + 1} ${voice}` : `${voice} ${PAGE_NAMES[state.page]}`;
  const head = pad(what, 15) + mark;
  const f = slots[state.knobFocus];
  if (state.detail && f) return [pad(f[1], 16), pad(showValue(state.params[f[2]] ?? 0, f[3]), 16)];
  return Date.now() < state.paramUntil
    ? [names.map(n => pad(n, 4)).join(''), vals.map(v => pad(v, 4)).join('')]
    : [head, names.map(n => pad(n, 4)).join('')];
}

// A slot's knob value; a mod destination is edited as its position in the voice's target list.
function slotValue(s) {
  const v = state.params[s[2]] ?? 0;
  return s[3] === DST_KIND ? Math.max(0, (TARGET_BLOCKS[Math.min(state.voice, 5)] || [0]).indexOf(v)) : v;
}
function editKnob(k, d) {
  const s = rowSlots()[k];
  if (!s || !state.params.length) return;
  const [lo, hi] = range(s[3]);
  const pos = Math.min(hi, Math.max(lo, slotValue(s) + d));
  const v = s[3] === DST_KIND ? TARGET_BLOCKS[Math.min(state.voice, 5)][pos] : pos;
  if (v === state.params[s[2]]) return;
  state.params[s[2]] = v;
  const kit = state.kits[state.kit];
  if (kit) kit.edited = true;
  post({ cmd: 'param', i: s[2], v });
  if (typeof drawSide === 'function') drawSide();
}

function setMode(m) { state.mode = m; state.paramUntil = 0; state.detail = false; state.confirmClear = false; refresh(); }
// Encoder in edit mode (module manual 4.2): turning picks one of the 4 parameters (in capitals), a push opens its
// detail page (full name, value turned with the encoder), another push closes it.
function encoderEdit(d) {
  if (state.detail) { editKnob(state.knobFocus, d); state.paramUntil = 0; refresh(); return; }
  const live = rowSlots().map((s, i) => (s ? i : -1)).filter(i => i >= 0);
  if (!live.length) return;
  const at = Math.max(0, live.indexOf(state.knobFocus));
  state.knobFocus = live[((at + d) % live.length + live.length) % live.length];
  state.paramUntil = Date.now() + 4000;
  refresh(); clearTimeout(encoderEdit.t); encoderEdit.t = setTimeout(refresh, 4100);
}
function encoderEditPush() {
  if (!state.detail && !rowSlots()[state.knobFocus]) return;
  state.detail = !state.detail; state.paramUntil = 0; refresh();
}
function selectPage(p) {
  if (state.mode === 'edit' && state.page === p && pageSlots(state.voice, p).slice(4).some(Boolean)) state.sub ^= 1;
  else { state.page = p; state.sub = 0; }
  state.mode = 'edit'; state.paramUntil = 0; state.detail = false;
  refresh();
}
function toggleShift() { state.shift = !state.shift; refresh(); }
// Module MOD: the voice's modulation page (pitch EG, accent routing); SHIFT + MOD: its LFO (manual p.16).
// FX (module) or SHIFT + FX (desktop step 15): the kit's effect. DRUM + select still picks the voice/LFO.
// Module: MOD is the mod matrix (again: the next slot), SHIFT + MOD the LFO (manual 5.3).
function modPress(e) {
  const lfo = state.shift || e?.shiftKey;
  state.shift = false;
  if (lfo) { selectPage(LFO_PAGE); return; }
  if (state.mode === 'edit' && state.page === MATRIX_PAGE) state.sub = (state.sub + 1) % 3;
  else { state.page = MATRIX_PAGE; state.sub = 0; }
  state.mode = 'edit'; state.paramUntil = 0; state.detail = false;
  refresh();
}
function fxPress() { state.shift = false; selectPage(FX_PAGE); }
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

function markButtons() {
  (ui.trig || []).forEach((nodes, t) => nodes.forEach(n => n.classList.toggle('muted', !!state.mutes[t])));
  (ui.pages || []).forEach((n, p) => n.classList.toggle('on', state.mode === 'edit' && state.page === p));
  ui.shift?.classList.toggle('on', state.shift);
  ui.drum?.classList.toggle('on', state.drum);
  ui.edit?.classList.toggle('on', state.mode === 'edit' && ![MATRIX_PAGE, LFO_PAGE, FX_PAGE].includes(state.page));
  ui.mod?.classList.toggle('on', state.mode === 'edit' && (state.page === MATRIX_PAGE || state.page === LFO_PAGE));
  ui.fx?.classList.toggle('on', state.mode === 'edit' && state.page === FX_PAGE);
  ui.perf?.classList.toggle('on', state.mode === 'perf' || (state.hw === MODULE && state.mode === 'load'));
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
  return { v: slotValue(s), lo, hi };
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
  if (s && state.savedParams) knobSet(k, s[3] === DST_KIND ? Math.max(0, TARGET_BLOCKS[Math.min(state.voice, 5)].indexOf(state.savedParams[s[2]])) : state.savedParams[s[2]]);
}
