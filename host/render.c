/* lxr-render: load a kit, hit each of the 6 voices, write a WAV. */
#include <stdio.h>
#include <stdlib.h>
#include "engine.h"

static void wav_header(FILE *f, uint32_t frames)
{
	uint32_t rate = LXR_RATE, bytes = frames * 4, chunk = 36 + bytes, fmtlen = 16, byterate = rate * 4;
	uint16_t pcm = 1, ch = 2, align = 4, bits = 16;
	fwrite("RIFF", 1, 4, f); fwrite(&chunk, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
	fwrite(&fmtlen, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
	fwrite(&byterate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
	fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f);
}

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: lxr-render KIT.SND out.wav\n"); return 2; }
	lxr_init();
	char name[9];
	uint8_t params[LXR_KIT_PARAMS];
	if (lxr_read_kit(argv[1], params, name)) { fprintf(stderr, "can't load %s\n", argv[1]); return 1; }
	lxr_load_params(params);
	static const char *vname[6] = {"drum1", "drum2", "drum3", "snare", "cymbal", "hihat"};
	const int blocks_per_hit = (int)(0.6 * LXR_RATE / LXR_BLOCK);
	FILE *out = fopen(argv[2], "wb");
	if (!out) { perror(argv[2]); return 1; }
	uint32_t frames = 0;
	int16_t buf[LXR_BLOCK * 2];
	wav_header(out, 0);
	for (int voice = 0; voice < 6; voice++) {
		int peak = 0;
		lxr_hit(voice, 127);
		for (int b = 0; b < blocks_per_hit; b++) {
			lxr_render(buf);
			for (int s = 0; s < LXR_BLOCK * 2; s++) if (abs(buf[s]) > peak) peak = abs(buf[s]);
			fwrite(buf, 2, LXR_BLOCK * 2, out);
			frames += LXR_BLOCK;
		}
		printf("  %-6s peak %5d\n", vname[voice], peak);
	}
	fseek(out, 0, SEEK_SET); wav_header(out, frames); fclose(out);
	printf("%s: %.1f s -> %s\n", name, frames / (double)LXR_RATE, argv[2]);
	return 0;
}
