/* lxa: the audition runtime shared by phx-play and the app. Loads the engine plugins, plays through CoreAudio,
   runs the step sequencer in the audio thread and sends/receives MIDI. Commands may come from any non-audio
   thread (UI, MIDI); they reach the audio thread through a ring. */
#pragma once
#include <stdint.h>
#include "engine.h"

enum { LXA_DESKTOP, LXA_MODULE };   /* hardware: LXR-02 (faders, velocity) or LXR-Drum (triggers, accents, no faders) */
#define LXA_TRACKS 7                /* the 7 triggers */
#define LXA_MAX_STEPS 32

typedef struct { uint8_t vel, note; } LxaStep;   /* vel 0 = no hit; note 60 = the kit's pitch */

int lxa_start(const char *engine_dir);   /* loads engine-*.dylib from engine_dir, starts audio; returns engine count */
void lxa_stop(void);
int lxa_engine_count(void);
const char *lxa_engine_name(int engine);

void lxa_load(const uint8_t params[LXR_KIT_PARAMS]);   /* into every engine, so switching engines keeps the kit */
void lxa_engine(int engine);
void lxa_hardware(int hw);
void lxa_hit(int trigger, int velocity);   /* trigger 0-6 (5 = closed hat, 6 = open hat), velocity 1-127 */
void lxa_note(int trigger, int note, int velocity);   /* pitched hit, also sent as MIDI */
void lxa_fader(int fader, float position); /* 0-5 voice faders, 6 master; position 0-1 as the fader sits */
void lxa_solo(int jack);
/* The LXR-Drum module's mod matrix (applied in the module hardware mode; see LxrMod in engine.h). */
void lxa_matrix(const uint8_t m[LXR_MOD_BYTES]);   /* the kit's 54 matrix bytes */
void lxa_morph(const uint8_t a[LXR_KIT_PARAMS], const uint8_t b[LXR_KIT_PARAMS], int amount);   /* after lxa_load: the unmorphed kit, its target, 0-255 */
void lxa_cv(int jack, float volts);                /* CV in 1-5 as 0-4, +-5 V */
void lxa_accent(int jack, int high);               /* accent in 1-6 as 0-5, held high or low */
void lxa_mute(int track, int on);         /* 0-6; a muted track still plays when hit by hand */                   /* 0 = all jacks mixed to the speakers, 1-4 = that jack alone */

/* User samples (LXR02Open engine only): mono 16-bit 44.1 kHz, one buffer; sample i starts at offsets[i] and is
   sizes[i] frames long. Sample i is oscillator waveform 6+i on the LXR-1 engine. */
typedef struct { const int16_t *pcm; const uint32_t *offsets, *sizes; const uint8_t *loops; int count; } LxaSamples;
void lxa_samples(const LxaSamples *set);
int lxa_engine_has_samples(int engine);

/* Sequencer. */
void lxa_pattern(const LxaStep steps[LXA_TRACKS][LXA_MAX_STEPS], int length);
void lxa_transport(int playing);
void lxa_tempo(float bpm, float swing);   /* swing 0-0.75: how far each odd step is pushed late, in steps */
int lxa_playhead(void);                   /* current step, -1 when stopped */
void lxa_hit_counts(uint32_t counts[LXA_TRACKS]);   /* per-trigger hit counters, to light the panel */

/* Audio output devices. */
int lxa_output_count(void);   /* rescans */
const char *lxa_output_name(int i);
int lxa_output_channels(int i);
/* i -1 = system default. channels 2 = stereo mix, 4 = one device channel per jack (main L/R, out2 L/R),
   starting at device channel first (0-based). Restarts audio; falls back to stereo/default if impossible. */
int lxa_set_output(int i, int channels, int first);
