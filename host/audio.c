#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include "audio.h"
#include "midi.h"

typedef struct {
	const char *(*name)(void);
	void (*init)(void);
	void (*load)(const uint8_t *);
	void (*hit)(int, uint8_t);
	void (*note)(int, uint8_t, uint8_t);
	void (*fader)(int, float);
	void (*render)(int16_t[LXR_JACKS][LXR_BLOCK]);
	void (*samples)(const int16_t *, const uint32_t *, const uint32_t *, const uint8_t *, int);   /* optional */
} Engine;

#define MAX_ENGINES 4
#define BUFFERS 3
#define BUFFER_FRAMES 256
static Engine engines[MAX_ENGINES];
static int n_engines;

/* Commands to the audio thread: many producers (UI, MIDI) behind a lock, one consumer that never locks. */
enum { CMD_HIT, CMD_LOAD, CMD_ENGINE, CMD_SOLO, CMD_FADER, CMD_HW, CMD_PATTERN, CMD_TRANSPORT, CMD_TEMPO, CMD_SAMPLES };
typedef struct {
	int type, arg, vel, note, from_midi;
	float value, value2;
	const LxaSamples *samples;
	union { uint8_t params[LXR_KIT_PARAMS]; LxaStep steps[LXA_TRACKS][LXA_MAX_STEPS]; } data;
} Cmd;
#define RING 128
static Cmd ring[RING];
static _Atomic int ring_w, ring_r;
static os_unfair_lock push_lock = OS_UNFAIR_LOCK_INIT;

/* Audio thread only. */
static int active, solo, hw;
static float fader_gain[6] = {1, 1, 1, 1, 1, 1}, master = 1;
static LxaStep pattern[LXA_TRACKS][LXA_MAX_STEPS];
static int pat_len = 16, playing, step;
static double bpm = 120, swing, grid_at, now;   /* times in frames */
static int note_off_track[LXA_TRACKS];
static double note_off_at[LXA_TRACKS];

static _Atomic int playhead = -1;
static _Atomic uint32_t hits[LXA_TRACKS];
static AudioQueueRef queue;
static int out_channels = 2;   /* 2 = stereo mix, 4 = one channel per jack; changed only while the queue is down */

static void push(Cmd *c)
{
	os_unfair_lock_lock(&push_lock);
	int w = atomic_load(&ring_w);
	if ((w + 1) % RING != atomic_load(&ring_r)) {   /* full: drop */
		ring[w] = *c;
		atomic_store(&ring_w, (w + 1) % RING);
	}
	os_unfair_lock_unlock(&push_lock);
}

/* The module has no faders: its engine always sees them fully up. */
static void apply_faders(void)
{
	for (int e = 0; e < n_engines; e++)
		for (int v = 0; v < 6; v++) engines[e].fader(v, hw == LXA_MODULE ? 1.f : fader_gain[v]);
}

/* MIDI is timestamped to leave when the sound it belongs to reaches the speaker: the queued buffers ahead of it. */
static uint64_t midi_delay_ns(double at_frame)
{
	double frames = BUFFERS * BUFFER_FRAMES + (at_frame - now);
	return frames > 0 ? (uint64_t)(frames * 1e9 / LXR_RATE) : 0;
}

static void play_note(int t, int note, int vel, double at_frame, int send_midi)
{
	engines[active].note(t, (uint8_t)note, (uint8_t)vel);
	atomic_fetch_add(&hits[t], 1);
	if (!send_midi) return;
	midi_send_note(t, note, vel, midi_delay_ns(at_frame));
	note_off_track[t] = note;
	note_off_at[t] = at_frame + LXR_RATE * 60.0 / bpm / 8;   /* half a step: the LXR ignores note off, DAWs don't */
}

static double step_frames(void) { return LXR_RATE * 60.0 / bpm / 4; }

