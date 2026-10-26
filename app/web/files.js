// Right sidebar (kit, pattern, bank and sample files) and the Settings sheet. The native side runs the file panels.
'use strict';
const WAVES = ['Sine', 'Tri', 'Saw', 'Rec', 'Noise', 'PWM', 'Crash (LXR-1)'];   // the LXR-2 has 0-5; on the LXR-1 engine 6 is its crash and 7 + n sample n
const VOICES = ['DRUM1', 'DRUM2', 'DRUM3', 'SNARE', 'CYM', 'HIHAT'];

const patternName = i => seq.patterns[i].name || 'PAT-' + SLOTS[i];
const patternMsg = p => ({ name: p.name, len: p.len, steps: p.steps });

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
  saveProject() {
    const all = seq.patterns.map((p, i) => ({ ...patternMsg(p), name: patternName(i) }));
    post({ cmd: 'saveProject', hw: state.hw, swing: seq.swing, patterns: all,
      json: JSON.stringify({ patterns: seq.patterns, slot: seq.slot, bpm: seq.bpm, swing: seq.swing }) });
  },
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
  const sampleEngine = state.sampleEngines?.[state.engine];
  const samples = state.samples || [];

  const waves = h('div', { className: 'waves' });
  VOICES.forEach((v, i) => {
    const opts = WAVES.map((w, j) => [j, w]).concat(samples.map((s, j) => [7 + j, `s${String(j + 1).padStart(2, '0')} ${s.name} (LXR-1)`]));
    const cur = state.waves?.[i] ?? 0;
    if (cur >= 7 + samples.length) opts.push([cur, `sample ${cur - 6} (not loaded)`]);
    waves.append(h('label', {}, v), select(opts, cur, val => post({ cmd: 'wave', voice: i, value: val }), v + ' oscillator waveform'));
  });

  const list = h('ol', { className: 'samples' }, samples.map((s, i) =>
    h('li', { title: s.name }, h('span', { className: 'num', textContent: 's' + String(i + 1).padStart(2, '0') }),
      h('span', { className: 'nm', textContent: s.name }), h('span', { className: 'dim', textContent: (s.loop ? '⟲ ' : '') + s.sec.toFixed(2) + 's' }))));

  side.replaceChildren(
    section('Kit',
      h('p', { className: 'cur', textContent: k ? `${k.bank} / ${k.name}${k.edited ? ' •' : ''}` : 'No kit' }),
      h('div', { className: 'btns' }, btn('Save', 'saveKit', '⌘S'), btn('Save as…', 'saveKitAs', '⇧⌘S'),
        btn('Save morph as kit…', 'saveMorph', 'What you hear: the kit morphed toward the target (⌥⌘S)'), btn('Import kits…', 'importKits', '⇧⌘O')),
      h('h4', { textContent: 'Oscillators' }), waves),
    section('Pattern',
      h('p', { className: 'cur', textContent: `${SLOTS[seq.slot]}: ${patternName(seq.slot)}` }),
      h('div', { className: 'btns' }, btn('Export…', () => phx.exportPatterns(false), '⌘E'), btn('Export A–H…', () => phx.exportPatterns(true), '⇧⌘E'),
        btn('Import…', 'importPatterns', 'Fills slots from the current one on (⌘I)'))),
    section('Project',
      h('p', { className: 'dim', textContent: 'This bank\'s kits, patterns, samples and tempo, with a card-ready Project00 (module) or PROJ00 (desktop) folder inside.' }),
      h('div', { className: 'btns' }, btn('Save project…', () => phx.saveProject(), '⌥⇧⌘S'), btn('Open project…', 'openProject', '⌥⌘O'))),
    section('Bank',
      h('p', { className: 'dim', textContent: 'This bank\'s kits as NN-NAME.SND plus patterns A–H as .PAT, ready for the SD card.' }),
      h('div', { className: 'btns' }, btn('Save bank as…', () => phx.saveBank(), '⇧⌘B'), btn('New user bank…', 'newBank', '⇧⌘N'))),
    section('Samples',
      h('p', { className: 'dim', textContent: sampleEngine ? 'Pick them as oscillator waveforms above.' : 'Samples play on the LXR-1 (open fw) engine only.' }),
      list,
      h('div', { className: 'btns' }, btn('Import…', 'importSamples', 'Any audio file, converted to mono 16-bit 44.1 kHz (⇧⌘I)'),
        samples.length ? btn('Clear', 'clearSamples') : '')),
  );
}

// Redraw after the host's state and after sequencer changes (slot names).
const baseState = window.lxrState;
window.lxrState = s => { baseState(s); drawSide(); };
const baseDrawSeq = drawSeq;
drawSeq = (...a) => { baseDrawSeq(...a); drawSide(); };

$('sidebtn').onclick = () => phx.sidebar();
let sideShown = true;
try { sideShown = localStorage.getItem('sideShown') !== '0'; } catch (e) { /* default: shown */ }
phx.sidebar(sideShown);
drawSide();
