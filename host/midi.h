/* MIDI in and out for the audition runtime (CoreMIDI). Out goes to one chosen destination and to a virtual
   source that DAWs see as "LXR Audition". In takes notes from one chosen source and plays them. */
#pragma once
#include <stdint.h>

enum { MIDI_PER_TRACK, MIDI_DRUM_MAP };   /* channel base+track with pitch as note / one channel, a GM note per track */

void midi_init(void (*on_note)(int track, int note, int vel));   /* on_note runs on the CoreMIDI thread */
int midi_out_count(void);
const char *midi_out_name(int i);
void midi_out_select(int i);    /* -1 = none (the virtual source still sends) */
int midi_in_count(void);
const char *midi_in_name(int i);
void midi_in_select(int i);     /* -1 = none */
void midi_set_mode(int mode, int base_channel);   /* base_channel 0-15 */
/* Called from the audio thread: a note for track 0-6, sent delay_ns from now. vel 0 = note off. */
void midi_send_note(int track, int note, int vel, uint64_t delay_ns);