/* Fire every step that falls inside this block. Odd steps are pushed late by the swing amount. */
static void sequence(double block_end)
{
	for (int t = 0; t < LXA_TRACKS; t++)
		if (note_off_at[t] > 0 && note_off_at[t] < block_end) {
			midi_send_note(t, note_off_track[t], 0, midi_delay_ns(note_off_at[t]));
			note_off_at[t] = 0;
		}
	if (!playing) return;
	for (;;) {
		double at = grid_at + ((step & 1) ? swing * step_frames() : 0);
		if (at >= block_end) break;
		int s = step % pat_len;
		for (int t = 0; t < LXA_TRACKS; t++)
			if (pattern[t][s].vel) play_note(t, pattern[t][s].note, pattern[t][s].vel, at, 1);
		atomic_store(&playhead, s);
		step = s + 1;
		grid_at += step_frames();
	}
}

static void handle(Cmd *c)
{
	switch (c->type) {
	case CMD_HIT: play_note(c->arg, c->note, c->vel, now, !c->from_midi); break;
	case CMD_LOAD: for (int e = 0; e < n_engines; e++) engines[e].load(c->data.params); break;
	case CMD_ENGINE: active = c->arg; break;
	case CMD_SOLO: solo = c->arg; break;
	case CMD_HW: hw = c->arg; apply_faders(); break;
	case CMD_FADER:
		if (c->arg == 6) master = c->value;
		else { fader_gain[c->arg] = c->value; apply_faders(); }
		break;
	case CMD_PATTERN: memcpy(pattern, c->data.steps, sizeof pattern); pat_len = c->arg; break;
	case CMD_TRANSPORT:
		playing = c->arg;
		if (playing) { step = 0; grid_at = now; }
		else atomic_store(&playhead, -1);
		break;
	case CMD_TEMPO: bpm = c->value; swing = c->value2; break;
	case CMD_SAMPLES:
		for (int e = 0; e < n_engines; e++)
			if (engines[e].samples) engines[e].samples(c->samples->pcm, c->samples->offsets, c->samples->sizes, c->samples->loops, c->samples->count);
		break;
	}
}

static void audio_cb(void *ud, AudioQueueRef q, AudioQueueBufferRef buf)
{
	(void)ud;
	int r;
	while ((r = atomic_load(&ring_r)) != atomic_load(&ring_w)) {
		handle(&ring[r]);
		atomic_store(&ring_r, (r + 1) % RING);
	}
	int16_t *out = buf->mAudioData, jack[LXR_JACKS][LXR_BLOCK];
	const int nch = out_channels, frame_bytes = 2 * nch;
	int blocks = buf->mAudioDataBytesCapacity / (LXR_BLOCK * frame_bytes);
	float gain = hw == LXA_MODULE ? 1.f : master;
	for (int b = 0; b < blocks; b++) {
		sequence(now + LXR_BLOCK);
		engines[active].render(jack);
		for (int i = 0; i < LXR_BLOCK; i++)
			for (int ch = 0; ch < nch; ch++) {
				int v = nch == 4 ? (int)(gain * jack[ch][i])   /* each jack on its own channel */
				      : (int)(gain * (solo ? jack[solo - 1][i] : jack[ch][i] + jack[2 + ch][i]));
				out[(b * LXR_BLOCK + i) * nch + ch] = v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v;
			}
		now += LXR_BLOCK;
	}
	buf->mAudioDataByteSize = blocks * LXR_BLOCK * frame_bytes;
	AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static int load_engine(const char *path)
{
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!h) return 0;
	Engine e = { dlsym(h, "lxr_engine_name"), dlsym(h, "lxr_init"), dlsym(h, "lxr_load_params"), dlsym(h, "lxr_hit"),
	             dlsym(h, "lxr_note"), dlsym(h, "lxr_set_fader"), dlsym(h, "lxr_render"), dlsym(h, "lxr_set_samples") };
	if (!e.name || !e.init || !e.load || !e.hit || !e.note || !e.fader || !e.render) { fprintf(stderr, "%s: missing symbols\n", path); return 0; }
	e.init();
	engines[n_engines++] = e;
	return 1;
}

