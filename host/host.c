/* lxr-render: load an LXR .SND kit into the native engine, hit each voice, write a WAV. */
#include <stdio.h>
#include <stdlib.h>
#include "Soundengine/Soundengine.h"
#include "Soundengine/MIDI/CortexParser.h"
#include "Soundengine/MIDI/MidiVoiceControl.h"
#include "Soundengine/MIDI/MidiMessages.h"
#include "frontPanelParser_ui.h"
#include "Soundengine/MIDI/ParameterArray.h"

extern GPIO_TypeDef native_gpio[11];
int16_t dma_buffer[OUTPUT_DMA_SIZE * 4], dma_buffer2[OUTPUT_DMA_SIZE * 4];

static void engine_init(void)
{
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

/* Same path the firmware takes when a kit is loaded: each byte goes to the engine as a front-panel CC. */
static int kit_load(const char *path, char name[9])
{
	uint8_t k[8 + END_OF_SOUND_PARAMETERS];
	FILE *f = fopen(path, "rb");
	if (!f) return -1;
	size_t n = fread(k, 1, sizeof k, f);
	fclose(f);
	if (n != sizeof k) return -2;
	memcpy(name, k, 8); name[8] = 0;
	for (int i = 0; i < END_OF_SOUND_PARAMETERS; i++) {
		uint8_t v = k[8 + i];
		if (i < 128) send(MIDI_CC, (uint8_t)i, v);
		else send(CC_2, (uint8_t)(i - 128), v);
	}
	return 0;
}

static void wav_header(FILE *f, uint32_t frames)
{
	uint32_t rate = 44100, bytes = frames * 4, chunk = 36 + bytes, fmtlen = 16, byterate = rate * 4;
	uint16_t pcm = 1, ch = 2, align = 4, bits = 16;
	fwrite("RIFF", 1, 4, f); fwrite(&chunk, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
	fwrite(&fmtlen, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
	fwrite(&byterate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
	fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f);
}

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: lxr-render KIT.SND out.wav\n"); return 2; }
	engine_init();
	char name[9];
	int r = kit_load(argv[1], name);
	if (r) { fprintf(stderr, "can't load %s (%d)\n", argv[1], r); return 1; }
	const int blocks_per_hit = (int)(0.6 * 44100 / OUTPUT_DMA_SIZE);
	FILE *out = fopen(argv[2], "wb");
	uint32_t frames = 0;
	wav_header(out, 0);
	if (getenv("LXR_JACKS")) for (int g = 0; g < 11; g++) native_gpio[g].IDR = (uint32_t)strtoul(getenv("LXR_JACKS"), 0, 0);
	static const char *vname[6] = {"drum1", "drum2", "drum3", "snare", "cymbal", "hihat"};
	int16_t mix[OUTPUT_DMA_SIZE * 2];
	for (int voice = 0; voice < 6; voice++) {
		int peak = 0;
		voiceControl_noteOn(voice, 60, 127);
		for (int b = 0; b < blocks_per_hit; b++) {
			memset(dma_buffer, 0, sizeof dma_buffer); memset(dma_buffer2, 0, sizeof dma_buffer2);
			mixer_calcNextSampleBlock(dma_buffer, dma_buffer2);
			/* sum both output pairs (DAC1 = main, DAC2 = second) so routing can't hide a voice */
			for (int s = 0; s < OUTPUT_DMA_SIZE * 2; s++) {
				int v = dma_buffer[s] + dma_buffer2[s];
				mix[s] = v > 32767 ? 32767 : v < -32768 ? -32768 : v;
				if (abs(mix[s]) > peak) peak = abs(mix[s]);
			}
			fwrite(mix, 2, OUTPUT_DMA_SIZE * 2, out);
			frames += OUTPUT_DMA_SIZE;
		}
		printf("  %-6s peak %5d\n", vname[voice], peak);
	}
	fseek(out, 0, SEEK_SET); wav_header(out, frames); fclose(out);
	printf("%s: %.1f s -> %s\n", name, frames / 44100.0, argv[2]);
	return 0;
}
