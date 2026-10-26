# Install

## Prerequisites
- macOS on Apple Silicon, with the Xcode command-line tools (`xcode-select --install`), which provide `clang`, `swiftc` and `make`.
- **Erica's firmware** (required). The build compiles it; it isn't part of this repo.
  ```sh
  git clone https://github.com/erica-synths/lxr-desktop-app ~/code/vendor/lxr-02/lxr-desktop-app
  ```
- **Brendan Clarke's LXR02Open** (optional). It adds the original LXR (LXR-1) engine. Its licence is non-commercial,
  so it isn't part of this repo either. Without it the app has only the LXR-02 engine.
  ```sh
  git clone https://github.com/brendanclarke/LXR02Open ~/code/vendor/lxr-02/LXR02Open
  ```
Clones elsewhere work too: `make VENDOR=/path/to/lxr-desktop-app VENDOR1=/path/to/LXR02Open`.

## Build
```sh
make app                # build/PHX-D01.app
make                    # the app plus build/lxr-play and build/lxr-render
```
The build copies the firmware to `build/src` and applies `patches/`. It never modifies your clones.

## Kits
The app comes with only an INIT kit. Bring your own:
- **Erica's factory kits.** On the [LXR-02 page](https://www.ericasynths.lv/shop/drum-machines/drum-synthesizer-lxr-02),
  under Downloads, get *Factory SD content* and *Sound Pack 1 (Hrtl DLC)*. Unzip either and open its folder
  as a bank (File ▸ Open Kit Folder…), or put the factory kits in `~/Documents/PHX-D01/Banks/Erica-factory` so they always show as a bank.
- **Your own card.** Copy your LXR-02 or LXR-Drum SD card to the Mac and open it as a project (File ▸ Open Project…).
  Work on a copy, not the card itself.

The app keeps its files in `~/Documents/PHX-D01` (`Banks/`, `Projects/`).

## Command line
```sh
./build/lxr-play path/to/kits    # 1-7 trigger (7 = open hat), space all, ←/→ kit, e engine, m desktop/module, o jack solo, q quit
./build/lxr-render KIT.SND out/kit.wav    # renders each of the 6 voices
```
