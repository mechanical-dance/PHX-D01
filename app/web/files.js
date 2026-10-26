// Right sidebar (kit, pattern, bank and sample files) and the Settings sheet. The native side runs the file panels.
'use strict';
const VOICES = ['DRUM1', 'DRUM2', 'DRUM3', 'SNARE', 'CYM', 'HIHAT'];

const patternName = i => seq.patterns[i].name || 'PAT-' + SLOTS[i];
const patternMsg = p => ({ name: p.name, len: p.len, steps: p.steps });

function projectPayload() {
  return { swing: seq.swing, patterns: seq.patterns.map((p, i) => ({ ...patternMsg(p), name: patternName(i) })),
    json: JSON.stringify({ patterns: seq.patterns, slot: seq.slot, bpm: seq.bpm, swing: seq.swing }) };
}

window.phx = {
  sidebar(on) {
    const side = $('side'), show = on ?? side.hidden;
    side.hidden = !show;
    $('sidebtn').setAttribute('aria-pressed', String(show));
    try { localStorage.setItem('sideShown', show ? '1' : '0'); } catch (e) { /* per-viewer nicety only */ }
  },
  sequencer() { $('seqbtn').click(); },
  prefs() { const d = $('prefs'); if (d.open) d.close(); else { drawPrefs(); d.showModal(); } },
  exportPatterns(all) {
    const slots = all ? [...SLOTS].map((_, i) => i) : [seq.slot];
    post({ cmd: 'exportPatterns', first: all ? 0 : seq.slot, swing: seq.swing,
      patterns: slots.map(i => ({ ...patternMsg(seq.patterns[i]), name: patternName(i) })) });
  },
  // ⌘S: the kit you're on and the current project. Save Project As: a copy under a new name.
  save() { post({ cmd: 'save', ...projectPayload() }); },
  saveProjectAs() { post({ cmd: 'saveProjectAs', hw: state.hw, ...projectPayload() }); },
  saveBank() {
    post({ cmd: 'saveBank', swing: seq.swing, patterns: seq.patterns.map((p, i) => ({ ...patternMsg(p), name: patternName(i) })) });
  },
};

// Save confirmations from the host.
window.lxrToast = ({ text }) => {
  let t = $('toast');
  if (!t) { t = h('div', { id: 'toast' }); document.body.append(t); }
  t.textContent = text; t.classList.add('show');
  clearTimeout(t.timer); t.timer = setTimeout(() => t.classList.remove('show'), 2500);
};

// Load sheet (encoder push): a bank and its kits; double-click, Enter or Load plays the kit.
phx.load = () => {
  const d = $('loadkit');
  let bank = state.kits[state.kit]?.bank ?? bankNames()[0];
  const draw = () => {
    const list = h('select', { size: 16, 'aria-label': 'Kits', className: 'kitlist' });
    state.kits.forEach((k, i) => { if (k.bank === bank) list.append(h('option', { value: i, selected: i === state.kit, textContent: `${slotLabel(i)}  ${k.name}${k.virtual ? '  (empty)' : ''}` })); });
    const go = () => { if (list.value !== '') { setKit(+list.value); d.close(); } };
    list.ondblclick = go;
    list.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); go(); } };
    d.replaceChildren(
      h('h2', { textContent: 'Load kit' }),
      h('div', { className: 'grid' },
        h('label', { textContent: 'Bank' }),
        h('select', { 'aria-label': 'Bank', onchange: e => { bank = e.target.value; draw(); } },
          bankNames().map(b => h('option', { value: b, textContent: b, selected: b === bank }))),
        h('label', { textContent: 'Kit' }), list),
      h('div', { className: 'row end' },
        h('button', { textContent: 'Open folder…', onclick: () => { d.close(); openFolder(); } }),
        h('span', { className: 'grow' }),
        h('button', { textContent: 'Cancel', onclick: () => d.close() }),
        h('button', { className: 'primary', textContent: 'Load', onclick: go })));
    list.focus();
  };
  draw();
  if (!d.open) d.showModal();
  d.querySelector('select.kitlist')?.focus();
};

