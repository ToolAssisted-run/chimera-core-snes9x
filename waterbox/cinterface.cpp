/* cinterface.cpp - Snes9x behind the chimera guest ABI.
 *
 * Descended from the author's BizHawk bizhawk/cinterface.cpp (the
 * TASEmulators/snes9x fork), reshaped for chimera's generic waterbox
 * adapter: settings arrive through the mounted "settings" JSON, the
 * cartridge arrives as a mounted file fed to Memory.LoadROMMem, and lag
 * detection is the InputWasRead export over upstream's own
 * SNES_JOY_READ_CALLBACKS hook - no host callbacks anywhere.
 *
 * The machine constants (rates, HDMA timing hack, sprite tiles per line,
 * BlockInvalidVRAMAccess, UpAndDown allowed) are the author's biz_init
 * block, verbatim. So are the S9xMapButton names, the port-device walk,
 * the RGB565 blit and the memory-domain table.
 *
 * This file compiles IDENTICALLY for the guest (miniBox emulibc) and for
 * the native reference build (native-shim/emulibc.h), which is what makes
 * the equivalence gate a real proof.
 */
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "snes9x.h"
#include "memmap.h"
#include "srtc.h"
#include "apu/apu.h"
#include "gfx.h"
#include "snapshot.h"
#include "controls.h"
#include "cheats.h"
#include "movie.h"
#include "display.h"
#include "conffile.h"

static char g_loadError[512];
static int g_inited;
static int g_inputRead;

/* ---- the wire format: waterbox.config "input.buttons" order ----
 * 0 Power (hard reset), 1 Reset (soft), then P1..P8 x
 * {Up,Down,Left,Right,Select,Start,Y,B,X,A,L,R} (quickerSnes9x's .sol
 * column order). Which pads are live follows the leftPort/rightPort
 * settings exactly like the author's port-device walk. */
#define BTN_PADS 2
#define BTN_PER_PAD 12
#define BTN_COUNT (BTN_PADS + 8 * BTN_PER_PAD)
static uint8_t g_buttons[BTN_COUNT];

/* wire column -> the fork's joypad button id (B=0,Y,Select,Start,Up,Down,
 * Left,Right,A,X,L,R) */
static const int kColToBtn[BTN_PER_PAD] = { 4, 5, 6, 7, 2, 3, 1, 0, 9, 8, 10, 11 };

#define DEV_NONE 0
#define DEV_JOYPAD 1
#define DEV_MULTITAP 2
#define DEV_MOUSE 3
#define DEV_SUPERSCOPE 4
#define DEV_JUSTIFIER 5
static unsigned snes_devices[2];

/* ---- video: RGB565 -> opaque BGRA, the author's blit verbatim ---- */
static uint32_t g_videoOut[MAX_SNES_WIDTH * MAX_SNES_HEIGHT];
static int g_vwidth = SNES_WIDTH, g_vheight = SNES_HEIGHT;
static int actual_width = SNES_WIDTH, actual_height = SNES_HEIGHT;
static bool use_overscan = false;

#define MAX_SAMPLES 4096
static int16_t g_soundbuffer[MAX_SAMPLES * 2];
static int g_nsamples;

/* ---- controller mapping (the author's map_buttons, verbatim) ---- */
#define MAP_BUTTON(id, name) S9xMapButton((id), S9xGetCommandT((name)), false)
#define MAKE_BUTTON(pad, btn) (((pad) << 4) | (btn))

#define PAD_1 1
#define PAD_2 2
#define PAD_3 3
#define PAD_4 4
#define PAD_5 5

#define BTN_FIRST 0
#define BTN_LAST 11
#define BTN_POINTER (BTN_LAST + 1)
#define BTN_POINTER2 (BTN_POINTER + 1)

