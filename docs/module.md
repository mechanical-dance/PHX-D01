# Module (LXR-Drum)

The Eurorack module's firmware is closed. What's here comes from its manual, its kit files, its firmware image,
and listening to the hardware.

## Kit format
A module kit is 309 bytes: the desktop's 255 (8-byte name and 247 parameters), then 54 bytes of mod matrix:
- 18 slots, 3 per voice (a, b, c).
- 18 destination bytes, then 18 amounts (0-100), then 18 sources.
- Sources: 0-4 = cv1-5, 5-10 = lf1-6 (the voice LFOs), 11-16 = ac1-6 (the accent jacks).
- A destination is an index into the module's target table: per voice, v/o first, then the desktop's targets,
  then `mrp` (morph). `tools/gen_module_targets.py` extracts the table from a firmware image
  (`LXRE_V2_*.img`) into `host/module_targets.h` and `app/web/modtargets.js`.

## Mod matrix
Each slot moves its destination around the kit's value, in both directions, by its amount (module manual 5.3.1):
- **v/o**: at 100 %, 1 V/oct over 5 octaves. Negative CV is ignored.
- **mrp**: morph toward the target kit, adding to the perform knob's morph amount.

The matrix is per kit, which matches the module's *Global CV Save* off setting.

## Differences from the desktop
- **LFO and velocity targets are ignored.** The module stores them in the kit but routes the voice LFOs and accents
  only through the matrix. In module mode the app does the same, so kits made on the desktop can sound different.
  This was checked by ear on the hardware.
- **Accent, not velocity.** An accent gate gives a full-velocity hit and is also a matrix source.
  Accent jack 6 drives both hihats.
- **Tails.** With feedback near maximum, the delay can ring for a long time (for example a 61 Hz drone on the Hrtl kit
  TAIPE). That's the engine, on the hardware too, not a bug in the app.