// Save sheet: pick a loaded bank (rename it in place with ✎), a slot in it and the kit's name.
const save = { open: false, morphed: false, bank: '', slot: 0, name: '', renaming: false };
const slotOf = k => parseInt(k.file, 10);
function bankKitsOf(b) { return state.kits.filter(k => k.bank === b); }
function firstFreeSlot(b) {
  const ks = bankKitsOf(b), v = ks.find(k => k.virtual), used = new Set(ks.map(slotOf));
  if (v) return slotOf(v);
  for (let i = 0; i < 128; i++) if (!used.has(i)) return i;
  return 127;
}
phx.saveAs = ({ morphed }) => {
  const k = state.kits[state.kit];
  if (!k) return;
  Object.assign(save, { open: true, morphed: !!morphed, bank: k.bank, renaming: false,
    name: ((morphed ? 'M' : '') + k.name).slice(0, 8) });
  save.slot = firstFreeSlot(save.bank);
  drawSave();
  const d = $('saveas'); if (!d.open) d.showModal();
  d.querySelector('input.kitname')?.select();
};
function drawSave() {
  const d = $('saveas');
  if (!save.open) return;
  // a bank that vanished (not one we're renaming): back to the kit's own bank, at a free slot
  if (!bankNames().includes(save.bank) && save.bank !== save.pending) {
    save.bank = state.kits[state.kit]?.bank ?? bankNames()[0]; save.slot = firstFreeSlot(save.bank);
  }
  const ks = bankKitsOf(save.pending === save.bank && !bankNames().includes(save.bank) ? save.pendingFrom : save.bank), at = new Map(ks.map(k => [slotOf(k), k]));
  const target = at.get(save.slot), replacing = target && !target.virtual;
  const finish = () => { save.open = false; d.close(); };
  const doSave = () => {
    const name = save.name.trim();
    if (!name) return;
    post({ cmd: 'saveKitTo', bank: save.bank, slot: save.slot, name, morphed: save.morphed });
    finish();
  };

  let bankCtl;
  if (save.renaming) {
    bankCtl = h('input', { className: 'bankname', value: save.bank, 'aria-label': 'Bank name' });
    const commit = () => {
      if (!save.renaming) return;
      save.renaming = false;
      const name = bankCtl.value.trim();
      if (name && name !== save.bank) {
        post({ cmd: 'renameBank', bank: save.bank, name });
        // the project's bank is named after the project, so it comes back as "Project: <name>"
        const shown = save.bank === state.projectBank ? 'Project: ' + name.replace(/^Project:\s*/, '') : name;
        save.pendingFrom = save.bank; save.pending = save.bank = shown;
      }
      drawSave();
    };
    bankCtl.onkeydown = e => {
      if (e.key === 'Enter') { e.preventDefault(); commit(); }
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); save.renaming = false; drawSave(); }
    };
    bankCtl.onblur = commit;
  } else {
    bankCtl = h('select', { 'aria-label': 'Bank', onchange: e => { save.bank = e.target.value; save.slot = firstFreeSlot(save.bank); drawSave(); } },
      bankNames().map(b => b === save.pendingFrom ? save.pending : b).filter((b, i, a) => a.indexOf(b) === i)
        .map(b => h('option', { value: b, textContent: b, selected: b === save.bank })));
  }
  const slots = h('select', { 'aria-label': 'Slot', onchange: e => { save.slot = +e.target.value; drawSave(); } },
    Array.from({ length: save.bank === state.projectBank && state.projectLayout === 'desktop' ? 64 : 128 }, (_, i) => {
      const k = at.get(i), nn = String(i).padStart(2, '0');
      return h('option', { value: i, selected: i === save.slot,
        textContent: !k ? `${nn}  — empty` : k.virtual ? `${nn}  INIT (empty)` : `${nn}  ${k.name}` });
    }));
  const name = h('input', { className: 'kitname', value: save.name, maxLength: 8, spellcheck: false, 'aria-label': 'Kit name',
    oninput: e => { save.name = e.target.value; }, onkeydown: e => { if (e.key === 'Enter') { e.preventDefault(); doSave(); } } });

  d.replaceChildren(
    h('h2', { textContent: save.morphed ? 'Save morph as kit' : 'Save kit as' }),
    h('div', { className: 'grid' },
      h('label', { textContent: 'Bank' }),
      h('div', { className: 'row' }, bankCtl, save.renaming ? '' : h('button', { textContent: '✎', title: 'Rename this bank (its folder)',
        onclick: () => { save.renaming = true; drawSave(); const i = d.querySelector('input.bankname'); i?.focus(); i?.select(); } })),
      h('label', { textContent: 'Slot' }), slots,
      h('label', { textContent: 'Name' }), name),
    h('p', { className: replacing ? 'warn' : 'dim', textContent: replacing
      ? `Replaces ${target.file}. The old file goes to the Trash.`
      : 'Up to 8 characters; the file is NN- plus its first 5.' }),
    h('div', { className: 'row end' },
      h('button', { textContent: 'Other folder…', onclick: () => { post({ cmd: 'saveKitElsewhere', morphed: save.morphed }); finish(); } }),
      h('span', { className: 'grow' }),
      h('button', { textContent: 'Cancel', onclick: finish }),
      h('button', { className: replacing ? 'danger' : 'primary', textContent: replacing ? `Replace ${String(save.slot).padStart(2, '0')} ${target.name}` : 'Save', onclick: doSave })),
  );
  d.onclose = () => { save.open = false; };
}

window.drawPrefs = () => {
  const d = $('prefs');
  if (!d.open && d.childElementCount) return;
  d.replaceChildren(
    h('h2', { textContent: 'Settings' }),
    ioRows(),
    h('div', { className: 'row end' }, h('button', { textContent: 'Done', onclick: () => d.close() })),
  );
};

function section(title, ...kids) { return h('section', {}, h('h3', { textContent: title }), ...kids); }
function btn(text, cmd, title = '') { return h('button', { textContent: text, title, onclick: typeof cmd === 'function' ? cmd : () => post({ cmd }) }); }