static void map_buttons()
{
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 8), "Joypad1 A");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 0), "Joypad1 B");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 9), "Joypad1 X");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 1), "Joypad1 Y");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 2), "{Joypad1 Select,Mouse1 L}");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 3), "{Joypad1 Start,Mouse1 R}");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 10), "Joypad1 L");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 11), "Joypad1 R");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 6), "Joypad1 Left");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 7), "Joypad1 Right");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 4), "Joypad1 Up");
	MAP_BUTTON(MAKE_BUTTON(PAD_1, 5), "Joypad1 Down");
	S9xMapPointer((BTN_POINTER), S9xGetCommandT("Pointer Mouse1+Superscope+Justifier1"), false);
	S9xMapPointer((BTN_POINTER2), S9xGetCommandT("Pointer Mouse2+Justifier2"), false);

	MAP_BUTTON(MAKE_BUTTON(PAD_2, 8), "Joypad2 A");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 0), "Joypad2 B");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 9), "Joypad2 X");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 1), "Joypad2 Y");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 2), "{Joypad2 Select,Mouse2 L,Superscope Fire,Justifier1 Trigger}");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 3), "{Joypad2 Start,Mouse2 R,Superscope Cursor,Justifier1 Start}");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 10), "Joypad2 L");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 11), "Joypad2 R");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 6), "{Joypad2 Left,Superscope AimOffscreen}");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 7), "Joypad2 Right");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 4), "{Joypad2 Up,Superscope ToggleTurbo,Justifier1 AimOffscreen}");
	MAP_BUTTON(MAKE_BUTTON(PAD_2, 5), "{Joypad2 Down,Superscope Pause}");

	MAP_BUTTON(MAKE_BUTTON(PAD_3, 8), "Joypad3 A");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 0), "Joypad3 B");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 9), "Joypad3 X");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 1), "Joypad3 Y");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 2), "{Joypad3 Select,Justifier2 Trigger}");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 3), "{Joypad3 Start,Justifier2 Start}");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 10), "Joypad3 L");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 11), "Joypad3 R");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 6), "Joypad3 Left");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 7), "Joypad3 Right");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 4), "{Joypad3 Up,Justifier2 AimOffscreen}");
	MAP_BUTTON(MAKE_BUTTON(PAD_3, 5), "Joypad3 Down");

	MAP_BUTTON(MAKE_BUTTON(PAD_4, 8), "Joypad4 A");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 0), "Joypad4 B");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 9), "Joypad4 X");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 1), "Joypad4 Y");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 2), "Joypad4 Select");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 3), "Joypad4 Start");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 10), "Joypad4 L");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 11), "Joypad4 R");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 6), "Joypad4 Left");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 7), "Joypad4 Right");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 4), "Joypad4 Up");
	MAP_BUTTON(MAKE_BUTTON(PAD_4, 5), "Joypad4 Down");

	MAP_BUTTON(MAKE_BUTTON(PAD_5, 8), "Joypad5 A");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 0), "Joypad5 B");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 9), "Joypad5 X");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 1), "Joypad5 Y");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 2), "Joypad5 Select");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 3), "Joypad5 Start");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 10), "Joypad5 L");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 11), "Joypad5 R");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 6), "Joypad5 Left");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 7), "Joypad5 Right");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 4), "Joypad5 Up");
	MAP_BUTTON(MAKE_BUTTON(PAD_5, 5), "Joypad5 Down");
}

static void set_port_device(unsigned port, unsigned device)
{
	int offset = snes_devices[0] == DEV_MULTITAP ? 4 : 1;
	switch (device)
	{
	case DEV_NONE:
		S9xSetController(port, CTL_NONE, 0, 0, 0, 0);
		break;
	case DEV_JOYPAD:
		S9xSetController(port, CTL_JOYPAD, port * offset, 0, 0, 0);
		break;
	case DEV_MULTITAP:
		S9xSetController(port, CTL_MP5, port * offset, port * offset + 1,
			port * offset + 2, port * offset + 3);
		break;
	case DEV_MOUSE:
		S9xSetController(port, CTL_MOUSE, 0, 0, 0, 0);
		break;
	case DEV_SUPERSCOPE:
		S9xSetController(port, CTL_SUPERSCOPE, 0, 0, 0, 0);
		break;
	case DEV_JUSTIFIER:
		S9xSetController(port, CTL_JUSTIFIER, 0, 0, 0, 0);
		break;
	default:
		break;
	}
	snes_devices[port] = device;
}

/* the wire's pads -> S9xReportButton, following the author's report_buttons
 * walk: the wire player index is the fork's input port index */
static void report_buttons()
{
	int offset = snes_devices[0] == DEV_MULTITAP ? 4 : 1;
	for (int port = 0; port <= 1; port++)
	{
		switch (snes_devices[port])
		{
		case DEV_JOYPAD:
			for (int col = 0; col < BTN_PER_PAD; col++)
				S9xReportButton(MAKE_BUTTON(port * offset + 1, kColToBtn[col]),
					g_buttons[BTN_PADS + (port * offset) * BTN_PER_PAD + col]);
			break;
		case DEV_MULTITAP:
			for (int j = 0; j < 4; j++)
				for (int col = 0; col < BTN_PER_PAD; col++)
					S9xReportButton(MAKE_BUTTON(port * offset + j + 1, kColToBtn[col]),
						g_buttons[BTN_PADS + (port * offset + j) * BTN_PER_PAD + col]);
			break;
		default:
			/* mouse/scope/justifier ride the exotic-input milestone */
			break;
		}
	}
}

