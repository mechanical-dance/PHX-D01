<p align="center"><img src="docs/logo.png" width="160" alt="PHX-D01 logo"></p>

# PHX-D01 (lxr-audition)

Audition LXR-02 kits (`.SND`) on the Mac with the LXR's own sound engine, compiled natively.
No SD-card swapping.

The engine is Erica Synths' open-source LXR firmware (`lxr-desktop-app`, GPL-3.0), cloned at
`~/code/vendor/lxr-02/lxr-desktop-app`. The build copies it to `build/src`, applies `patches/`,
and links it with `host/`. The vendor tree is never modified.

## Use
```sh
make
./build/lxr-play path/to/kits       # live: 1-7 triggers (7 = open hat), space all, ←/→ kit, e engine, m hardware (LXR-02/LXR-Drum), o jack solo, q quit
./build/lxr-render KIT.SND out/kit.wav        # offline: hits each of the 6 voices
```
Engines are plugins (`build/engine-*.dylib`) exporting only `lxr_*` (see `host/engine.h`), so engines
built from different firmware trees, with clashing symbol names, can run side by side. `lxr-play` loads every
engine it finds next to itself and keeps the current kit loaded in all of them, so switching is instant.

## App
`make app` builds `build/PHX-D01.app`: the LXR-02 desktop or LXR-Drum module front panel (drawn from the
manuals' panel drawings) in a window, on the same engines.
- Triggers (1-7, shift = accent / full velocity), accent jacks, output-jack solo, desktop faders (firmware curve).
- Kit banks: each opened folder is a bank. Morph toward a target kit (firmware rule: routing and mod targets stay).
- Step sequencer in the audio thread: 7 tracks, up to 32 steps, velocity/accent and pitch per step, swing,
  8 pattern slots. Pitch input: piano (on screen or QWERTY) and MIDI in. Note 60 = the kit's pitch.
- MIDI out (port + virtual "PHX-D01" source): channel per track (how the LXR listens) or one channel with GM drum
  notes; timestamped to line up with the audio.
- Audio out: any device; stereo mix on any channel pair, or the 4 jacks on 4 channels.

Code: `host/audio.c` (runtime: engines, CoreAudio, sequencer), `host/midi.c` (CoreMIDI), `app/main.swift` (window,
kit banks, settings), `app/web/` (panels, sequencer UI).

## Before publishing
Not yet: rename (Erica's notice reserves "LXR"/"LXR-02"/"Erica Synths" names and the panel design), add credits
(Julian Schmidt / Sonic Potions, Erica Synths, Brendan Clarke / LXR02Open) and licences, and decide how to ship
the LXR-1 engine (LXR02Open's non-commercial licence doesn't mix with GPL-3.0 in one program).

## How it works
- Kit format (`.SND`, 255 bytes): 8-byte name, then 247 parameter bytes indexed by the firmware's
  `Parameters.h` enum (`END_OF_SOUND_PARAMETERS` = 247; the `//228` comment there is stale).
  The Eurorack module and the desktop LXR use the same format.
- Loading: each byte is fed to `frontParser_parseUartData` as a front-panel CC (param < 128: `MIDI_CC`,
  else `CC_2`, param − 128), the same path the firmware uses on kit load.
- Rendering: `mixer_calcNextSampleBlock` (64 stereo frames per call, 44.1 kHz). Both output pairs
  (DAC1 main, DAC2 second) are summed so routing can't hide a voice.
- `shim/`: stand-ins for the STM32 HAL (types, Cortex-M intrinsics), FatFs and USB headers.
- `host/stubs.c`: no-op front panel, LEDs, menu, UART, trigger outputs.
- Native differences from the hardware: parameter slots with a NULL pointer (`PAR_NONE`) point at scratch
  memory (address 0 is readable flash on the STM32); `patches/01` computes the ARM overflow flag the noise
  oscillator reads.

## Engines
| Plugin | Source | Notes |
|---|---|---|
| `engine-lxr2.dylib` | Erica `lxr-desktop-app` v1.7 (GPL-3.0) | the LXR-02's own engine; kits load natively |
| `engine-lxr1.dylib` | Sonic Potions 0.37 via `LXR02Open` (non-commercial licence) | kits translated by parameter name (`gen_map.py` → `build/lxr1_map.h`, 220/247 params) |

LXR-1 translation: the 27 LXR-2-only parameters (FX bus, PWM, morph) are dropped; voices routed to the FX bus
play dry on the main output; waveform PWM becomes Rec and sample slots shift down by one.

Native fixes in both: NULL parameter pointers point at scratch memory; kit index 127 is skipped (firmware bug:
it becomes CC 0 and `midiParser_ccHandler` writes `midiParser_originalCcValues[65536]`); the noise oscillator's
ARM overflow-flag read is computed in C. LXR-1 only: interrupt masking is a no-op and the RNG is the system's.

## Not yet
- Hardware models (output stage of the desktop LXR-2 vs the original LXR).