function drawSide() {
  const side = $('side');
  if (!side) return;
  const k = state.kits[state.kit];
  const samples = state.samples || [], report = state.sampleReport || {};

  const waves = h('div', { className: 'waves' });
  VOICES.forEach((v, i) => {
    // the waveform menu as the engine has it (LXR-1: edit.js waveKit/waveName); values are kit values
    const cur = state.waves?.[i] ?? 0;
    const opts = sampleEngine()
      ? Array.from({ length: 6 + samples.length }, (_, p) => waveKit(p)).map(v => [v, v >= 7 ? `${waveName(v)} ${samples[v - 7].name}` : waveName(v)])
      : LXR_PAGES.menus[2].map((w, v) => [v, w]);
    if (!opts.some(([v]) => v === cur)) opts.push([cur, sampleEngine() ? waveName(cur) : `${cur} (not in this engine's menu)`]);
    waves.append(h('label', {}, v), select(opts, cur, val => post({ cmd: 'wave', voice: i, value: val }), v + ' oscillator waveform'));
  });

  const list = h('ol', { className: 'samples' }, samples.map((s, i) =>
    h('li', { title: s.name }, h('span', { className: 'num', textContent: sampleShort(i) }),
      h('span', { className: 'nm', textContent: s.name }), h('span', { className: 'dim', textContent: (s.loop ? '⟲ ' : '') + s.sec.toFixed(2) + 's' }))));

  side.replaceChildren(
    section('Kit',
      h('p', { className: 'cur', textContent: k ? `${k.bank} / ${k.name}${k.edited ? ' •' : ''}` : 'No kit' }),
      h('div', { className: 'btns' }, btn('Save', () => phx.save(), 'Saves this kit and the project (⌘S)'), btn('Save as…', () => phx.saveAs({ morphed: false }), '⇧⌘S'),
        btn('Save morph as kit…', () => phx.saveAs({ morphed: true }), 'What you hear: the kit morphed toward the target (⌥⌘S)'), btn('Import kits…', 'importKits', '⇧⌘O')),
      h('h4', { textContent: 'Oscillators' }), waves),
    section('Pattern',
      h('p', { className: 'cur', textContent: `${SLOTS[seq.slot]}: ${patternName(seq.slot)}` }),
      h('div', { className: 'btns' }, btn('Export…', () => phx.exportPatterns(false), '⌘E'), btn('Export A–H…', () => phx.exportPatterns(true), '⇧⌘E'),
        btn('Import…', 'importPatterns', 'Fills slots from the current one on (⌘I)'))),
    section('Project',
      h('p', { className: 'cur', textContent: `${state.project || '—'} (${state.projectLayout === 'desktop' ? 'desktop' : 'module'})` }),
      h('p', { className: 'dim', textContent: 'Its kits are the "Project:" bank; ⌘S saves them with the patterns and tempo.' }),
      h('div', { className: 'btns' }, btn('Save', () => phx.save(), '⌘S'), btn('Save project as…', () => phx.saveProjectAs(), '⌥⇧⌘S'),
        btn('Open project…', 'openProject', '⌥⌘O'))),
    section('Bank',
      h('p', { className: 'dim', textContent: 'This bank\'s kits as NN-NAME.SND plus patterns A–H as .PAT, ready for the SD card.' }),
      h('div', { className: 'btns' }, btn('Save bank as…', () => phx.saveBank(), '⇧⌘B'), btn('New user bank…', 'newBank', '⇧⌘N'))),
    section('Samples',
      h('p', { className: 'dim', textContent: (sampleEngine() ? '' : 'Samples play on the LXR-1 engine only. ')
        + 'Load Samples replaces them with the card\'s samples/, then adds its loops/ (mono 16-bit 44.1 kHz WAV only).' }),
      list,
      report.failed ? h('p', { className: 'warn', textContent: `${report.failed} Failed` }) : '',
      report.skipped?.length ? h('details', {}, h('summary', { textContent: `${report.skipped.length} skipped` }),
        h('ul', { className: 'skipped' }, report.skipped.map(([f, why]) => h('li', { textContent: `${f}: ${why}` })))) : '',
      h('div', { className: 'btns' }, btn('Load samples', 'loadSamples', 'From this project\'s samples/ and loops/ (⇧⌘I)'),
        btn('From card…', 'loadSamplesFrom', 'Another card folder, e.g. an SD card (⌥⇧⌘I)'))),
  );
}

// Redraw after the host's state and after sequencer changes (slot names).
const baseState = window.lxrState;
window.lxrState = s => {
  baseState(s); drawSide();
  // a rename settles with the host's next state: done if the new name is there, else it failed and we go back
  if (save.pending && s.kits) {
    if (!bankNames().includes(save.pending) && save.bank === save.pending) save.bank = save.pendingFrom;
    save.pending = save.pendingFrom = null;
  }
  if (save.open && !save.renaming) drawSave();
};
const baseDrawSeq = drawSeq;
drawSeq = (...a) => { baseDrawSeq(...a); drawSide(); };

$('sidebtn').onclick = () => phx.sidebar();
let sideShown = true;
try { sideShown = localStorage.getItem('sideShown') !== '0'; } catch (e) { /* default: shown */ }
phx.sidebar(sideShown);
drawSide();
