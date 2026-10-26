/* The native LXR engine: init, kit loading, voice triggers, block rendering. Not thread-safe: call from one thread. */
#pragma once
#include <stdint.h>
#define LXR_BLOCK 64   /* frames per render call (OUTPUT_DMA_SIZE) */
#define LXR_JACKS 4    /* output jacks: DAC1 L/R (main), DAC2 L/R */
#define LXR_RATE 44100

#define LXR_API __attribute__((visibility("default")))

/* A kit is the 247 LXR-2 (.SND) parameter bytes after the 8-byte name. */
#define LXR_KIT_PARAMS 247

LXR_API const char *lxr_engine_name(void);
LXR_API void lxr_init(void);
LXR_API void lxr_load_params(const uint8_t params[LXR_KIT_PARAMS]);
LXR_API void lxr_hit(int voice, uint8_t velocity);          /* trigger 0-6: voices drum1-3, snare, cymbal, hihat; 5 and 6 both play the hihat (closed/open decay), closed chokes open */
LXR_API void lxr_note(int voice, uint8_t note, uint8_t velocity); /* as lxr_hit, pitched: note 60 = the kit's own pitch, +-1 = a semitone */
LXR_API void lxr_set_fader(int voice, float gain);           /* voice 0-5 fader gain 0-1, after the fader curve; 1 = no fader */
LXR_API void lxr_render(int16_t jack[LXR_JACKS][LXR_BLOCK]); /* one mono buffer per output jack */
/* Optional (LXR-2 only): the LXR-Drum module's mod matrix. 3 slots per voice, stored after the 247 kit bytes in the
   module's 309-byte .SND as 18 targets, 18 amounts (0-100 %), 18 sources (0-4 CV1-5, 5-10 LFO1-6, 11-16 accent 1-6).
   on = 0 is the desktop: each LFO and velocity has its own target. on = 1 is the module: those targets are silenced
   and the LFOs only reach the sound through the matrix. cv in volts (+-5), acc = accent gates. */
#define LXR_MOD_SLOTS 18
#define LXR_MOD_BYTES (3 * LXR_MOD_SLOTS)
typedef struct { uint8_t on; uint8_t dst[LXR_MOD_SLOTS], amt[LXR_MOD_SLOTS], src[LXR_MOD_SLOTS]; float cv[5]; uint8_t acc[6]; } LxrMod;
LXR_API void lxr_set_mod(const LxrMod *m);
/* Optional (LXR-2 only): the morph pair behind the loaded kit (a = the kit, b = the morph target, amount 0-255 as the
   host morphed it), so a matrix slot aimed at mrp can move the morph. Send after every lxr_load_params. */
LXR_API void lxr_set_morph(const uint8_t a[LXR_KIT_PARAMS], const uint8_t b[LXR_KIT_PARAMS], uint8_t amount);
/* Optional (LXR-1 only): user samples, see LxaSamples in audio.h. */
LXR_API void lxr_set_samples(const int16_t *pcm, const uint32_t *offsets, const uint32_t *sizes, const uint8_t *loops, int count);
/* LXR-2 kit indexes of the six main oscillator waveforms (drum1-3, snare, cymbal, hihat). */
extern const int lxr_osc_wave_param[6];

/* Host side. A kit file: the 8-byte name, the 247 params, and on the module the 54 mod-matrix bytes. params holds
   LXR_KIT_PARAMS + LXR_MOD_BYTES bytes; the matrix is zero (all slots off) for a 255-byte desktop kit. */
int lxr_read_kit(const char *path, uint8_t params[LXR_KIT_PARAMS + LXR_MOD_BYTES], char name[9]);   /* 0 on success */
/* The firmware's kit morph (preset_morph_tick): amount 0-255 from kit a to kit b. Routing and mod targets stay on a. */
void lxr_morph_kit(const uint8_t a[LXR_KIT_PARAMS], const uint8_t b[LXR_KIT_PARAMS], uint8_t amount, uint8_t out[LXR_KIT_PARAMS]);
