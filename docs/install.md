# Install

## Requirements
- macOS on Apple Silicon, with Xcode command-line tools (`xcode-select --install`). Other platforms are not supported.
- **Erica Synths LXR-02 firmware** (required): compiled into the sound engine.
  ```sh
  git clone https://github.com/erica-synths/lxr-desktop-app ~/code/vendor/lxr-02/lxr-desktop-app
  ```
- **LXR02Open by Brendan Clarke** (optional): adds the Sonic Potions LXR-1 engine. Non-commercial licence, so not included.
  ```sh
  git clone https://github.com/brendanclarke/LXR02Open ~/code/vendor/lxr-02/LXR02Open
  ```

Other locations: `make VENDOR=/path/to/lxr-desktop-app VENDOR1=/path/to/LXR02Open`.

## Build
```sh
make app    # build/PHX-D01.app
make        # app, lxr-play and lxr-render
```

## Kits
Only an INIT kit is included.
- **Erica Synths factory kits**: download *Factory SD content* and *Sound Pack 1 (Hrtl DLC)* from the
  [LXR-02 product page](https://www.ericasynths.lv/shop/drum-machines/drum-synthesizer-lxr-02). Open the folder with
  File ▸ Open Kit Folder…, or place the kits in `~/Documents/PHX-D01/Banks/Erica-factory` to load them at launch.
- **SD card**: open a copy of the card with File ▸ Open Project….

## Command-line tools
```sh
./build/lxr-play path/to/kits             # play kits live
./build/lxr-render KIT.SND out/kit.wav    # render each voice to WAV
```
`lxr-play` keys: 1–7 voices, space all, ←/→ kit, `e` engine, `m` desktop/module, `o` solo output, `q` quit.
