# lxr-audition

Audition LXR-02 kits (`.SND`) on the Mac with the LXR's own sound engine, compiled natively.
No SD-card swapping.

The engine is Erica Synths' open-source LXR firmware (`lxr-desktop-app`, GPL-3.0), cloned at
`~/code/vendor/lxr-02/lxr-desktop-app`. The build copies it to `build/src`, applies `patches/`,
and links it with `host/`. The vendor tree is never modified.

## Use
```sh
make
./build/lxr-render ~/code/synth/lxr-kits/05-WOODS.SND out/woods.wav   # hits each of the 6 voices
afplay out/woods.wav
```

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

## Not yet
- Velocity / LFO mod targets from the kit (`CC_VELO_TARGET`, `CC_LFO_TARGET`) aren't sent yet, so modulation routing is off.
- Interactive player (keys 1-6, step through a folder of kits).
