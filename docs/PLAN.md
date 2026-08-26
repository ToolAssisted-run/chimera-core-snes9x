# chimera-core-snes9x: Snes9x as a Chimera waterbox core

SNES emulation for Chimera, built from upstream Snes9x compiled into
miniBox's deterministic sandbox and packaged as `core.wbx` +
`waterbox.config`. The chimera-core-gpgx / chimera-core-opera playbook,
applied a third time.

## Sources and their roles

- **BizHawk waterbox/snes9x** (the TASEmulators/snes9x fork @ 21c7dbb, whose
  bizhawk/cinterface.cpp is the author's integration): imitated almost
  verbatim - the Settings block, the controller mapping (S9xMapButton names,
  the port-device walk), the memory-domain table, the RGB565 blit, the
  audio landing sequence.
- **Upstream snes9xgit/snes9x @ 2971061c** (376 commits past the fork base
  e49165c5): the emulation core, vendored as submodule `extern/snes9x`.
  THE RULE: keep upstream as clean as possible.
- **quickerSnes9x**: the movie test base - 4 games' .sol movies, two of them
  homebrew and VENDORED here (Christmas Craze, The Last Super); Arkanoid and
  Prince of Persia stay local-files-only.

## The fork diff (e49165c5..21c7dbb) - what survives, what dissolves

The fork carried ~9000 diff lines; almost all of it is not needed:

- **memmap.cpp**: 8057 lines of which 61 are real (whitespace churn). The
  real ones swap std::vector/malloc storage for emulibc heaps (invisible
  tile caches, plain ROM/SRAM) plus stack-array deinterleave buffers. ALL
  DROPPED: whole-guest savestates make every heap correct by construction;
  the invisible-cache optimization also NEEDED the biz_post_load_state
  invalidation hook, which chimera's host-side savestates would never call.
  (The 512KB stack array in S9xDeinterleaveGD24 would overflow the musl
  guest stack anyway - upstream's malloc version is strictly better here.)
- **gfx.cpp/gfx.h**: same heap swaps plus the OBJ-priority display toggles
  (Settings.OBJ_Displayed). DROPPED - BizHawk NON-SYNC display knobs
  (layers, sound channels) do not exist in chimera.
- **apu/bapu/smp/core.cpp**: 156 lines of pure line-ending churn. DROPPED.
- **controls.cpp pad_read sticky**: not needed - lag detection uses
  upstream's own SNES_JOY_READ_CALLBACKS hook (S9xOnSNESPadRead raises the
  guest's InputWasRead flag; upstream fires it on the first pad read of
  each frame).
- **msu1.cpp/h BizHawk file callbacks**: DROPPED - MSU1 data/audio are real
  files in the guest FS; upstream's stream.cpp (plain stdio) reads them.
  Wiring the file NAMES is the MSU1 milestone (LoadROMMem takes an optional
  rom filename, which S9xGetFilename derives siblings from).
- **KEPT: apu/apu.cpp one-liner** - size the resampler buffer from the
  INPUT rate (the author's "ensure resampler buffer size spans at least
  20ms" fix; upstream still lacks it). The entire upstream patch set.

## Settings

`leftPort` (none/joypad/multitap) and `rightPort` (none/joypad/multitap/
mouse/superScope/justifier) - exactly BizHawk's sync-settings catalogue.
BizHawk's non-sync settings (8 sound channels, 4 BG layers, 4 sprite
priorities, window, transparency) are display/audio knobs and do not exist
here. The machine constants (rates, HDMA timing, sprite tiles per line,
BlockInvalidVRAMAccess, UpAndDown allowed) are hardcoded exactly as
bizhawk/cinterface.cpp's biz_init.

## Input (the wire)

0 Power (hard reset), 1 Reset (soft), then P1..P8 x
{Up,Down,Left,Right,Select,Start,Y,B,X,A,L,R} = 98 buttons (wide SetButton
channel; the order is quickerSnes9x's .sol column order). Which pads are
live follows the port settings exactly like the fork's
retro_set_controller_port_device walk: left multitap = P1..P4, right
device's pads start after the left's. Mouse / Super Scope / Justifier
(buttons + pointer axes) land with the exotic-input milestone; the movie
test base is joypads only.

## Milestones

- **M1+M2 - native reference + core.wbx + gate**: repo, submodule, the
  1-line patch, cinterface.cpp (C++ port of bizhawk/cinterface.cpp behind
  the chimera guest ABI, shared by both flavors), the shared gate harness
  with quickerSnes9x's sol format (|Pr|UDLRsSYBXAlr|x2), run-gate.sh over
  the two vendored homebrews + pad exercise: equivalence + per-frame
  savestate round-trips on all digests. C++ guest build (miniBox meson-cpp
  toolchain, the dosbox recipe).
- **M3 - package**: waterbox.config (2 settings, 98-button wire, lag group,
  extensions .sfc/.smc/.swc/.fig/.bs), file_slots.json (cart slot),
  default_keybinds.json (BizHawk's SNES defaults), savedata (CARTRAM /
  CARTRAM B / RTC), build-package.sh, CI.
- **M4 - frontend gate**: WRAM byte-identical inside Chimera, a port
  setting proven through the config, keybinds adopted.
- **M5 - local movies**: run-roms.sh over the full quickerSnes9x manifest
  (Arkanoid, Prince of Persia from tests/roms-local/).
- **M6 - exotic input** (mouse/scope/justifier + pointer axes), **MSU1**
  (slot + filename wiring), multitap gate leg.
- **M7 - tooling**: registers/trace via the 65c816, later.

## Build

Same commands as the sibling repos; the guest needs miniBox's C++ toolchain
(`meson setup <miniBox>/build/meson-cpp -Dguest_cpp=true`).

## Milestone log

- 2026-08-26: repo created, upstream pinned at 2971061c.
- 2026-08-26: M1-M5 DONE the same day, all gates green, and the upstream
  patch set is literally ONE line (the resampler-buffer sizing fix). Lag
  detection needed no patch at all (SNES_JOY_READ_CALLBACKS +
  S9xOnSNESPadRead); the fork's ~9000 diff lines were whitespace churn,
  waterbox heap surgery made unnecessary by whole-guest savestates, and
  non-sync display toggles chimera does not have.
  run-gate.sh 9/9: both homebrew movies (3101 + 3771 frames) native ==
  sandbox == per-frame savestate round-trips, pad exercise input-shaped,
  savedata trees, and leftPort=none proven to unplug the movie's pad
  (note: port devices are INVISIBLE to an idle machine - a settings leg
  must press buttons to see them). tests/run-frontend.sh 4/4 including a
  NEW frontend INPUT leg: lua joypad.set holding P1 Right+Start matches a
  native movie twin byte-for-byte in WRAM (sharp edge: the native twin
  must cap --frames alongside --sol, or the harness runs the 600-frame
  default past the movie). tests/run-roms.sh replays the manifest (2
  homebrews pass; Arkanoid + Prince of Persia from tests/roms-local/).
  Package installs as build/Cores/snes9x.zip; CI written (needs the
  meson-cpp C++ guest toolchain, like dosbox).
  REMAINING (after the exotic-input update below): MSU1 (slot + filename
  wiring via LoadROMMem's optional name), BSX/Sufami multi-cart, tooling.
- 2026-08-26 (later): M6 exotic input DONE (17/17 + frontend 4/4). The wire
  grew the right-port device blocks (Mouse Left/Right, the five Super Scope
  buttons, the three Justifier buttons = 108 buttons) and six axes (mouse
  deltas -127..127, gun pointers 0..255/0..239 - BizHawk's AddLightGun
  ranges); the guest reports them exactly like the fork's report_buttons
  (relative-to-absolute mouse accumulation included, as savestated machine
  state). The harness gained SetAxis plumbing, --exercise-pad N and
  --wiggle-axes; four new gate legs (multitap driving P3, mouse, superScope,
  justifier) prove the plumbing: same schedule -> same machine in both
  flavors + per-frame savestate round-trips. Device SEMANTICS (a game that
  reads a mouse) ride the local movie set later.
