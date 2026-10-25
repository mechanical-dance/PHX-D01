/* The native LXR engine: init, kit loading, voice triggers, block rendering. Not thread-safe: call from one thread. */
#pragma once
#include <stdint.h>
#define LXR_BLOCK 64   /* stereo frames per render call (OUTPUT_DMA_SIZE) */
#define LXR_RATE 44100

#define LXR_API __attribute__((visibility("default")))

/* A kit is the 247 LXR-2 (.SND) parameter bytes after the 8-byte name. */
#define LXR_KIT_PARAMS 247

LXR_API const char *lxr_engine_name(void);
LXR_API void lxr_init(void);
LXR_API void lxr_load_params(const uint8_t params[LXR_KIT_PARAMS]);
LXR_API void lxr_hit(int voice, uint8_t velocity);          /* voice 0-5: drum1-3, snare, cymbal, hihat */
LXR_API void lxr_render(int16_t out[LXR_BLOCK * 2]);        /* interleaved stereo, all outputs summed */

int lxr_read_kit(const char *path, uint8_t params[LXR_KIT_PARAMS], char name[9]);   /* 0 on success; host side */
