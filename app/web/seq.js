// Step sequencer, pitch input and I/O settings, under the panel. Patterns live here and are sent whole to the
// native sequencer (which runs in the audio thread) whenever they change.
'use strict';
const MAX_STEPS = 32, SLOTS = 'ABCDEFGH';
const PIANO_KEYS = 'awsedftgyhujk';   // QWERTY piano: a = C ... k = C an octave up
const emptyPattern = () => ({ len: 16, steps: Array.from({ length: 7 }, () => Array.from({ length: MAX_STEPS }, () => [0, 60])) });
const seq = {
  patterns: Array.from({ length: SLOTS.length }, emptyPattern), slot: 0,
  bpm: 120, swing: 0, playing: false, track: 0, playhead: -1,
  piano: false, octave: 0,
  io: { audioOuts: [], audioOut: -1, midiOuts: [], midiOut: -1, midiIns: [], midiIn: -1, midiMode: 0, midiCh: 0 },
};
const pat = () => seq.patterns[seq.slot];

// ---------- native sync ----------
function sendPattern() {
  const p = pat();
  // On the module a step is a trigger with or without its accent gate; on the desktop it's a velocity.
  const steps = p.steps.map(row => row.map(([v, n]) => [v === 0 ? 0 : state.hw === MODULE ? (v >= 120 ? 127 : state.base) : v, n]));
  post({ cmd: 'pattern', steps, length: p.len });
  post({ cmd: 'savePatterns', json: JSON.stringify({ patterns: seq.patterns, slot: seq.slot, bpm: seq.bpm, swing: seq.swing }) });
}
function sendTempo() { post({ cmd: 'tempo', bpm: seq.bpm, swing: seq.swing }); }
window.seqToggle = () => { seq.playing = !seq.playing; post({ cmd: 'transport', on: seq.playing ? 1 : 0 }); if (!seq.playing) seq.playhead = -1; drawSeq(); };

// Called by the host: saved patterns, device lists.
window.lxrSeqState = s => {
  if (s.saved) {
    try {
      const d = JSON.parse(s.saved);
      if (Array.isArray(d.patterns) && d.patterns.length === SLOTS.length) seq.patterns = d.patterns;
      Object.assign(seq, { slot: d.slot ?? 0, bpm: d.bpm ?? 120, swing: d.swing ?? 0 });
    } catch (e) { /* keep the empty patterns */ }
  }
  if (s.io) Object.assign(seq.io, s.io);
  sendPattern(); sendTempo(); drawSeq();
};
// Called ~30 times a second: playhead and per-trigger hit counters (to light the panel for sequenced and MIDI hits).
let lastCounts = null;
window.lxrTick = (step, counts) => {
  if (step !== seq.playhead) { seq.playhead = step; markPlayhead(); }
  if (lastCounts) counts.forEach((c, t) => { if (c !== lastCounts[t]) (ui.trig?.[t] || []).forEach(n => flash(n)); });
  lastCounts = counts;
};

// ---------- drawing ----------
const $ = id => document.getElementById(id);
function h(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const k in props) {
    if (k === 'dataset') Object.assign(e.dataset, props[k]);
    else if (k in e) e[k] = props[k];
    else e.setAttribute(k, props[k]);
  }
  kids.flat().forEach(k => e.append(k));
  return e;
}
function select(options, value, onchange, label) {
  const s = h('select', { 'aria-label': label, onchange: e => onchange(+e.target.value) });
  options.forEach(([v, t]) => s.append(h('option', { value: v, textContent: t })));
  s.value = value;
  return s;
}