static int port_device(const char *name, int isRight)
{
	char buf[32];
	strncpy(buf, "joypad", sizeof buf - 1);
	buf[sizeof buf - 1] = 0;
	wbx_setting_str(name, buf, sizeof buf);
	if (strcmp(buf, "none") == 0) return DEV_NONE;
	if (strcmp(buf, "joypad") == 0) return DEV_JOYPAD;
	if (strcmp(buf, "multitap") == 0) return DEV_MULTITAP;
	if (isRight)
	{
		if (strcmp(buf, "mouse") == 0) return DEV_MOUSE;
		if (strcmp(buf, "superScope") == 0) return DEV_SUPERSCOPE;
		if (strcmp(buf, "justifier") == 0) return DEV_JUSTIFIER;
	}
	fprintf(stderr, "chimera-snes9x: unknown %s '%s', using joypad\n", name, buf);
	return DEV_JOYPAD;
}

extern "C" {

ECL_EXPORT const char *GetLoadError(void)
{
	return g_loadError;
}

ECL_EXPORT int Init(void)
{
	g_loadError[0] = 0;

	/* the author's biz_init machine block, verbatim */
	memset(&Settings, 0, sizeof(Settings));
	Settings.MouseMaster = TRUE;
	Settings.SuperScopeMaster = TRUE;
	Settings.JustifierMaster = TRUE;
	Settings.MultiPlayer5Master = TRUE;
	Settings.FrameTimePAL = 20000;
	Settings.FrameTimeNTSC = 16667;
	Settings.SixteenBitSound = TRUE;
	Settings.Stereo = TRUE;
	Settings.SoundPlaybackRate = 44100;
	Settings.SoundInputRate = 32040;
	Settings.SoundSync = TRUE;
	Settings.InterpolationMethod = 2;
	Settings.Transparency = TRUE;
	Settings.AutoDisplayMessages = TRUE;
	Settings.InitialInfoStringTimeout = 120;
	Settings.SuperFXClockMultiplier = 100;
	Settings.HDMATimingHack = 100;
	Settings.MaxSpriteTilesPerLine = 34;
	Settings.BlockInvalidVRAMAccessMaster = TRUE;
	Settings.WrongMovieStateProtection = TRUE;
	Settings.DumpStreamsMaxFrames = -1;
	Settings.StretchScreenshots = 0;
	Settings.SnapshotScreenshots = FALSE;
	Settings.CartAName[0] = 0;
	Settings.CartBName[0] = 0;
	Settings.AutoSaveDelay = 1;
	Settings.DontSaveOopsSnapshot = TRUE;
	Settings.UpAndDown = TRUE;

	CPU.Flags = 0;

	if (!Memory.Init() || !S9xInitAPU())
	{
		snprintf(g_loadError, sizeof g_loadError, "failed to init Memory or APU");
		return 0;
	}

	S9xInitSound(21);
	S9xSetSoundMute(FALSE);
	S9xGraphicsInit();

	int left = port_device("leftPort", 0);
	int right = port_device("rightPort", 1);
	set_port_device(0, left);
	set_port_device(1, right);

	S9xUnmapAllControls();
	map_buttons();

	/* the cartridge: the project slot's file, else the plain rom mount */
	char name[512];
	const char *file = NULL;
	if (wbx_slot_count("cart") > 0 && wbx_slot_name("cart", 0, name, sizeof name) != NULL)
		file = name;
	else
	{
		snprintf(name, sizeof name, "rom");
		file = name;
	}

	FILE *f = fopen(file, "rb");
	if (f == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "no cartridge file is mounted");
		return 0;
	}
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	static uint8_t *romBuf;
	romBuf = new uint8_t[size > 0 ? (size_t)size : 1];
	if (fread(romBuf, 1, (size_t)size, f) != (size_t)size)
	{
		fclose(f);
		snprintf(g_loadError, sizeof g_loadError, "could not read '%s'", file);
		return 0;
	}
	fclose(f);

	if (!Memory.LoadROMMem(romBuf, (uint32)size, file))
	{
		snprintf(g_loadError, sizeof g_loadError, "Snes9x rejected '%s'", file);
		return 0;
	}
	delete[] romBuf;
	romBuf = NULL;

	S9xGraphicsDeinit();
	S9xGraphicsInit();

	g_inited = 1;
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < BTN_COUNT)
		g_buttons[index] = state != 0;
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed; /* > 64 buttons: input rides the SetButton wide channel */
	if (!g_inited)
		return;

	/* Power = hard reset, Reset = the console's reset button (held levels,
	 * exactly as the author's BizHawk core) */
	if (g_buttons[0])
		S9xReset();
	else if (g_buttons[1])
		S9xSoftReset();

	report_buttons();

	g_inputRead = 0;
	S9xMainLoop();
	S9xLandSamples();

	size_t avail = S9xGetSampleCount();
	if (avail > MAX_SAMPLES * 2)
		avail = MAX_SAMPLES * 2;
	S9xMixSamples((uint8 *)g_soundbuffer, avail);
	g_nsamples = (int)(avail / 2);

	/* RGB565 -> opaque BGRA (the author's blit, channel math verbatim) */
	{
		const uint16_t *src = GFX.Screen;
		uint32_t *dst = g_videoOut;
		const int vinc = GFX.Pitch / sizeof(uint16_t) - actual_width;
		for (int j = 0; j < actual_height; j++)
		{
			for (int i = 0; i < actual_width; i++)
			{
				uint16_t c = *src++;
				uint32_t b = (c << 3 & 0xf8) | (c >> 2 & 7);
				uint32_t g = (c >> 3 & 0xfa) | (c >> 9 & 3);
				uint32_t r = (c >> 8 & 0xf8) | (c >> 13 & 7);
				*dst++ = b | (g << 8) | (r << 16) | 0xff000000u;
			}
			src += vinc;
		}
		g_vwidth = actual_width;
		g_vheight = actual_height;
	}
}

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_videoOut; }
ECL_EXPORT int GetVideoWidth(void) { return g_vwidth; }
ECL_EXPORT int GetVideoHeight(void) { return g_vheight; }

