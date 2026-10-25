#!/bin/zsh
# Syntax-check the LXR02Open (LXR-1 0.37 port) engine natively; prints the first errors per file.
S=${0:A:h}; V=~/code/vendor/lxr-02/LXR02Open/Core
INC=(-I$S/shim1 -I$S/shim -I$V/..); for d in $V $V/**/*(/); do INC+=(-I$d); done
cd $V
for f in DSPAudio/*.c MIDI/*.c Sequencer/*.c Preset/ParameterArray.c; do
  out=$(clang -std=gnu11 -fsyntax-only -w '-Dsection(x)=unused' $INC "$f" 2>&1 | grep "error:" | head -${N:-2})
  [[ -n $out ]] && print -r -- "== $f" && print -r -- "${out//$V\//}"
done