function drawSeq() {
  const root = $('seq');
  if (!root) return;
  const p = pat();
  const transport = h('div', { className: 'row' },
    h('button', { className: 'play' + (seq.playing ? ' on' : ''), textContent: seq.playing ? '■ Stop' : '▶ Play', title: 'Space', onclick: window.seqToggle }),
    h('label', {}, 'BPM ', h('input', { type: 'number', min: 20, max: 300, value: seq.bpm, onchange: e => { seq.bpm = +e.target.value || 120; sendTempo(); sendPattern(); } })),
    h('label', {}, 'Swing ', h('input', { type: 'range', min: 0, max: 0.6, step: 0.01, value: seq.swing, oninput: e => { seq.swing = +e.target.value; sendTempo(); } })),
    h('label', {}, 'Steps ', h('input', { type: 'number', min: 1, max: MAX_STEPS, value: p.len, onchange: e => { p.len = Math.min(MAX_STEPS, Math.max(1, +e.target.value || 16)); sendPattern(); drawSeq(); } })),
    h('span', { className: 'slots' }, [...SLOTS].map((c, i) => h('button', { textContent: c, className: i === seq.slot ? 'on' : '', title: 'Pattern ' + c,
      onclick: () => { seq.slot = i; sendPattern(); drawSeq(); } }))),
    h('button', { textContent: 'Clear', onclick: () => { seq.patterns[seq.slot] = emptyPattern(); sendPattern(); drawSeq(); } }),
    h('span', { className: 'grow' }),
    h('button', { className: seq.piano ? 'on' : '', textContent: seq.piano ? 'Keys: piano' : 'Keys: pads',
      title: 'Piano: a w s e d f t g y h u j k play the selected track chromatically, z/x octave', onclick: () => { seq.piano = !seq.piano; drawSeq(); } }),
  );

  const grid = h('div', { className: 'grid', style: `--steps:${p.len}` });
  TRIGGERS.forEach((name, t) => {
    grid.append(h('button', { className: 'trk' + (t === seq.track ? ' on' : ''), textContent: name, title: 'Select for pitch editing and the piano', onclick: () => { seq.track = t; drawSeq(); } }));
    for (let s = 0; s < p.len; s++) {
      const [v] = p.steps[t][s];
      const cell = h('div', { className: 'cell' + (s % 4 === 0 ? ' beat' : '') + (v ? ' set' : '') + (v >= 120 ? ' acc' : ''), dataset: { s } });
      if (v) cell.style.setProperty('--v', (v / 127).toFixed(2));
      cell.title = 'Click: step on/off · shift-click: accent · scroll: velocity';
      cell.onpointerdown = e => {
        const st = p.steps[t][s];
        st[0] = e.shiftKey ? (st[0] >= 120 ? 0 : 127) : st[0] ? 0 : 100;
        sendPattern(); drawSeq();
      };
      cell.onwheel = e => {
        e.preventDefault();
        const st = p.steps[t][s];
        if (!st[0]) return;
        st[0] = Math.min(127, Math.max(1, st[0] + (e.deltaY < 0 ? 4 : -4)));
        sendPattern(); drawSeq();
      };
      grid.append(cell);
    }
  });
  // pitch lane for the selected track: semitones from the kit's own pitch
  grid.append(h('div', { className: 'trk lane', textContent: 'pitch ' + TRIGGERS[seq.track] }));
  for (let s = 0; s < p.len; s++) {
    const st = p.steps[seq.track][s], off = st[1] - 60;
    const c = h('div', { className: 'pitch' + (st[0] ? '' : ' idle'), textContent: off > 0 ? '+' + off : String(off), dataset: { s } });
    c.title = 'Drag or scroll: pitch in semitones · double-click: reset';
    const set = d => { st[1] = Math.min(127, Math.max(0, st[1] + d)); c.textContent = (st[1] - 60 > 0 ? '+' : '') + (st[1] - 60); sendPattern(); };
    c.onwheel = e => { e.preventDefault(); set(e.deltaY < 0 ? 1 : -1); };
    c.ondblclick = () => { st[1] = 60; sendPattern(); drawSeq(); };
    c.onpointerdown = e => {
      c.setPointerCapture(e.pointerId);
      let y0 = e.clientY;
      c.onpointermove = ev => { const d = Math.trunc((y0 - ev.clientY) / 6); if (d) { set(d); y0 -= d * 6; } };
      c.onpointerup = () => { c.onpointermove = null; };
    };
    grid.append(c);
  }

  // piano for the selected track
  const piano = h('div', { className: 'piano' });
  let white = 0;
  for (let i = 0; i < 25; i++) {
    const note = 48 + seq.octave * 12 + i, black = [1, 3, 6, 8, 10].includes(i % 12);
    const k = h('button', { className: black ? 'k black' : 'k', title: noteName(note), onpointerdown: () => playNote(note) });
    k.style.left = (black ? white * 22 - 8 : white++ * 22) + 'px';
    piano.append(k);
  }
  piano.style.width = white * 22 + 'px';

  const io = seq.io;
  const ioRow = h('div', { className: 'row io' },
    h('label', {}, 'Audio out ', select([[-1, 'System default'], ...io.audioOuts.map((n, i) => [i, n])], io.audioOut, v => { io.audioOut = v; io.audioLayout = [2, 0]; sendAudioOut(); drawSeq(); }, 'Audio output')),
    h('label', {}, layoutSelect()),
    h('label', {}, 'MIDI out ', select([[-1, io.midiOuts.length ? 'None (virtual port only)' : 'Virtual port "LXR Audition"'], ...io.midiOuts.map((n, i) => [i, n])], io.midiOut, v => { io.midiOut = v; post({ cmd: 'midiOut', i: v }); }, 'MIDI output')),
    h('label', {}, select([[0, 'Channel per track'], [1, 'One channel, drum notes']], io.midiMode, v => { io.midiMode = v; post({ cmd: 'midiMode', mode: v, ch: io.midiCh }); drawSeq(); }, 'MIDI mode')),
    h('label', {}, io.midiMode === 0 ? 'from ch ' : 'ch ', select(Array.from({ length: 16 }, (_, i) => [i, String(i + 1)]), io.midiCh, v => { io.midiCh = v; post({ cmd: 'midiMode', mode: io.midiMode, ch: v }); drawSeq(); }, 'MIDI channel')),
    h('label', {}, 'MIDI in ', select([[-1, 'None'], ...io.midiIns.map((n, i) => [i, n])], io.midiIn, v => { io.midiIn = v; post({ cmd: 'midiIn', i: v }); }, 'MIDI input')),
    h('button', { textContent: '↻', title: 'Rescan audio and MIDI devices', onclick: () => post({ cmd: 'rescan' }) }),
  );
  root.replaceChildren(transport, grid, h('div', { className: 'row' }, h('span', { className: 'dim', textContent: `Piano → ${TRIGGERS[seq.track]}  ` }), piano), ioRow);
  markPlayhead();
}
// Stereo mix on any channel pair, or the 4 jacks on 4 channels (main L, main R, out2 L, out2 R) when the device has them.
function layoutSelect() {
  const io = seq.io, n = io.audioOut >= 0 ? io.audioChannels?.[io.audioOut] || 2 : 2, opts = [];
  for (let f = 0; f + 2 <= n; f += 2) opts.push([`2:${f}`, n > 2 ? `Stereo mix → ch ${f + 1}-${f + 2}` : 'Stereo mix']);
  for (let f = 0; f + 4 <= n; f += 4) opts.push([`4:${f}`, `4 jacks → ch ${f + 1}-${f + 4}`]);
  const s = h('select', { 'aria-label': 'Output layout', title: '4 jacks: each LXR output on its own channel, e.g. into Ableton via BlackHole 16ch',
    onchange: e => { io.audioLayout = e.target.value.split(':').map(Number); sendAudioOut(); } });
  opts.forEach(([v, t]) => s.append(h('option', { value: v, textContent: t })));
  s.value = (io.audioLayout || [2, 0]).join(':');
  if (s.selectedIndex < 0) s.selectedIndex = 0;
  return s;
}
function sendAudioOut() { const [channels, first] = seq.io.audioLayout || [2, 0]; post({ cmd: 'audioOut', i: seq.io.audioOut, channels, first }); }

