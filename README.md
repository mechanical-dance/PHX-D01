# lxr-audition

Audition LXR-02 kits (`.SND`) on the Mac with the LXR's own sound engine, compiled natively.
No SD-card swapping.

The engine is Erica Synths' open-source LXR firmware (`lxr-desktop-app`, GPL-3.0), cloned at
`~/code/vendor/lxr-02/lxr-desktop-app`. The build copies it to `build/src`, applies `patches/`,
and links it with `host/`. The vendor tree is never modified.

## Use
```sh
make
./build/lxr-play ~/code/synth/lxr-kits        # live: 1-6 hit voices, space all, ←/→ kit, e engine, q quit
./build/lxr-render KIT.SND out/kit.wav        # offline: hits each of the 6 voices
```
Engines are plugins (`build/engine-*.dylib`) exporting only `lxr_*` (see `host/engine.h`), so engines
built from different firmware trees, with clashing symbol names, can run side by side. `lxr-play` loads every
engine it finds next to itself and keeps the current kit loaded in all of them, so switching is instant.

## How it works
- Kit format (`.SND`, 255 bytes): 8-byte name, then 247 parameter bytes indexed by the firmware's
  `Parameters.h` enum (`END_OF_SOUND_PARAMETERS` = 247; the `//228` comment there is stale).
  Verified against `~/code/synth/lxr-kits/kit_analysis.md`. The Eurorack module and the desktop LXR use the same format.
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