ECL_EXPORT int16_t *GetAudio(void) { return g_soundbuffer; }
ECL_EXPORT int GetAudioSampleCount(void) { return g_nsamples; }

ECL_EXPORT int GetVsyncNumerator(void)
{
	return Settings.PAL ? 21281370 : 21477272;
}
ECL_EXPORT int GetVsyncDenominator(void)
{
	return Settings.PAL ? 425568 : 357366;
}

ECL_EXPORT int InputWasRead(void)
{
	return g_inputRead;
}

/* ---- memory domains: the author's GetMemoryAreas table, dense ---- */
static const char *memdom(int which, void **area, int64_t *size, int *writable)
{
	*writable = 1;
	switch (which)
	{
	case 0:
		*area = Memory.RAM;
		*size = 128 * 1024;
		return "WRAM";
	case 1:
	{
		unsigned sz = Memory.SRAMSize ? Memory.SRAMMask + 1 : 0;
		if (sz > Memory.SRAM_SIZE) sz = Memory.SRAM_SIZE;
		if (sz == 0) return NULL;
		*area = Memory.SRAM;
		*size = sz;
		return "CARTRAM";
	}
	case 2:
		if (!(Multi.cartType && Multi.sramSizeB)) return NULL;
		*area = Multi.sramB;
		*size = (1 << (Multi.sramSizeB + 3)) * 128;
		return "CARTRAM B";
	case 3:
		if (!(Settings.SRTC || Settings.SPC7110RTC)) return NULL;
		*area = RTCData.reg;
		*size = 20;
		return "RTC";
	case 4:
		*area = Memory.VRAM;
		*size = 64 * 1024;
		return "VRAM";
	case 5:
		*area = Memory.ROM;
		*size = Memory.CalculatedSize;
		return "CARTROM";
	case 6:
		if (!Settings.SA1) return NULL;
		*area = &Memory.FillRAM[0x3000];
		*size = 2 * 1024;
		return "SA1 IRAM";
	default:
		return NULL;
	}
}

static int domain_slot(int i)
{
	int found = 0;
	for (int which = 0; which < 7; which++)
	{
		void *area = NULL;
		int64_t size = 0;
		int w = 0;
		if (memdom(which, &area, &size, &w) != NULL)
		{
			if (found == i) return which;
			found++;
		}
	}
	return -1;
}

ECL_EXPORT int GetMemoryDomainCount(void)
{
	int count = 0;
	for (int which = 0; which < 7; which++)
	{
		void *area = NULL;
		int64_t size = 0;
		int w = 0;
		if (memdom(which, &area, &size, &w) != NULL) count++;
	}
	return count;
}
ECL_EXPORT const char *GetMemoryDomainName(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 ? memdom(which, &area, &size, &w) : NULL;
}
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 && memdom(which, &area, &size, &w) != NULL ? (uint8_t *)area : NULL;
}
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 && memdom(which, &area, &size, &w) != NULL ? size : 0;
}
ECL_EXPORT int GetMemoryDomainWritable(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 && memdom(which, &area, &size, &w) != NULL ? w : 0;
}

