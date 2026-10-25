# Native build of the LXR sound engine (Erica Synths lxr-desktop-app, GPL-3.0) for kit auditioning on macOS.
# The vendor tree is copied to build/src and patched there; ~/code/vendor stays pristine.
VENDOR ?= $(HOME)/code/vendor/lxr-02/lxr-desktop-app
B := build
SRC := $(B)/src/Core/Src
INC := $(B)/src/Core/Inc
ENGINE := $(shell cd $(VENDOR)/Core/Src 2>/dev/null && ls Soundengine/DSPAudio/*.c Soundengine/DSPAudio/FX/*.c Soundengine/DSPAudio/FX/*/*.c \
            Soundengine/FxBus.c Soundengine/MIDI/*.c Soundengine/Sequencer/*.c | grep -v -e MIDI/Uart.c)
LXR2_OBJS := $(patsubst %.c,$(B)/obj/%.o,$(ENGINE)) $(B)/obj/host/engine.o $(B)/obj/host/stubs.o $(B)/obj/menu/Cc2Text.o
CFLAGS := -std=gnu11 -O2 -w -fvisibility=hidden '-Dsection(x)=unused' -Ishim -I$(INC) -I$(INC)/Soundengine -I$(SRC) -Ihost

all: $(B)/lxr-render $(B)/lxr-play $(B)/engine-lxr2.dylib

$(B)/.patched: $(wildcard patches/*.patch)
	rm -rf $(B)/src && mkdir -p $(B)/src && cp -R $(VENDOR)/Core $(B)/src/
	for p in patches/*.patch; do patch -s -p1 -d $(B)/src < $$p || exit 1; done
	touch $@

$(B)/obj/%.o: $(VENDOR)/Core/Src/%.c $(B)/.patched
	@mkdir -p $(dir $@); $(CC) $(CFLAGS) -c $(SRC)/$*.c -o $@

$(B)/obj/host/%.o: host/%.c $(B)/.patched
	@mkdir -p $(dir $@); $(CC) $(CFLAGS) -c $< -o $@

$(B)/lxr-render: $(LXR2_OBJS) $(B)/obj/host/render.o $(B)/obj/host/kit.o
	$(CC) $^ -o $@ -lm

# Each engine is a plugin that exports only the lxr_* API, so engines with clashing symbols can coexist.
$(B)/engine-lxr2.dylib: $(LXR2_OBJS)
	$(CC) -dynamiclib $^ -o $@ -lm

$(B)/lxr-play: $(B)/obj/host/play.o $(B)/obj/host/kit.o
	$(CC) $^ -o $@ -framework AudioToolbox -framework CoreFoundation

clean:
	rm -rf $(B)
.PHONY: all clean
