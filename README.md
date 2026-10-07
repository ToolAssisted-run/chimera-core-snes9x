# chimera-core-snes9x

**Snes9x as a Chimera waterbox core** - upstream
[Snes9x](https://github.com/snes9xgit/snes9x), compiled into
[miniBox](https://github.com/ToolAssisted-run/chimera-common-minibox)'s
deterministic sandbox and packaged as a Chimera core (`core.wbx` +
`waterbox.config`), the same shape as
[chimera-core-gpgx](https://github.com/ToolAssisted-run/chimera-core-gpgx),
[chimera-core-opera](https://github.com/ToolAssisted-run/chimera-core-opera)
and the other core repos.

The integration imitates the author's own BizHawk Snes9x port
(TASEmulators/snes9x, `bizhawk/cinterface.cpp`) almost verbatim, on a
current upstream pin, with upstream kept as clean as possible: the whole
patch set is ONE line (the resampler-buffer sizing fix; see `patches/` and
`docs/PLAN.md`). Lag detection rides upstream's own
`SNES_JOY_READ_CALLBACKS` hook, and the fork's waterbox heap surgery is
unnecessary under whole-guest savestates.

Status and plan: `docs/PLAN.md`.

## Using it in Chimera

Chimera ships no cores and downloads none. Download
`snes9x-<version>.chimeraCore` from this repository's
[Releases](https://github.com/ToolAssisted-run/chimera-core-snes9x/releases)
page (`dev` follows main, `nightly-YYYY-MM-DD` builds are dated), or build it,
and put the file in the `Cores` folder beside `Chimera.exe`. File > Core
Manager lists the cores in that folder. The same file works on Linux and on
Windows. Game files are not included: you provide them.

## Build and test

`<chimera>` is a Chimera checkout and `<minibox>` is its
`extern/chimera-common-minibox` submodule.

```
# miniBox with its C++ guest toolchain, in build/meson-cpp
meson setup <minibox>/build/meson-cpp <minibox> -Dguest_cpp=true
meson compile -C <minibox>/build/meson-cpp

# native reference + sandbox drivers
meson setup build/meson-native -Dminibox_dir=<minibox> && ninja -C build/meson-native

# the guest core
sh waterbox/setup-guest.sh -m <minibox> && ninja -C build/meson-guest

# the equivalence gate: native == sandbox == savestate-rerecord on video,
# audio, lag and every memory domain, over quickerSnes9x's homebrew movies
./waterbox/run-gate.sh

# the full movie manifest (commercial roms from tests/roms-local/)
./waterbox/tests/run-roms.sh

# the package, written to <chimera>/build/Cores/snes9x.chimeraCore
./waterbox/build-package.sh -m <minibox> -r <chimera>
```

The full instructions, from a fresh clone to the gates, are in
[docs/BUILDING.md](docs/BUILDING.md). An AI coding agent should start with
[AGENTS.md](AGENTS.md).