/* ---- savedata export: the battery-backed pieces (SaveRAM starts empty
 * every boot; this channel is the way OUT) ---- */
static const char *savedata_entry(int32_t i, uint8_t **buf, int64_t *size)
{
	int32_t found = 0;
	void *area = NULL;
	int64_t sz = 0;
	int w = 0;
	static const int saveable[] = { 1, 2, 3 }; /* CARTRAM, CARTRAM B, RTC */
	static const char *const names[] = { "CARTRAM.sav", "CARTRAM_B.sav", "RTC.sav" };
	for (int k = 0; k < 3; k++)
	{
		if (memdom(saveable[k], &area, &sz, &w) == NULL) continue;
		if (found == i)
		{
			*buf = (uint8_t *)area;
			*size = sz;
			return names[k];
		}
		found++;
	}
	return NULL;
}

ECL_EXPORT int32_t GetSaveDataFileCount(void)
{
	uint8_t *b;
	int64_t n;
	int32_t count = 0;
	while (savedata_entry(count, &b, &n) != NULL) count++;
	return count;
}
ECL_EXPORT const char *GetSaveDataFileName(int32_t i)
{
	uint8_t *b;
	int64_t n;
	return savedata_entry(i, &b, &n);
}
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i)
{
	uint8_t *b = NULL;
	int64_t n = 0;
	return savedata_entry(i, &b, &n) != NULL ? n : 0;
}
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	uint8_t *b = NULL;
	int64_t n = 0;
	return savedata_entry(i, &b, &n) != NULL ? b : NULL;
}

} /* extern "C" */

/* ---- upstream port hooks (the author's list, verbatim where possible) ---- */

void S9xOnSNESPadRead()
{
	g_inputRead = 1;
}

bool8 S9xDeinitUpdate(int width, int height)
{
	if (!use_overscan)
	{
		if (height >= SNES_HEIGHT << 1)
			height = SNES_HEIGHT << 1;
		else
			height = SNES_HEIGHT;
	}
	else
	{
		if (height > SNES_HEIGHT_EXTENDED)
		{
			if (height < SNES_HEIGHT_EXTENDED << 1)
				memset(GFX.Screen + (GFX.Pitch >> 1) * height, 0,
					GFX.Pitch * ((SNES_HEIGHT_EXTENDED << 1) - height));
			height = SNES_HEIGHT_EXTENDED << 1;
		}
		else
		{
			if (height < SNES_HEIGHT_EXTENDED)
				memset(GFX.Screen + (GFX.Pitch >> 1) * height, 0,
					GFX.Pitch * (SNES_HEIGHT_EXTENDED - height));
			height = SNES_HEIGHT_EXTENDED;
		}
	}

	actual_width = width;
	actual_height = height;
	return TRUE;
}

bool8 S9xContinueUpdate(int width, int height)
{
	return true;
}

std::string S9xGetDirectory(s9x_getdirtype) { return ""; }
std::string S9xGetFilenameInc(std::string in, s9x_getdirtype) { return ""; }
void S9xParsePortConfig(ConfigFile &, int) {}
void S9xSyncSpeed() {}
const char *S9xStringInput(const char *in) { return in; }
void S9xInitInputDevices() {}
const char *S9xChooseFilename(unsigned char) { return ""; }
void S9xHandlePortCommand(s9xcommand_t, short, short) {}
bool S9xPollButton(unsigned int, bool *) { return false; }
void S9xToggleSoundChannel(int) {}
bool8 S9xInitUpdate() { return TRUE; }
void S9xExtraUsage() {}
bool8 S9xOpenSoundDevice() { return TRUE; }
void S9xMessage(int, int, const char *) {}
bool S9xPollAxis(unsigned int, short *) { return FALSE; }
void S9xSetPalette() {}
void S9xParseArg(char **, int &, int) {}
void S9xExit() {}
bool S9xPollPointer(unsigned int, short *, short *) { return false; }
const char *S9xChooseMovieFilename(unsigned char) { return NULL; }

bool8 S9xOpenSnapshotFile(const char *filepath, bool8 read_only, STREAM *file)
{
	if (read_only)
	{
		if ((*file = OPEN_STREAM(filepath, "rb")) != 0)
			return (TRUE);
	}
	else
	{
		if ((*file = OPEN_STREAM(filepath, "wb")) != 0)
			return (TRUE);
	}
	return (FALSE);
}

void S9xCloseSnapshotFile(STREAM file)
{
	CLOSE_STREAM(file);
}

void S9xAutoSaveSRAM()
{
}
