#!/bin/zsh
# Syntax-check the vendor sound engine natively; prints the first errors per file.
S=${0:A:h}/shim; V=~/code/vendor/lxr-02/lxr-desktop-app/Core
cd $V/Src
for f in Soundengine/DSPAudio/*.c Soundengine/DSPAudio/FX/*.c Soundengine/DSPAudio/FX/*/*.c(N) Soundengine/FxBus.c Soundengine/Soundengine.c Soundengine/MIDI/*.c; do
  out=$(clang -std=gnu11 -fsyntax-only -w '-Dsection(x)=unused' -I$S -I$V/Inc -I$V/Inc/Soundengine -I$V/Src "$f" 2>&1 | grep "error:" | head -${N:-2})
  [[ -n $out ]] && print -r -- "== $f" && print -r -- "${out//$V\//}"
done
