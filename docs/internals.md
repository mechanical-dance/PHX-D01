# Internals

## Firmware on macOS
- **Kit loading**: each kit byte is sent to `frontParser_parseUartData` as a front-panel CC, as the firmware does.
- **Rendering**: `mixer_calcNextSampleBlock`, 64 stereo frames per call at 44.1 kHz.
- **Hardware stand-ins**: `shim/` (STM32 HAL, FatFs, USB headers) and `host/stubs.c` (front panel, LEDs, UART).
- **Fixes**: NULL parameter pointers go to scratch memory; kit index 127 is skipped (a firmware bug writes out of
  bounds); the ARM overflow flag read by the noise oscillator is computed in C (`patches/01`).

## Engines
Engines are plugins (`build/engine-*.dylib`) exporting only `lxr_*` (`host/engine.h`), so firmware trees with
conflicting symbols can run side by side. Every engine keeps the current kit loaded, so switching is immediate.

| Plugin | Source | Notes |
|---|---|---|
| `engine-lxr2.dylib` | Erica Synths `lxr-desktop-app` v1.7 (GPL-3.0) | Native kit format. |
| `engine-lxr1.dylib` | Sonic Potions 0.37 via LXR02Open (non-commercial) | Optional. Kits translated by parameter name (220 of 247). |

## Source layout
- `host/`: runtime (`audio.c`), MIDI (`midi.c`), engine wrapper and mod matrix (`engine.c`), kit reader (`kit.c`).
- `app/`: window, banks, cards and projects (`main.swift`, `Files.swift`); panels and sequencer UI (`web/`).
- `tools/`: generators for the display pages and module target table.
