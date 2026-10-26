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
#include "Soundengine/DSPAudio/Oscillator.h"
#include "module_targets.h"

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

static void route_targets(void);
static void mod_tick(void);
static LxrMod mod;

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
	route_targets();
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++) {
		/* Firmware bug: index 127 (PAR_BANK_CHANGE) becomes CC 0 after the +1 offset, and midiParser_ccHandler then
		   writes midiParser_originalCcValues[65536]. Skipped here (as LXR02Open does); bank change has no sound. */
		if (i == 127) continue;
		if (i < 128) send(MIDI_CC, (uint8_t)i, p[i]);
		else send(CC_2, (uint8_t)(i - 128), p[i]);
	}
	if (mod.on) mod_tick();
}

_Static_assert(END_OF_SOUND_PARAMETERS == LXR_KIT_PARAMS, "LXR-2 kit size");

/* ---------- the LXR-Drum module's mod matrix (its firmware is closed; behaviour from its manual, p.15) ----------
   Each slot is a modulation node like the firmware's LFOs and velocity: bipolar around the parameter's current value,
   amount 0-100 % of the full range. Sources in 0-1, 0.5 = no change: a CV maps -5..+5 V, an LFO its own output, an
   accent gate 0 V (off) or +5 V (on). The v/o target scales a CV to 1 V/oct on the voice's oscillator, positive
   volts only (5 octaves). The morph target (the module's PAR_MORPH) isn't modeled. */
static ModulationNode slot_node[LXR_MOD_SLOTS];
static float vo_oct[6];

static OscInfo *voice_osc(int v)
{
	return v < 3 ? &voiceArray[v].osc : v == 3 ? &snareVoice.osc : v == 4 ? &cymbalVoice.osc : &hatVoice.osc;
}
static float lfo_out(int v)
{
	const Lfo *l = v < 3 ? &voiceArray[v].lfo : v == 3 ? &snareVoice.lfo : v == 4 ? &cymbalVoice.lfo : &hatVoice.lfo;
	return l->modTarget.lastVal;
}
static float source(uint8_t s)
{
	if (s < 5) { float v = mod.cv[s]; return ((v < -5 ? -5 : v > 5 ? 5 : v) + 5) / 10; }
	if (s < 11) return lfo_out(s - 5);
	if (s < 17) return mod.acc[s - 11] ? 1.f : .5f;
	return .5f;
}

/* Desktop: each LFO and velocity modulator aims at the kit's own target. Module: at nothing (PAR_NONE), so the LFOs
   still run (the matrix reads them) but only the matrix moves the sound. The module saves these targets as 1. */
static void route_targets(void)
{
	for (int i = 0; i < 6; i++) {
		uint8_t lfo = 0, vel = 0;
		if (!mod.on) {
			lfo = (uint8_t)pgm_read_word(&modTargets[activeParameters[PAR_TARGET_LFO1 + i]].param);
			vel = (uint8_t)pgm_read_word(&modTargets[activeParameters[PAR_VEL_DEST_1 + i]].param);
		}
		send(CC_VELO_TARGET, (uint8_t)(((vel & 0x80) >> 7) | ((i & 0x3f) << 1)), vel & 0x7f);
		send(CC_LFO_TARGET, (uint8_t)(((lfo & 0x80) >> 7) | ((i & 0x3f) << 1)), lfo & 0x7f);
	}
}

/* v/o: the oscillator's own pitch (osc_recalcFreq: note, coarse, fine) times 2^octaves. Redone every block, since
   note on, a kit load or a slot on coarse/fine recalculates the pitch without it. */
static void apply_vo(void)
{
	for (int v = 0; v < 6; v++) {
		float oct = 0;
		for (int k = 0; k < 3 && mod.on; k++) {
			const int s = v * 3 + k;
			const uint8_t t = mod.dst[s];
			if (t >= MODULE_TARGETS || module_target_param[t] != PAR_UNUSED_1 + v) continue;
			const float volts = source(mod.src[s]) * 10 - 5;
			if (volts > 0) oct += volts * mod.amt[s] / 100.f;
		}
		if (oct > 5) oct = 5;
		if (oct == 0 && vo_oct[v] == 0) continue;
		OscInfo *o = voice_osc(v);
		osc_recalcFreq(o);
		o->freq *= exp2f(oct);
		vo_oct[v] = oct;
	}
}

static void mod_tick(void)
{
	for (int s = 0; s < LXR_MOD_SLOTS; s++) {
		const uint8_t t = mod.dst[s];
		uint16_t par = mod.on && t < MODULE_TARGETS ? module_target_param[t] : PAR_NONE;
		if (par >= END_OF_SOUND_PARAMETERS || (par >= PAR_UNUSED_1 && par <= PAR_UNUSED_6)) par = PAR_NONE;   /* morph; v/o */
		ModulationNode *n = &slot_node[s];
		if (n->destination != par) {
			if (n->destination != PAR_NONE) { n->amount = 0; modNode_updateValue(n, .5f); }   /* back to the kit's value */
			n->destination = par;
		}
		if (par == PAR_NONE) continue;
		n->amount = mod.amt[s] / 100.f;
		modNode_updateValue(n, source(mod.src[s]));
	}
	apply_vo();
}

void lxr_set_mod(const LxrMod *m)
{
	const int was = mod.on;
	mod = *m;
	if (mod.on != was) route_targets();
	mod_tick();
}

void lxr_hit(int voice, uint8_t velocity) { lxr_note(voice, SEQ_DEFAULT_NOTE, velocity); }

void lxr_render(int16_t jack[LXR_JACKS][LXR_BLOCK])
{
	if (mod.on) mod_tick();
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
	if (voice < 0 || voice >= 7) return;
	if (mod.on) mod_tick();   /* an accent gate that came with this hit reaches the sound before the note starts */
	voiceControl_noteOn((uint8_t)voice, note > 127 ? 127 : note, velocity);
	if (mod.on) apply_vo();   /* note on recalculated the pitch */
}
