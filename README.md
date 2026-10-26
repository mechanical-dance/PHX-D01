<p align="center"><img src="docs/logo.png" width="160" alt="PHX-D01 logo"></p>

# PHX-D01

Audition LXR kits (`.SND`) on the Mac with the LXR's own sound engine, compiled natively. No SD-card swapping.

- **The real engine.** Erica Synths' open-source LXR-02 firmware, built for macOS. An optional second engine plays
  the original Sonic Potions LXR (from Brendan Clarke's LXR02Open).
- **Two front panels.** The LXR-02 desktop and the LXR-Drum Eurorack module, with the hardware's menu pages,
  knobs, encoder and buttons.
- **Module mod matrix.** The module's 18 matrix slots load from its kit files. CV and accent jacks are playable sources,
  including v/o at 1 V/oct.
- **Morph.** Morph toward a target kit, from a slider, the perform knobs, or a matrix slot.
- **Kit banks and SD cards.** Open a folder as a bank, or load and save whole SD cards in the desktop or the module layout.
- **Projects.** Kits, samples and patterns in one folder.
- **Step sequencer.** 7 tracks, up to 32 steps, per-step velocity, accent and pitch, swing, and 8 pattern slots.
- **MIDI in and out, any audio device.** Output is a stereo mix or the 4 jacks on separate channels.
- **Command-line tools.** `lxr-play` plays kits live in the terminal; `lxr-render` renders a kit to WAV.

## Quick start
```sh
git clone https://github.com/erica-synths/lxr-desktop-app ~/code/vendor/lxr-02/lxr-desktop-app
git clone https://github.com/brendanclarke/LXR02Open ~/code/vendor/lxr-02/LXR02Open   # optional: LXR-1 engine
make app && open build/PHX-D01.app
```
The app ships with no kits. Get Erica's factory kits from the
[LXR-02 page](https://www.ericasynths.lv/shop/drum-machines/drum-synthesizer-lxr-02) (Downloads: *Factory SD
content*, *Sound Pack 1 (Hrtl DLC)*), or open your own card. See [Install](docs/install.md).

## Docs
- [Install](docs/install.md): prerequisites, building, getting kits
- [Panels](docs/panel.md): the desktop and module controls
- [Kits, cards and projects](docs/kits.md): banks, SD-card layouts, projects, samples
- [Module](docs/module.md): mod matrix, CV and accents, perform mode, how the module differs from the desktop
- [Internals](docs/internals.md): how the firmware runs on a Mac, the engines, the kit format

## Credits
- **Julian Schmidt / Sonic Potions**: the LXR drum synth and its firmware.
- **Erica Synths**: the LXR-02 and LXR-Drum, and the open-source
  [lxr-desktop-app](https://github.com/erica-synths/lxr-desktop-app) firmware (GPL-3.0).
- **Brendan Clarke**: [LXR02Open](https://github.com/brendanclarke/LXR02Open), the source of the LXR-1 engine.
- **Leoš Hort**: the Hrtl kit pack.

PHX-D01 is not affiliated with Erica Synths or Sonic Potions. "LXR", "LXR-02" and "Erica Synths" are their names.
Kits are their authors' work and aren't included here.