/* ---------- output devices ---------- */
#define MAX_DEVICES 32
static AudioDeviceID devices[MAX_DEVICES];
static char device_names[MAX_DEVICES][128];
static int device_channels[MAX_DEVICES];
static int n_devices;

static int output_channel_count(AudioDeviceID d)
{
	AudioObjectPropertyAddress a = { kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &size) || !size) return 0;
	AudioBufferList *l = malloc(size);
	int n = 0;
	if (!AudioObjectGetPropertyData(d, &a, 0, NULL, &size, l))
		for (UInt32 i = 0; i < l->mNumberBuffers; i++) n += (int)l->mBuffers[i].mNumberChannels;
	free(l);
	return n;
}

static void scan_devices(void)
{
	AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	AudioDeviceID all[MAX_DEVICES];
	UInt32 size = sizeof all;
	n_devices = 0;
	if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, all)) return;
	for (UInt32 i = 0; i < size / sizeof(AudioDeviceID) && n_devices < MAX_DEVICES; i++) {
		AudioObjectPropertyAddress s = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
		UInt32 ssize = 0;
		if (AudioObjectGetPropertyDataSize(all[i], &s, 0, NULL, &ssize) || ssize == 0) continue;   /* no outputs */
		CFStringRef name = NULL;
		UInt32 nsize = sizeof name;
		AudioObjectPropertyAddress n = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
		if (AudioObjectGetPropertyData(all[i], &n, 0, NULL, &nsize, &name) || !name) continue;
		CFStringGetCString(name, device_names[n_devices], sizeof device_names[0], kCFStringEncodingUTF8);
		CFRelease(name);
		device_channels[n_devices] = output_channel_count(all[i]);
		devices[n_devices++] = all[i];
	}
}

int lxa_output_count(void) { scan_devices(); return n_devices; }
const char *lxa_output_name(int i) { return i >= 0 && i < n_devices ? device_names[i] : ""; }
int lxa_output_channels(int i) { return i >= 0 && i < n_devices ? device_channels[i] : 0; }

static AudioDeviceID default_output(void)
{
	AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	AudioDeviceID d = 0;
	UInt32 size = sizeof d;
	AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &d);
	return d;
}

/* device -1 = system default. channels 2 or 4, starting at device channel first (0-based). */
static int open_queue(int device, int channels, int first)
{
	AudioDeviceID dev = device >= 0 && device < n_devices ? devices[device] : default_output();
	int have = output_channel_count(dev);
	if (have < first + channels) { first = 0; if (have < channels) channels = 2; }
	out_channels = channels;
	AudioStreamBasicDescription fmt = { .mSampleRate = LXR_RATE, .mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
		.mBytesPerPacket = 2 * channels, .mFramesPerPacket = 1, .mBytesPerFrame = 2 * channels,
		.mChannelsPerFrame = channels, .mBitsPerChannel = 16 };
	if (AudioQueueNewOutput(&fmt, audio_cb, NULL, NULL, NULL, 0, &queue)) return 0;
	CFStringRef uid = NULL;
	UInt32 size = sizeof uid;
	AudioObjectPropertyAddress a = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &uid) == noErr && uid) {
		AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof uid);
		AudioQueueChannelAssignment map[4];
		for (int c = 0; c < channels; c++) map[c] = (AudioQueueChannelAssignment){ uid, (UInt32)(first + c + 1) };   /* 1-based */
		AudioQueueSetProperty(queue, kAudioQueueProperty_ChannelAssignments, map, sizeof map[0] * channels);
		CFRelease(uid);
	}
	for (int i = 0; i < BUFFERS; i++) {
		AudioQueueBufferRef b;
		AudioQueueAllocateBuffer(queue, BUFFER_FRAMES * 2 * channels, &b);
		audio_cb(NULL, queue, b);
	}
	if (AudioQueueStart(queue, NULL)) { AudioQueueDispose(queue, true); queue = NULL; return 0; }
	return 1;
}

