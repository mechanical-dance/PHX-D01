# Panels

Switch panels with the *LXR-02 desktop* / *LXR-Drum module* buttons. Both drive the same engines; the panel also sets the
hardware model (the module's kit format, mod matrix and its LFO/velocity rules; see [Module](module.md)).
Hover any control to see what it does. Controls the app doesn't model say so.

## Shared
- **Knobs** (4, under the display): drag or scroll to edit the 4 values the display shows. Double-click resets the value.
- **DATA encoder**:
  - In load mode, turning steps through kits; pushing opens the load dialog (bank and kit list).
  - In save mode, pushing opens the save dialog.
  - In edit mode, turning picks one of the 4 parameters (it shows in capitals) and pushing opens its detail view
    (long name and value). Push again to leave.
- **Triggers**: keys 1-7 (7 = open hat). Shift plays an accented hit.
- **Mutes**: SHIFT (latched) plus a voice button, or ⌥1-7. Mutes silence the sequencer and MIDI in; clicking still plays.
- Page markers `>` `*` `<` in the display's top-right mean there are more pages.

## Desktop (LXR-02)
- **Voice buttons** play and select a voice. **OSC … MIX** show that voice's pages; press again for the second row.
- **LOAD / SAVE**: load or save mode. SAVE again saves (⌘S).
- **PERF**: bpm, morph, sample rate and shuffle on the knobs.
- **SHIFT + RELOAD** (step 13) reverts the kit to its saved state. **SHIFT + COPY** (CLEAR), then **COPY**,
  resets the kit to INIT after a "Clear kit?" prompt.
- **Faders**: voice volumes, using the firmware's curve.
- **Output jacks**: click OUT 2 or MAIN OUT L/R to hear only that jack.
- The step buttons run the app's own sequencer, which isn't the LXR-02's (see the README).

## Module (LXR-Drum)
- **EDIT**: the select buttons pick the page. **DRUM** plus a select button picks the voice.
- **PERFORM**: the select buttons play the voices. The knobs are `mrp` (morph amount), `mtg` (morph target kit)
  and `sr` (global sample rate).
- **MOD**: the voice's mod matrix. Press again for slots a, b, c. **SHIFT + MOD** (or shift-click): its LFO. **FX**: the kit's effect.
- **SAVE/LOAD**: load mode. With SHIFT: save mode.
- **Trigger jacks**: click to fire; shift-click for an accented hit. **Accent jacks**: click to hold the gate high.
- **CV jacks**: drag or scroll for -5 to +5 V (0.1 V steps; shift: a semitone). Double-click for 0 V.
- **OUT1-4**: click to hear only that jack.

The module's pages follow its firmware: the MOD page shows dec/slp/mod/vol, the LFO page frq/ofs/wav/rtg, and MIX has no
len/ch/nte.
