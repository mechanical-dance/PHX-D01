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
A project (`~/Documents/PHX-D01/Projects/<name>/`) holds the kits in SD-card layout (`PROJ00/`) and
the app's patterns and settings (`phx.json`). Open it with File ▸ Open Project….

