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
/* Optional (LXR-1 only): user samples, see LxaSamples in audio.h. */
LXR_API void lxr_set_samples(const int16_t *pcm, const uint32_t *offsets, const uint32_t *sizes, const uint8_t *loops, int count);
/* LXR-2 kit indexes of the six main oscillator waveforms (drum1-3, snare, cymbal, hihat). */
extern const int lxr_osc_wave_param[6];

int lxr_read_kit(const char *path, uint8_t params[LXR_KIT_PARAMS], char name[9]);   /* 0 on success; host side */
/* The firmware's kit morph (preset_morph_tick): amount 0-255 from kit a to kit b. Routing and mod targets stay on a. */
void lxr_morph_kit(const uint8_t a[LXR_KIT_PARAMS], const uint8_t b[LXR_KIT_PARAMS], uint8_t amount, uint8_t out[LXR_KIT_PARAMS]);
