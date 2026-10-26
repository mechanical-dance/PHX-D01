# Native build of the LXR sound engine (Erica Synths lxr-desktop-app, GPL-3.0) for kit auditioning on macOS.
# The vendor tree is copied to build/src and patched there; ~/code/vendor stays pristine.
VENDOR ?= $(HOME)/code/vendor/lxr-02/lxr-desktop-app
B := build
SRC := $(B)/src/Core/Src
INC := $(B)/src/Core/Inc
ENGINE := $(shell cd $(VENDOR)/Core/Src 2>/dev/null && ls Soundengine/DSPAudio/*.c Soundengine/DSPAudio/FX/*.c Soundengine/DSPAudio/FX/*/*.c \
            Soundengine/FxBus.c Soundengine/MIDI/*.c Soundengine/Sequencer/*.c | grep -v -e MIDI/Uart.c)
LXR2_OBJS := $(patsubst %.c,$(B)/obj/%.o,$(ENGINE)) $(B)/obj/host/engine.o $(B)/obj/host/stubs.o $(B)/obj/menu/Cc2Text.o $(B)/obj/host/kit.o
CFLAGS := -std=gnu11 -O2 -w -fvisibility=hidden '-Dsection(x)=unused' -Ishim -I$(INC) -I$(INC)/Soundengine -I$(SRC) -Ihost

all: $(B)/lxr-render $(B)/lxr-play $(B)/engine-lxr2.dylib $(B)/engine-lxr1.dylib $(B)/PHX-D01.app

$(B)/.patched: $(wildcard patches/*.patch)
	rm -rf $(B)/src && mkdir -p $(B)/src && cp -R $(VENDOR)/Core $(B)/src/
	for p in patches/*.patch; do patch -s -p1 -d $(B)/src < $$p || exit 1; done
	touch $@

$(B)/obj/%.o: $(VENDOR)/Core/Src/%.c $(B)/.patched
	@mkdir -p $(dir $@); $(CC) $(CFLAGS) -c $(SRC)/$*.c -o $@

$(B)/obj/host/%.o: host/%.c host/engine.h host/audio.h host/midi.h host/module_targets.h $(B)/.patched
	@mkdir -p $(dir $@); $(CC) $(CFLAGS) -c $< -o $@

$(B)/lxr-render: $(LXR2_OBJS) $(B)/obj/host/render.o
	$(CC) $^ -o $@ -lm

# Each engine is a plugin that exports only the lxr_* API, so engines with clashing symbols can coexist.
$(B)/engine-lxr2.dylib: $(LXR2_OBJS)
	$(CC) -dynamiclib $^ -o $@ -lm

$(B)/lxr-play: $(B)/obj/host/play.o $(B)/obj/host/audio.o $(B)/obj/host/midi.o $(B)/obj/host/kit.o
	$(CC) $^ -o $@ -framework AudioToolbox -framework CoreAudio -framework CoreMIDI -framework CoreFoundation

# --- LXR-1 engine: Sonic Potions 0.37 via LXR02Open (non-commercial licence; personal use) ---
VENDOR1 ?= $(HOME)/code/vendor/lxr-02/LXR02Open
B1 := $(B)/lxr1
ENGINE1 := $(shell cd $(VENDOR1)/Core 2>/dev/null && ls DSPAudio/*.c MIDI/*.c Sequencer/*.c Preset/ParameterArray.c Menu/Cc2Text.c | grep -v -e MIDI/Uart.c -e DSPAudio/random.c)
LXR1_OBJS := $(patsubst %.c,$(B1)/obj/%.o,$(ENGINE1)) $(B1)/obj/host/engine1.o $(B1)/obj/host/stubs1.o $(B1)/obj/host/random1.o
INC1 = -Ishim1 -Ishim -I$(B) -Ihost -I$(VENDOR1) $(addprefix -I,$(shell find $(VENDOR1)/Core -type d -not -path "*/knowledge_files/*"))
CFLAGS1 = -std=gnu11 -O2 -w -fvisibility=hidden '-Dsection(x)=unused' $(INC1)

$(B1)/.patched: $(wildcard patches-lxr1/*.patch)
	rm -rf $(B1)/src && mkdir -p $(B1)/src && cp -R $(VENDOR1)/Core $(VENDOR1)/config.h $(B1)/src/
	for p in patches-lxr1/*.patch; do patch -s -p1 -d $(B1)/src < $$p || exit 1; done
	touch $@

$(B)/lxr1_map.h: gen_map.py
	python3 gen_map.py $(VENDOR) $(VENDOR1) $@

$(B1)/obj/host/%.o: host/%.c $(B1)/.patched $(B)/lxr1_map.h
	@mkdir -p $(dir $@); $(CC) $(CFLAGS1) -c $< -o $@

$(B1)/obj/%.o: $(VENDOR1)/Core/%.c $(B1)/.patched
	@mkdir -p $(dir $@); $(CC) $(CFLAGS1) -c $(B1)/src/Core/$*.c -o $@

$(B)/engine-lxr1.dylib: $(LXR1_OBJS)
	$(CC) -dynamiclib $^ -o $@ -lm

clean:
	rm -rf $(B)
.PHONY: all clean

# The app: a WKWebView front panel (app/web) on the lxa runtime, with the engine plugins inside the bundle.
APP := $(B)/PHX-D01.app
app: $(APP)
# app/icon.svg is the source; AppIcon.icns is built from it (render at 1024, sips, iconutil).
$(APP): app/AppIcon.icns $(wildcard app/*.swift) app/bridge.h host/audio.h host/midi.h app/Info.plist $(wildcard app/web/*) $(wildcard factory/Erica-factory/*) $(B)/obj/host/audio.o $(B)/obj/host/midi.o $(B)/obj/host/kit.o $(B)/engine-lxr2.dylib $(B)/engine-lxr1.dylib
	rm -rf $@ && mkdir -p $@/Contents/MacOS $@/Contents/Resources
	swiftc -O -import-objc-header app/bridge.h app/*.swift $(B)/obj/host/audio.o $(B)/obj/host/midi.o $(B)/obj/host/kit.o \
		-framework AudioToolbox -framework CoreAudio -framework CoreMIDI -framework WebKit -o $@/Contents/MacOS/lxr-audition
	cp $(B)/engine-lxr2.dylib $(B)/engine-lxr1.dylib $@/Contents/MacOS/
	cp -R app/web $@/Contents/Resources/
	cp app/AppIcon.icns $@/Contents/Resources/
	cp -R factory/Erica-factory factory/INIT.SND $@/Contents/Resources/
	cp app/Info.plist $@/Contents/
	codesign --force --deep -s - $@
