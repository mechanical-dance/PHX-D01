/* No-op stand-ins for LXR02Open's front panel, LEDs, menu, sample ROM, trigger jacks, UART and USB. */
#include "stm32f7xx_hal.h"
#include "config.h"
#include "MidiMessages.h"
#include "SampleMemory.h"
#include "ParameterArray.h"

uint8_t parameter_values[NUM_PARAMS];   /* the loaded kit (presetManager.c on hardware) */

GPIO_TypeDef native_gpio[11];
RNG_HandleTypeDef hrng;
volatile uint32_t systick_ticks;
uint8_t buttonHandler_selectedStep, menu_activePage, menu_playedPattern;
float slider_vol[ADC_POT_COUNT] = {1.f, 1.f, 1.f, 1.f, 1.f, 1.f};   /* voice faders all the way up */

uint8_t buttonHandler_getMode(void) { return 0; }
uint8_t buttonHandler_getShift(void) { return 0; }
void buttonHandler_setRunStopState(uint8_t running) { (void)running; }
void led_clearActive_step(void) {}
void led_clearAllBlinkLeds(void) {}
void led_clearSequencerLeds(void) {}
void led_initPerformanceLeds(void) {}
void led_pulseLed(uint8_t ledNr) { (void)ledNr; }
void led_setActive_step(uint8_t stepNr) { (void)stepNr; }
void led_setValue(uint8_t val, uint8_t ledNr) { (void)val; (void)ledNr; }
uint8_t menu_getViewedPattern(void) { return 0; }
void menu_notifyExternalParamChanged(uint16_t paramNr) { (void)paramNr; }
void menu_setNumSamples(uint8_t num) { (void)num; }
void menu_setShownPattern(uint8_t patternNr) { (void)patternNr; }
void preset_morph(uint8_t morph) { (void)morph; }
/* User samples live in RAM instead of flash. SampleInfo.offset is a 32-bit field, so it holds an index into
   sample_pcm rather than an address (patches-lxr1/03 makes the oscillator add the base). */
static const int16_t *sample_pcm;
static SampleInfo sample_info[SAMPLE_MAX_COUNT];
static uint8_t sample_loop[SAMPLE_MAX_COUNT], sample_count;
static uint32_t sample_generation;
const int16_t *lxr1_sample_data(uint32_t offset) { static const int16_t silence[4]; return sample_pcm ? sample_pcm + offset : silence; }
uint32_t sampleMemory_getGeneration(void) { return sample_generation; }
uint8_t sampleMemory_getNumSamples(void) { return sample_count; }
SampleInfo sampleMemory_getSampleInfo(uint8_t index)
{
	if (index < sample_count) return sample_info[index];
	SampleInfo s; memset(&s, 0, sizeof s); return s;
}
uint8_t sampleMemory_isLooped(uint8_t index) { return index < sample_count && sample_loop[index]; }
/* Called on the audio thread between blocks. pcm must stay valid until the next call. */
void lxr1_set_samples(const int16_t *pcm, const uint32_t *offsets, const uint32_t *sizes, const uint8_t *loops, int count)
{
	if (count > (int)SAMPLE_MAX_COUNT) count = SAMPLE_MAX_COUNT;
	sample_pcm = pcm;
	for (int i = 0; i < count; i++) {
		memset(&sample_info[i], 0, sizeof sample_info[i]);
		sample_info[i].offset = offsets[i];
		sample_info[i].size = sizes[i];
		sample_loop[i] = loops[i];
	}
	sample_count = (uint8_t)count;
	if (++sample_generation == 0) sample_generation = 1;
}
uint32_t timebase_tim2Delta(uint32_t newer, uint32_t older) { return newer - older; }
uint32_t timebase_tim2Now(void) { return 0; }
void trigger_allOff() {}
void trigger_clockTick(uint8_t pos) { (void)pos; }
void trigger_reset(uint8_t value) { (void)value; }
void trigger_setGatemode(uint8_t onOff) { (void)onOff; }
void trigger_triggerVoice(uint8_t voiceNr, uint8_t onOff) { (void)voiceNr; (void)onOff; }
uint8_t triggerJacks_clockInputRecently(uint32_t nowUs) { (void)nowUs; return 0; }
void triggerJacks_setClockInputPpq(uint8_t menuValue) { (void)menuValue; }
void triggerJacks_setClockOut1Ppq(uint8_t menuValue) { (void)menuValue; }
void triggerJacks_setClockOut2Ppq(uint8_t menuValue) { (void)menuValue; }
uint8_t triggerJacks_tick(void) { return 0; }
void uart_sendMidi(MidiMsg msg) { (void)msg; }
void usb_sendMidi(MidiMsg msg) { (void)msg; }