int lxa_set_output(int i, int channels, int first)
{
	if (queue) { AudioQueueStop(queue, true); AudioQueueDispose(queue, true); queue = NULL; }
	return open_queue(i, channels == 4 ? 4 : 2, first < 0 ? 0 : first) || open_queue(-1, 2, 0);
}

/* ---------- API ---------- */
/* Notes from MIDI in play but aren't echoed to MIDI out, so routing out back to in can't loop. */
static void midi_note_in(int track, int note, int vel)
{
	if (track < 0 || track >= LXA_TRACKS) return;
	Cmd c = { .type = CMD_HIT, .arg = track, .note = note, .vel = vel, .from_midi = 1 };
	push(&c);
}

int lxa_start(const char *engine_dir)
{
	static const char *names[] = {"engine-lxr2.dylib", "engine-lxr1.dylib"};
	char path[1100];
	for (int i = 0; i < 2; i++) { snprintf(path, sizeof path, "%s/%s", engine_dir, names[i]); load_engine(path); }
	if (!n_engines) return 0;
	midi_init(midi_note_in);
	scan_devices();
	if (!open_queue(-1, 2, 0)) return 0;
	return n_engines;
}

void lxa_stop(void) { if (queue) AudioQueueStop(queue, true); }
int lxa_engine_count(void) { return n_engines; }
const char *lxa_engine_name(int engine) { return engine >= 0 && engine < n_engines ? engines[engine].name() : ""; }

void lxa_load(const uint8_t params[LXR_KIT_PARAMS])
{
	Cmd c = { .type = CMD_LOAD };
	memcpy(c.data.params, params, LXR_KIT_PARAMS);
	push(&c);
}

/* The set must stay alive while any engine uses it; the app keeps every set it sends (they are small and rare). */
void lxa_samples(const LxaSamples *set) { Cmd c = { .type = CMD_SAMPLES, .samples = set }; push(&c); }
int lxa_engine_has_samples(int engine) { return engine >= 0 && engine < n_engines && engines[engine].samples != NULL; }

static void simple(int type, int arg) { Cmd c = { .type = type, .arg = arg }; push(&c); }
void lxa_engine(int engine) { if (engine >= 0 && engine < n_engines) simple(CMD_ENGINE, engine); }
void lxa_hardware(int h) { simple(CMD_HW, h); }
void lxa_solo(int jack) { simple(CMD_SOLO, jack); }
void lxa_transport(int on) { simple(CMD_TRANSPORT, on); }

static int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }
void lxa_note(int trigger, int note, int velocity)
{
	if (trigger < 0 || trigger >= LXA_TRACKS) return;
	Cmd c = { .type = CMD_HIT, .arg = trigger, .note = clamp(note, 0, 127), .vel = clamp(velocity, 1, 127) };
	push(&c);
}
void lxa_hit(int trigger, int velocity) { lxa_note(trigger, 60, velocity); }

/* The LXR-02 squares the fader position and treats the bottom 1% as off (adcPots.c). */
void lxa_fader(int fader, float position)
{
	if (fader < 0 || fader > 6) return;
	Cmd c = { .type = CMD_FADER, .arg = fader, .value = position < 0.01f ? 0.f : position > 1.f ? 1.f : position * position };
	push(&c);
}

void lxa_pattern(const LxaStep steps[LXA_TRACKS][LXA_MAX_STEPS], int length)
{
	Cmd c = { .type = CMD_PATTERN, .arg = clamp(length, 1, LXA_MAX_STEPS) };
	memcpy(c.data.steps, steps, sizeof c.data.steps);
	push(&c);
}

void lxa_tempo(float b, float sw)
{
	Cmd c = { .type = CMD_TEMPO, .value = b < 20 ? 20 : b > 300 ? 300 : b, .value2 = sw < 0 ? 0 : sw > 0.75f ? 0.75f : sw };
	push(&c);
}

int lxa_playhead(void) { return atomic_load(&playhead); }
void lxa_hit_counts(uint32_t counts[LXA_TRACKS]) { for (int t = 0; t < LXA_TRACKS; t++) counts[t] = atomic_load(&hits[t]); }
