/* Dumps the LXR-2 voice menu pages and the FX bus page (labels, parameter numbers, display types) and value-name lists as JSON. */
#include <stdio.h>
#include <stdint.h>
#include "menu.h"
#include "MenuText.h"
#include "menuPages.h"
#include "dtypes.inc"   /* parameter_dtypes, cut from menu.c by tools/gen_pages.sh */
#include "names.inc"    /* valueNames, cut from menu.c */
static void str(const char *s, int n) { putchar('"'); for (int i = 0; i < n && s[i]; i++) if (s[i] >= 32 && s[i] != '"' && s[i] != '\\') putchar(s[i]); putchar('"'); }
#define LIST(id, arr, w) { printf("%s\"%d\":[", first ? "" : ",", id); first = 0; for (int i = 1; i <= arr[0][0]; i++) { if (i > 1) putchar(','); str(arr[i], w); } printf("]"); }
static void page(int p)   /* one menu page: its sub pages, 8 slots each */
{
	printf("[");
	for (int s = 0; s < NUM_SUB_PAGES; s++) {
		const Page *g = &menuPages[p][s];
		const uint8_t t[8] = {g->top1, g->top2, g->top3, g->top4, g->top5, g->top6, g->top7, g->top8};
		const uint16_t b[8] = {g->bot1, g->bot2, g->bot3, g->bot4, g->bot5, g->bot6, g->bot7, g->bot8};
		printf(s ? ",[" : "[");
		for (int i = 0; i < 8; i++) {
			printf(i ? ",[" : "[");
			str(shortNames[valueNames[t[i]].shortName], 3); putchar(',');
			str(catNames[valueNames[t[i]].category], 16); putchar(',');
			str(longNames[valueNames[t[i]].longName], 16);
			printf(",%d,%d]", b[i], b[i] < NUM_PARAMS ? (int)parameter_dtypes[b[i]] : -1);
		}
		printf("]");
	}
	printf("]");
}
int main(void)
{
	printf("{\"pages\":[");
	for (int p = 0; p < 6; p++) { if (p) putchar(','); page(p); }
	printf("],\"fx\":");   /* sub page n = FX type n (off, drive, ring, compressor, delay, reverb) */
	page(FX_MODE_PAGE);
	printf(",\"menus\":{");
	int first = 1;
	LIST(MENU_FILTER, filterTypes, 7) LIST(MENU_WAVEFORM, waveformNames, 3) LIST(MENU_AUDIO_OUT, outputNames, 6)
	LIST(MENU_SYNC_RATES, syncRateNames, 3) LIST(MENU_LFO_WAVES, lfoWaveNames, 3) LIST(MENU_RETRIGGER, retriggerNames, 3)
	LIST(MENU_TRANS, transientNames, 3) LIST(MENU_MIX_FM, mixFmNames, 5)
	LIST(MENU_FX, fxNames, 3) LIST(MENU_DIST, distNames, 3) LIST(MENU_RATIO, ratioNames, 3) LIST(MENU_DELAY, delayNames, 3)
	LIST(MENU_AUDIO_OUT_FX, outputNamesFx, 6)
	printf("},\"names\":[");   /* every value name [short, long]: what mod-target name indexes point at */
	for (unsigned i = 0; i < sizeof valueNames / sizeof valueNames[0]; i++) {
		printf(i ? ",[" : "[");
		str(shortNames[valueNames[i].shortName], 3); putchar(',');
		str(longNames[valueNames[i].longName], 16); putchar(']');
	}
	printf("]}\n");
}
