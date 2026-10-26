# Kits, cards and projects

## Banks
Any folder of `.SND` files is a bank (File ▸ Open Kit Folder…). Kits are listed by the slot in their file name (`00-NAME.SND` …
`127-NAME.SND`; from 100 on the module writes `NNN-` and 4 letters). Empty slots up to 127 show as INIT.
Unsaved edits are kept per kit until you save or reload.

## SD cards
Both machines keep a project in `PROJ00` (with `GLO.CFG` and `PRJ.NFO`). The app tells the layouts apart:
- **Module**: 309-byte kits (with the mod matrix), or kits in slots 64 and up.
- **Desktop**: `.PAT` pattern files next to the kits.

When you save a card, it's written in the layout of the current panel. Kits without matrix data are saved as 255-byte
files that both machines read.

## Projects
A project is a folder in `~/Documents/PHX-D01/Projects/<name>/`:
- `PROJ00/`: the kits, laid out like a card, ready to copy back to an SD card.
- Samples: the user samples the kits play (File ▸ Import Samples…).
- `phx.json`: the app's own state: the 8 sequencer patterns, tempo, swing and panel layout.

File ▸ Open Project… accepts the project folder or its `PROJ00`.

## Samples
The LXR-02 holds up to 120 user samples in 1.5 MB of flash, about 17 s of 16-bit mono at 44.1 kHz.
The app enforces the 120-sample limit, but not the 1.5 MB, so check the total size before you copy samples to the hardware.
