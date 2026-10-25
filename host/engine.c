#include <string.h>
#include "engine.h"
#include "main.h"   /* jack-detect pins */
#include "Soundengine/Soundengine.h"
#include "Soundengine/MIDI/CortexParser.h"
#include "Soundengine/MIDI/MidiVoiceControl.h"
#include "Soundengine/MIDI/MidiMessages.h"
#include "Soundengine/MIDI/ParameterArray.h"
#include "frontPanelParser_ui.h"
#include "menu/menu.h"
#include "menu/CcNr2Text.h"

int16_t dma_buffer[OUTPUT_DMA_SIZE * 4], dma_buffer2[OUTPUT_DMA_SIZE * 4];

void lxr_init(void)
{
	/* every output jack patched, so the mixer's jack-detect fallback never reroutes a voice */
	switch_l1_GPIO_Port->IDR |= switch_l1_Pin | switch_r1_Pin;
	switch_l2_GPIO_Port->IDR |= switch_l2_Pin | switch_r2_Pin;
	mixer_init();
	parameterArray_init();
	/* On the STM32, address 0 is readable flash, so modulators aimed at PAR_NONE (ptr NULL) read junk harmlessly.
	   Natively that's a segfault: point unset slots at scratch storage instead. */
	static uint32_t scratch[4];
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++)
		if (!parameterArray[i].ptr) parameterArray[i].ptr = scratch;
	euklid_init();
	for (int i = 0; i < 6; i++) modNode_init(&velocityModulators[i]);
	seq_init();
	seq_setBpm(120);
	initDrumVoice();
	Snare_init();
	HiHat_init();
	Cymbal_init();
}

static void send(uint8_t status, uint8_t d1, uint8_t d2)
{
	frontParser_parseUartData(status);
	frontParser_parseUartData(d1);
	frontParser_parseUartData(d2);
}

const char *lxr_engine_name(void) { return "LXR-2"; }

/* Mirrors the firmware's kit load: preset_readDrumsetData, preset_sendDrumsetParameters (mod targets),
   then preset_morph_tick (every parameter as a front-panel CC; the parser adds the +1 offset below 128). */
void lxr_load_params(const uint8_t params[LXR_KIT_PARAMS])
{
	uint8_t p[END_OF_SOUND_PARAMETERS];
	memcpy(p, params, sizeof p);
	const uint8_t nmt = getNumModTargets();
	for (int i = 0; i < 6; i++) {
		if (p[PAR_VEL_DEST_1 + i] >= nmt) p[PAR_VEL_DEST_1 + i] = 0;
		if (p[PAR_TARGET_LFO1 + i] >= nmt) p[PAR_TARGET_LFO1 + i] = 0;
		if (p[PAR_VOICE_LFO1 + i] < 1 || p[PAR_VOICE_LFO1 + i] > 6) p[PAR_VOICE_LFO1 + i] = 1;
	}
	memcpy(activeParameters, p, END_OF_SOUND_PARAMETERS);
	for (int i = 0; i < 6; i++) {
		uint8_t value = (uint8_t)pgm_read_word(&modTargets[p[PAR_VEL_DEST_1 + i]].param);
		send(CC_VELO_TARGET, (uint8_t)(((value & 0x80) >> 7) | ((i & 0x3f) << 1)), value & 0x7f);
		value = (uint8_t)pgm_read_word(&modTargets[p[PAR_TARGET_LFO1 + i]].param);
		send(CC_LFO_TARGET, (uint8_t)(((value & 0x80) >> 7) | ((i & 0x3f) << 1)), value & 0x7f);
	}
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++) {
		/* Firmware bug: index 127 (PAR_BANK_CHANGE) becomes CC 0 after the +1 offset, and midiParser_ccHandler then
		   writes midiParser_originalCcValues[65536]. Skipped here (as LXR02Open does); bank change has no sound. */
		if (i == 127) continue;
		if (i < 128) send(MIDI_CC, (uint8_t)i, p[i]);
		else send(CC_2, (uint8_t)(i - 128), p[i]);
	}
}

_Static_assert(END_OF_SOUND_PARAMETERS == LXR_KIT_PARAMS, "LXR-2 kit size");

void lxr_hit(int voice, uint8_t velocity)
{
	if (voice >= 0 && voice < 7) voiceControl_noteOn((uint8_t)voice, SEQ_DEFAULT_NOTE, velocity);
}

void lxr_render(int16_t jack[LXR_JACKS][LXR_BLOCK])
{
	memset(dma_buffer, 0, sizeof dma_buffer);
	memset(dma_buffer2, 0, sizeof dma_buffer2);
	mixer_calcNextSampleBlock(dma_buffer, dma_buffer2);   /* DAC1 (main) goes to the second buffer */
	for (int i = 0; i < LXR_BLOCK; i++) {
		jack[0][i] = dma_buffer2[2 * i]; jack[1][i] = dma_buffer2[2 * i + 1];
		jack[2][i] = dma_buffer[2 * i];  jack[3][i] = dma_buffer[2 * i + 1];
	}
}

void lxr_set_fader(int voice, float gain)
{
	extern float lxr_fader_gain[6];
	if (voice >= 0 && voice < 6) lxr_fader_gain[voice] = gain;
}

void lxr_note(int voice, uint8_t note, uint8_t velocity)
{
	if (voice >= 0 && voice < 7) voiceControl_noteOn((uint8_t)voice, note > 127 ? 127 : note, velocity);
}
