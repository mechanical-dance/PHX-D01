# Internals

## Running the firmware on a Mac
- **Loading**: each kit byte goes to `frontParser_parseUartData` as a front-panel CC (param < 128: `MIDI_CC`,
  else `CC_2`, param − 128). That's the path the firmware uses when it loads a kit.
- **Rendering**: `mixer_calcNextSampleBlock`, 64 stereo frames per call at 44.1 kHz.
- `shim/` has stand-ins for the STM32 HAL (types, Cortex-M intrinsics), FatFs and the USB headers.
  `host/stubs.c` has a no-op front panel, LEDs, menu, UART and trigger outputs.
- **Native fixes**:
  - Parameter slots with a NULL pointer (`PAR_NONE`) point at scratch memory. On the STM32, address 0 is readable flash.
  - Kit index 127 is skipped. It's a firmware bug: it becomes CC 0, and `midiParser_ccHandler` writes past
    `midiParser_originalCcValues`.
  - The noise oscillator reads the ARM overflow flag; `patches/01` computes it in C.
- **Mod matrix (module)**: the engine runs the firmware's `ModulationNode`s on the 18 slots each tick. v/o scales
  the oscillator frequency after `osc_recalcFreq`; morph re-sends the morphed parameters when they change.

## Engines
Engines are plugins (`build/engine-*.dylib`) that export only `lxr_*` (`host/engine.h`). That way, engines built
from different firmware trees, with clashing symbol names, can run side by side. The runtime (`host/audio.c`) keeps
the current kit loaded in every engine, so switching is instant.

| Plugin | Source | Notes |
|---|---|---|
| `engine-lxr2.dylib` | Erica Synths `lxr-desktop-app` v1.7 (GPL-3.0) | the LXR-02 engine; kits load natively |
| `engine-lxr1.dylib` | Sonic Potions 0.37 via LXR02Open (non-commercial) | built only if LXR02Open is cloned; kits translated by parameter name (220 of 247) |

The LXR-1 translation drops the 27 LXR-2-only parameters (FX bus, PWM, morph). Voices routed to the FX bus play dry
on the main output. Waveform PWM becomes Rec, and sample slots shift down by one.

## Code map
- `host/audio.c`: runtime (engines, CoreAudio, sequencer).
- `host/midi.c`: CoreMIDI.
- `host/engine.c`: the plugin wrapper and module mod matrix.
- `host/kit.c`: the `.SND` reader.
- `app/main.swift`, `app/Files.swift`: the window, banks, cards, projects and settings.
- `app/web/`: the panels, display pages and sequencer UI.
- `tools/gen_pages.sh` generates the display pages from the firmware's menu tables.
