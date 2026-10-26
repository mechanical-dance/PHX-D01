# Module (LXR-Drum)

The LXR-Drum firmware is closed source. This page is based on the module manual, its kit files and firmware image,
and tests on the hardware.

## Kit format
309 bytes: the 255-byte desktop kit, then 54 bytes of mod matrix (18 slots, three per voice):
- 18 destinations, then 18 amounts (0–100), then 18 sources.
- Sources: 0–4 CV inputs, 5–10 voice LFOs, 11–16 accent inputs.
- Destinations index the module's target table, extracted from a firmware image by `tools/gen_module_targets.py`.

## Mod matrix
Each slot modulates its destination around the kit's value by its amount.
- **v/o**: 1 V/octave at 100%, over 5 octaves; negative voltages are ignored.
- **mrp**: morphs toward the target kit.

## Differences from the desktop
- **LFO and velocity targets** stored in the kit are ignored; modulation goes through the matrix only.
- **Accents** trigger full-velocity hits and act as matrix sources. Accent input 6 controls both hi-hats.
