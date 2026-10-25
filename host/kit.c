#include <stdio.h>
#include <string.h>
#include "engine.h"

int lxr_read_kit(const char *path, uint8_t params[LXR_KIT_PARAMS], char name[9])
{
	uint8_t k[8 + LXR_KIT_PARAMS];
	FILE *f = fopen(path, "rb");
	if (!f) return -1;
	size_t n = fread(k, 1, sizeof k, f);
	fclose(f);
	if (n != sizeof k) return -2;
	memcpy(name, k, 8); name[8] = 0;
	for (int i = 7; i >= 0 && (name[i] == ' ' || name[i] == 0); i--) name[i] = 0;
	memcpy(params, k + 8, LXR_KIT_PARAMS);
	return 0;
}
