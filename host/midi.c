#include <CoreAudio/HostTime.h>
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <string.h>
#include "midi.h"

static MIDIClientRef client;
static MIDIPortRef out_port, in_port;
static MIDIEndpointRef virtual_src, out_dest, in_src;
static _Atomic int mode = MIDI_PER_TRACK, base = 0;
static void (*note_cb)(int, int, int);
static char name_buf[128];

/* General MIDI drum notes: kick, low tom, high tom, snare, clap, closed hat, open hat. */
static const uint8_t drum_map[7] = {36, 45, 50, 38, 39, 42, 46};

static const char *endpoint_name(MIDIEndpointRef e)
{
	CFStringRef s = NULL;
	name_buf[0] = 0;
	if (MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr && s) {
		CFStringGetCString(s, name_buf, sizeof name_buf, kCFStringEncodingUTF8);
		CFRelease(s);
	}
	return name_buf;
}

static void read_proc(const MIDIPacketList *list, void *ref, void *src_ref)
{
	(void)ref; (void)src_ref;
	const MIDIPacket *p = &list->packet[0];
	for (UInt32 n = 0; n < list->numPackets; n++, p = MIDIPacketNext(p))
		for (int i = 0; i + 2 < p->length; i++) {
			uint8_t st = p->data[i];
			if ((st & 0xE0) != 0x80) continue;   /* only note on/off: status plus two data bytes */
			int ch = st & 15, note = p->data[i + 1], vel = (st & 0xF0) == 0x90 ? p->data[i + 2] : 0;
			i += 2;
			if (!vel || !note_cb) continue;   /* the LXR ignores note off */
			if (atomic_load(&mode) == MIDI_PER_TRACK) {
				int t = (ch - atomic_load(&base) + 16) % 16;
				if (t < 7) note_cb(t, note, vel);
			} else if (ch == atomic_load(&base)) {
				for (int t = 0; t < 7; t++) if (drum_map[t] == note) note_cb(t, 60, vel);
			}
		}
}

void midi_init(void (*on_note)(int, int, int))
{
	note_cb = on_note;
	if (MIDIClientCreate(CFSTR("LXR Audition"), NULL, NULL, &client)) return;
	MIDIOutputPortCreate(client, CFSTR("out"), &out_port);
	MIDIInputPortCreate(client, CFSTR("in"), read_proc, NULL, &in_port);
	MIDISourceCreate(client, CFSTR("LXR Audition"), &virtual_src);
}

int midi_out_count(void) { return (int)MIDIGetNumberOfDestinations(); }
const char *midi_out_name(int i) { return endpoint_name(MIDIGetDestination(i)); }
void midi_out_select(int i) { out_dest = i >= 0 && i < midi_out_count() ? MIDIGetDestination(i) : 0; }

/* Sources, minus our own virtual one so it can't loop back. */
static MIDIEndpointRef source_at(int i)
{
	for (ItemCount k = 0, n = 0; k < MIDIGetNumberOfSources(); k++) {
		MIDIEndpointRef e = MIDIGetSource(k);
		if (e == virtual_src) continue;
		if ((int)n++ == i) return e;
	}
	return 0;
}
int midi_in_count(void) { return (int)MIDIGetNumberOfSources() - (virtual_src ? 1 : 0); }
const char *midi_in_name(int i) { return endpoint_name(source_at(i)); }
void midi_in_select(int i)
{
	if (in_src) MIDIPortDisconnectSource(in_port, in_src);
	in_src = i >= 0 ? source_at(i) : 0;
	if (in_src) MIDIPortConnectSource(in_port, in_src, NULL);
}

void midi_set_mode(int m, int b) { atomic_store(&mode, m); atomic_store(&base, b & 15); }

void midi_send_note(int track, int note, int vel, uint64_t delay_ns)
{
	if (!client || track < 0 || track > 6) return;
	int m = atomic_load(&mode), b = atomic_load(&base);
	uint8_t ch = m == MIDI_PER_TRACK ? (uint8_t)((b + track) & 15) : (uint8_t)b;
	uint8_t msg[3] = { (uint8_t)((vel ? 0x90 : 0x80) | ch), (uint8_t)(m == MIDI_PER_TRACK ? note : drum_map[track]), (uint8_t)vel };
	Byte buf[64];
	MIDIPacketList *list = (MIDIPacketList *)buf;
	MIDIPacket *p = MIDIPacketListInit(list);
	MIDIPacketListAdd(list, sizeof buf, p, mach_absolute_time() + AudioConvertNanosToHostTime(delay_ns), 3, msg);
	if (out_dest) MIDISend(out_port, out_dest, list);
	if (virtual_src) MIDIReceived(virtual_src, list);
}