function markPlayhead() {
  document.querySelectorAll('#seq .cell.now, #seq .pitch.now').forEach(c => c.classList.remove('now'));
  if (seq.playhead >= 0) document.querySelectorAll(`#seq [data-s="${seq.playhead}"]`).forEach(c => c.classList.add('now'));
}
const NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const noteName = n => NAMES[n % 12] + (Math.floor(n / 12) - 1) + (n === 60 ? ' (kit pitch)' : '');
function playNote(note) {
  const vel = state.hw === MODULE ? (state.accent[ACCENT_OF[seq.track]] ? 127 : state.base) : state.vel;
  post({ cmd: 'note', t: seq.track, note, vel });
  (ui.trig?.[seq.track] || []).forEach(n => flash(n));
}

// QWERTY piano; runs before the panel's key handler and swallows the keys it uses.
document.addEventListener('keydown', e => {
  if (!seq.piano || e.metaKey || e.ctrlKey || e.repeat || /INPUT|SELECT/.test(e.target.tagName)) return;
  const i = PIANO_KEYS.indexOf(e.key);
  if (i >= 0) playNote(60 + seq.octave * 12 + i);
  else if (e.key === 'z') seq.octave = Math.max(-3, seq.octave - 1), drawSeq();
  else if (e.key === 'x') seq.octave = Math.min(3, seq.octave + 1), drawSeq();
  else return;
  e.preventDefault(); e.stopImmediatePropagation();
}, true);

drawSeq();
