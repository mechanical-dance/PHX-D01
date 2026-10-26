/* phx-play: audition LXR kits live. Loads each engine plugin (build/engine-*.dylib), plays through CoreAudio.
   Keys: 1-7 are the 7 triggers for the 6 voices (drum1-3, snare, cymbal, hihat; 6 = closed hat, 7 = open hat on the
   same voice, closed chokes open), space fires all in turn, left/right or j/k change kit,
   e switch engine, m switch hardware (LXR-02 desktop / LXR-Drum module), o solo an output jack, q quit.
   Desktop: hits play at a velocity, [ and ] change it. Module: no velocity, only triggers and accent gates:
   plain keys trigger unaccented, shift+1-7 (!@#$%^&) trigger with the accent gate high (one accent per voice: 6 and 7 share accent 6). */
#include <dirent.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include "audio.h"

#define MAX_KITS 512
static char *kit_paths[MAX_KITS], kit_names[MAX_KITS][9];
static int n_kits;

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

/* Hardware: what the inputs and outputs are. Both units run the same voice engine and FX bus. */
static const char *hw_name[] = {"LXR-02", "LXR-Drum"};
static const char *jack_name[2][5] = {{"mix", "main L", "main R", "out2 L", "out2 R"}, {"mix", "out 1", "out 2", "out 3", "out 4"}};
/* Accent gate levels as velocities. The module firmware is closed: these two values are an assumption. */
#define ACCENT_OFF 64
#define ACCENT_ON 127

static void status(int kit, int eng, int hw, int vel, int solo_jack)
{
	const char *file = strrchr(kit_paths[kit], '/');
	char input[24];
	if (hw == LXA_DESKTOP) snprintf(input, sizeof input, "vel %d ([ ])", vel);
	else snprintf(input, sizeof input, "shift = accent");
	printf("\r\033[K[%s · %s]  kit %d/%d %-8s (%s)  %s  jack %s   1-7 hit · m hw · e eng · o jack · q",
	       lxa_engine_name(eng), hw_name[hw], kit + 1, n_kits, kit_names[kit], file ? file + 1 : kit_paths[kit],
	       input, jack_name[hw][solo_jack]);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: phx-play KIT.SND|DIR ...\n"); return 2; }
	char dir[1024];
	uint32_t sz = sizeof dir;
	_NSGetExecutablePath(dir, &sz);
	*strrchr(dir, '/') = 0;
	for (int i = 1; i < argc; i++) add_kits(argv[i]);
	static uint8_t params[MAX_KITS][LXR_KIT_PARAMS + LXR_MOD_BYTES];
	int good = 0;
	for (int i = 0; i < n_kits; i++)
		if (lxr_read_kit(kit_paths[i], params[good], kit_names[good]) == 0) { kit_paths[good] = kit_paths[i]; good++; }
	n_kits = good;
	if (!n_kits) { fprintf(stderr, "no readable .SND kits\n"); return 1; }

	int kit = 0, eng = 0;
	if (!lxa_start(dir)) { fprintf(stderr, "no engines next to phx-play, or no audio output\n"); return 1; }
	lxa_load(params[kit]);

	tcgetattr(0, &saved);
	struct termios raw = saved;
	raw.c_lflag &= ~(ICANON | ECHO);
	tcsetattr(0, TCSANOW, &raw);
	atexit(restore_tty);
	int hw = LXA_DESKTOP, vel = 127, solo_jack = 0;
	status(kit, eng, hw, vel, solo_jack);

	static const char accent_keys[] = "!@#$%^&";
	for (;;) {
		int ch = getchar(), next = kit;
		const char *acc = ch > 0 ? strchr(accent_keys, ch) : NULL;
		if (ch == 'q' || ch == EOF) break;
		if (ch >= '1' && ch <= '7') lxa_hit(ch - '1', hw == LXA_DESKTOP ? vel : ACCENT_OFF);
		else if (acc && hw == LXA_MODULE) lxa_hit((int)(acc - accent_keys), ACCENT_ON);
		else if (ch == ' ') for (int v = 0; v < 7; v++) { lxa_hit(v, hw == LXA_DESKTOP ? vel : ACCENT_OFF); usleep(250000); }
		else if (ch == '[' && hw == LXA_DESKTOP) vel = vel > 8 ? vel - 8 : 1;
		else if (ch == ']' && hw == LXA_DESKTOP) vel = vel < 119 ? vel + 8 : 127;
		else if (ch == 'm') lxa_hardware(hw = !hw);
		else if (ch == 'o') { solo_jack = (solo_jack + 1) % (LXR_JACKS + 1); lxa_solo(solo_jack); }
		else if (ch == 'e' && lxa_engine_count() > 1) lxa_engine(eng = (eng + 1) % lxa_engine_count());
		else if (ch == 'k' || ch == 'l') next = (kit + 1) % n_kits;
		else if (ch == 'j' || ch == 'h') next = (kit + n_kits - 1) % n_kits;
		else if (ch == 27 && getchar() == '[') { int a = getchar(); if (a == 'C') next = (kit + 1) % n_kits; if (a == 'D') next = (kit + n_kits - 1) % n_kits; }
		if (next != kit) {
			kit = next;
			lxa_load(params[kit]);
		}
		status(kit, eng, hw, vel, solo_jack);
	}
	lxa_stop();
	return 0;
}
