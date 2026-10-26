/* LXR-1 engine plugin: the Sonic Potions 0.37 sound engine as ported to STM32F7 by LXR02Open.
   Takes LXR-2 kits and translates them by parameter name (build/lxr1_map.h, from gen_map.py). */
#include <string.h>
#include "engine.h"
#include "lxr1_map.h"
#include "DrumVoice.h"
#include "Snare.h"
#include "CymbalVoice.h"
#include "HiHat.h"
#include "mixer.h"
#include "random.h"
#include "modulationNode.h"
#include "ParameterArray.h"
#include "frontPanelParser.h"
#include "MidiVoiceControl.h"
#include "MidiMessages.h"
#include "sequencer.h"
#include "SampleMemory.h"

const char *lxr_engine_name(void) { return "LXR-1"; }

void lxr_init(void)
{
	/* main.c dsp_init() */
	initRng();
	initDrumVoice();
	Snare_init();
	Cymbal_init();
	HiHat_init();
	mixer_init();
	parameterArray_init();
	static uint32_t scratch[4];   /* see engine.c: NULL parameter pointers are readable flash on the STM32 */
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++)
		if (!parameterArray[i].ptr) parameterArray[i].ptr = scratch;
	for (int i = 0; i < 6; i++) modNode_init(&velocityModulators[i]);
}

static void set_lfo_target(int lfo, uint8_t param)
{
	switch (lfo) {
	case 0: case 1: case 2: modNode_setDestination(&voiceArray[lfo].lfo.modTarget, param); break;
	case 3: modNode_setDestination(&snareVoice.lfo.modTarget, param); break;
	case 4: modNode_setDestination(&cymbalVoice.lfo.modTarget, param); break;
	case 5: modNode_setDestination(&hatVoice.lfo.modTarget, param); break;
	}
}

/* Mirrors LXR02Open preset_sendDrumsetParameters + preset_morphTick (morph 0), after translating the kit. */
void lxr_load_params(const uint8_t params[LXR_KIT_PARAMS])
{
	_Static_assert(LXR2_NUM_PARAMS == LXR_KIT_PARAMS, "kit size");
	_Static_assert(LXR1_NUM_PARAMS == END_OF_SOUND_PARAMETERS, "LXR-1 parameter count");
	int have[END_OF_SOUND_PARAMETERS] = {0};
	uint8_t p[END_OF_SOUND_PARAMETERS] = {0};
	for (int i = 0; i < LXR2_NUM_PARAMS; i++)
		if (lxr2_to_lxr1_param[i] >= 0) { p[lxr2_to_lxr1_param[i]] = params[i]; have[lxr2_to_lxr1_param[i]] = 1; }
	for (int i = 0; i < 6; i++) {
		const uint8_t vel = params[PAR_VEL_DEST_1 + i], lfo = params[PAR_TARGET_LFO1 + i];
		modNode_setDestination(&velocityModulators[i], vel < LXR2_NUM_MODTARGETS ? lxr2_modtarget_to_lxr1_param[vel] : 0);
		set_lfo_target(i, lfo < LXR2_NUM_MODTARGETS ? lxr2_modtarget_to_lxr1_param[lfo] : 0);
		if (p[PAR_VOICE_LFO1 + i] < 1 || p[PAR_VOICE_LFO1 + i] > 6) p[PAR_VOICE_LFO1 + i] = 1;
	}
	/* LXR-2-only values: the FX bus (routing 6) doesn't exist, so those voices play dry on the main output;
	   waveform 5 is PWM on the LXR-2 but the first sample slot on the LXR-1, so PWM becomes Rec and samples shift down. */
	for (int i = PAR_AUDIO_OUT1; i <= PAR_AUDIO_OUT6; i++) if (p[i] > MIXER_ROUTING_DAC2_R) p[i] = MIXER_ROUTING_DAC1_STEREO;
	static const int waves[] = {PAR_OSC_WAVE_DRUM1, PAR_OSC_WAVE_DRUM2, PAR_OSC_WAVE_DRUM3, PAR_OSC_WAVE_SNARE,
	                            PAR_WAVE1_CYM, PAR_WAVE1_HH, PAR_MOD_WAVE_DRUM1, PAR_MOD_WAVE_DRUM2, PAR_MOD_WAVE_DRUM3,
	                            PAR_WAVE2_CYM, PAR_WAVE3_CYM, PAR_WAVE2_HH, PAR_WAVE3_HH};
	for (unsigned w = 0; w < sizeof waves / sizeof *waves; w++) {
		uint8_t *v = &p[waves[w]];
		if (*v == 5) *v = 3; else if (*v > 5) *v -= 1;
	}
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++) if (have[i]) parameter_values[i] = p[i];
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++) {
		if (!have[i] || i == 127) continue;   /* 127: CC wraparound bug, skipped like preset_morphShouldSkip */
		if ((i >= PAR_VEL_DEST_1 && i <= PAR_VEL_DEST_6) || (i >= PAR_VOICE_LFO1 && i <= PAR_VOICE_LFO6) ||
		    (i >= PAR_TARGET_LFO1 && i <= PAR_TARGET_LFO6)) continue;
		if (i < 128) frontPanel_sendData(MIDI_CC, (uint8_t)i, p[i]);
		else frontPanel_sendData(CC_2, (uint8_t)(i - 128), p[i]);
	}
}

void lxr_hit(int voice, uint8_t velocity)
{
	if (voice >= 0 && voice < 7) voiceControl_noteOn((uint8_t)voice, SEQ_DEFAULT_NOTE, velocity);
}

void lxr1_set_samples(const int16_t *pcm, const uint32_t *offsets, const uint32_t *sizes, const uint8_t *loops, int count);
void lxr_set_samples(const int16_t *pcm, const uint32_t *offsets, const uint32_t *sizes, const uint8_t *loops, int count)
{
	lxr1_set_samples(pcm, offsets, sizes, loops, count);
}

void lxr_sample_limits(uint32_t *max_count, uint32_t *rom_bytes)
{
	*max_count = SAMPLE_MAX_COUNT;
	*rom_bytes = SAMPLE_ROM_SIZE;
}

static int16_t sat(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }

void lxr_render(int16_t jack[LXR_JACKS][LXR_BLOCK])
{
	_Static_assert(LXR_BLOCK % OUTPUT_DMA_SIZE == 0, "block size");
	static sample_mx_t a[OUTPUT_DMA_SIZE * 2], b[OUTPUT_DMA_SIZE * 2];
	for (int blk = 0; blk < LXR_BLOCK / OUTPUT_DMA_SIZE; blk++) {
		voiceControl_processPending();
		memset(a, 0, sizeof a); memset(b, 0, sizeof b);
		mixer_calcNextSampleBlock(a, b);
		for (int s = 0; s < OUTPUT_DMA_SIZE * 2; s++) {   /* 24-bit in int32 -> int16; DAC1 (main) is b */
			int i = blk * OUTPUT_DMA_SIZE + s / 2;
			jack[s & 1][i] = sat(b[s] >> 8);
			jack[2 + (s & 1)][i] = sat(a[s] >> 8);
		}
	}
}

void lxr_set_fader(int voice, float gain)
{
	extern float slider_vol[];
	if (voice >= 0 && voice < 6) slider_vol[voice] = gain;
}

void lxr_note(int voice, uint8_t note, uint8_t velocity)
{
	if (voice >= 0 && voice < 7) voiceControl_noteOn((uint8_t)voice, note > 127 ? 127 : note, velocity);
}
