# Kits, cards and projects

## Banks
Any folder of `.SND` files opens as a bank (File ▸ Open Kit Folder…). Kits are ordered by the slot number in the
file name (`00` to `127`); empty slots show as INIT.

## SD cards
Both machines store kits in `PROJ00`. The layout is detected automatically:
- **Module**: 309-byte kits, or kits in slots 64 and above.
- **Desktop**: `.PAT` pattern files present.

Cards are saved in the current panel's layout.

## Projects
A project (`~/Documents/PHX-D01/Projects/<name>/`) holds the kits in SD-card layout (`PROJ00/`), the card's
`samples/` and `loops/` folders, and the app's patterns and settings (`phx.json`). Open it with File ▸ Open Project….

The selected engine, panel, kit, morph and any unsaved kit edits are restored when the app restarts.


## Samples
User samples play on the LXR-1 engine and follow LXR02Open's behaviour on the LXR-02.

- **Card.** The project folder acts as the SD card: one-shots in `samples/`, loops in `loops/`. The sidebar adds files
  to the card (as copies) and removes them (to the Trash), then reloads.
- **Format.** Mono, 16-bit, 44.1 kHz PCM WAV. Other files are listed with the reason they were skipped. Nothing is
  converted.
- **Loading.** Load Samples (⇧⌘I) replaces the loaded set with `samples/`, then appends `loops/`, as the firmware's
  Load: Samples does. Files load in filename order, up to 120 samples in about 1.5 MB. Load Samples from Card…
  (⌥⇧⌘I) reads any folder, such as an SD card, without changing it. The loaded set persists across restarts and does
  not change with the project.
- **Selection.** Samples follow Cym in the waveform menu as `s01`, `s02`…; the display shows an 8-character name.
- **Playback.** Each trigger restarts the sample. LXR02Open reads at most 32,768 frames per sample, about 0.74 s at
  the original speed; longer samples wrap to the start. Coarse 29 with fine 35 plays a sample at its original speed
  (−34 on the display). Each 12 coarse steps halves or doubles the speed, so a file sped up 2× plays at its original
  pitch at coarse 17 (−46), and one sped up 4× at coarse 5 (−58), fitting two or four times as much audio.
- **Limitation.** Drum 1 does not play samples yet.
