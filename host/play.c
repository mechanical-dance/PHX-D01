/* lxr-play: audition LXR kits live. Loads each engine plugin (build/engine-*.dylib), plays through CoreAudio.
   Keys: 1-6 hit drum1-3/snare/cymbal/hihat, space hits all six in turn, left/right or j/k change kit,
   e switch engine, q quit. */
#include <AudioToolbox/AudioToolbox.h>
#include <dirent.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include "engine.h"

typedef struct {
	const char *(*name)(void);
	void (*init)(void);
	void (*load)(const uint8_t *);
	void (*hit)(int, uint8_t);
	void (*render)(int16_t *);
} Engine;

#define MAX_ENGINES 4
#define MAX_KITS 512
static Engine engines[MAX_ENGINES];
static int n_engines;
static char *kit_paths[MAX_KITS], kit_names[MAX_KITS][9];
static int n_kits;

/* Commands from the UI thread to the audio thread (single producer, single consumer). */
enum { CMD_HIT, CMD_LOAD, CMD_ENGINE };
typedef struct { int type, arg; uint8_t params[LXR_KIT_PARAMS]; } Cmd;
static Cmd ring[64];
static _Atomic int ring_w, ring_r;
static int active;   /* engine index, audio thread only */

static void push(Cmd c)
{
	int w = atomic_load(&ring_w);
	if ((w + 1) % 64 == atomic_load(&ring_r)) return;   /* full: drop */
	ring[w] = c;
	atomic_store(&ring_w, (w + 1) % 64);
}

static void audio_cb(void *ud, AudioQueueRef q, AudioQueueBufferRef buf)
{
	(void)ud;
	int r;
	while ((r = atomic_load(&ring_r)) != atomic_load(&ring_w)) {
		Cmd *c = &ring[r];
		if (c->type == CMD_HIT) engines[active].hit(c->arg, 127);
		else if (c->type == CMD_LOAD) for (int e = 0; e < n_engines; e++) engines[e].load(c->params);
		else if (c->type == CMD_ENGINE) active = c->arg;
		atomic_store(&ring_r, (r + 1) % 64);
	}
	int16_t *out = buf->mAudioData;
	int blocks = buf->mAudioDataBytesCapacity / (LXR_BLOCK * 4);
	for (int b = 0; b < blocks; b++) engines[active].render(out + b * LXR_BLOCK * 2);
	buf->mAudioDataByteSize = blocks * LXR_BLOCK * 4;
	AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static int load_engine(const char *path)
{
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!h) return 0;
	Engine e = { dlsym(h, "lxr_engine_name"), dlsym(h, "lxr_init"), dlsym(h, "lxr_load_params"), dlsym(h, "lxr_hit"), dlsym(h, "lxr_render") };
	if (!e.name || !e.init || !e.load || !e.hit || !e.render) { fprintf(stderr, "%s: missing symbols\n", path); return 0; }
	e.init();
	engines[n_engines++] = e;
	return 1;
}

static int cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void add_kits(const char *arg)
{
	DIR *d = opendir(arg);
	if (!d) { if (n_kits < MAX_KITS) kit_paths[n_kits++] = strdup(arg); return; }
	struct dirent *de;
	int first = n_kits;
	while ((de = readdir(d)) && n_kits < MAX_KITS) {
		size_t l = strlen(de->d_name);
		if (l > 4 && strcasecmp(de->d_name + l - 4, ".snd") == 0 && de->d_name[0] != '.') {
			char *p = malloc(strlen(arg) + l + 2);
			sprintf(p, "%s/%s", arg, de->d_name);
			kit_paths[n_kits++] = p;
		}
	}
	closedir(d);
	qsort(kit_paths + first, n_kits - first, sizeof(char *), cmp);
}

static struct termios saved;
static void restore_tty(void) { tcsetattr(0, TCSANOW, &saved); printf("\n"); }

static void status(int kit, int eng)
{
	const char *file = strrchr(kit_paths[kit], '/');
	printf("\r\033[K[%s]  kit %d/%d  %-8s  (%s)   1-6 hit · space all · ←/→ kit · e engine · q quit",
	       engines[eng].name(), kit + 1, n_kits, kit_names[kit], file ? file + 1 : kit_paths[kit]);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: lxr-play KIT.SND|DIR ...\n"); return 2; }
	char dir[1024], path[1100];
	uint32_t sz = sizeof dir;
	_NSGetExecutablePath(dir, &sz);
	*strrchr(dir, '/') = 0;
	const char *names[] = {"engine-lxr2.dylib", "engine-lxr1.dylib"};
	for (int i = 0; i < 2; i++) { snprintf(path, sizeof path, "%s/%s", dir, names[i]); load_engine(path); }
	if (!n_engines) { fprintf(stderr, "no engines found next to lxr-play\n"); return 1; }

	for (int i = 1; i < argc; i++) add_kits(argv[i]);
	static uint8_t params[MAX_KITS][LXR_KIT_PARAMS];
	int good = 0;
	for (int i = 0; i < n_kits; i++)
		if (lxr_read_kit(kit_paths[i], params[good], kit_names[good]) == 0) { kit_paths[good] = kit_paths[i]; good++; }
	n_kits = good;
	if (!n_kits) { fprintf(stderr, "no readable .SND kits\n"); return 1; }

	AudioStreamBasicDescription fmt = { .mSampleRate = LXR_RATE, .mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
		.mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 16 };
	AudioQueueRef q;
	if (AudioQueueNewOutput(&fmt, audio_cb, NULL, NULL, NULL, 0, &q)) { fprintf(stderr, "can't open audio output\n"); return 1; }
	int kit = 0, eng = 0;
	Cmd c = { .type = CMD_LOAD };
	memcpy(c.params, params[kit], LXR_KIT_PARAMS);
	push(c);
	for (int i = 0; i < 3; i++) {   /* 3 x 256 frames: ~6 ms per buffer */
		AudioQueueBufferRef b;
		AudioQueueAllocateBuffer(q, LXR_BLOCK * 4 * 4, &b);
		audio_cb(NULL, q, b);
	}
	AudioQueueStart(q, NULL);

	tcgetattr(0, &saved);
	struct termios raw = saved;
	raw.c_lflag &= ~(ICANON | ECHO);
	tcsetattr(0, TCSANOW, &raw);
	atexit(restore_tty);
	status(kit, eng);

	for (;;) {
		int ch = getchar(), next = kit;
		if (ch == 'q' || ch == EOF) break;
		if (ch >= '1' && ch <= '6') push((Cmd){ .type = CMD_HIT, .arg = ch - '1' });
		else if (ch == ' ') for (int v = 0; v < 6; v++) { push((Cmd){ .type = CMD_HIT, .arg = v }); usleep(250000); }
		else if (ch == 'e' && n_engines > 1) { eng = (eng + 1) % n_engines; push((Cmd){ .type = CMD_ENGINE, .arg = eng }); }
		else if (ch == 'k' || ch == 'l') next = (kit + 1) % n_kits;
		else if (ch == 'j' || ch == 'h') next = (kit + n_kits - 1) % n_kits;
		else if (ch == 27 && getchar() == '[') { int a = getchar(); if (a == 'C') next = (kit + 1) % n_kits; if (a == 'D') next = (kit + n_kits - 1) % n_kits; }
		if (next != kit) {
			kit = next;
			c = (Cmd){ .type = CMD_LOAD };
			memcpy(c.params, params[kit], LXR_KIT_PARAMS);
			push(c);
		}
		status(kit, eng);
	}
	AudioQueueStop(q, true);
	return 0;
}
