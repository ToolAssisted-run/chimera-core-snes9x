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

## Build and test

```
# native reference + sandbox drivers
meson setup build/meson-native && ninja -C build/meson-native

# the guest core (needs miniBox's C++ toolchain, e.g. in a chimera checkout:
#   meson setup extern/miniBox/build/meson-cpp extern/miniBox -Dguest_cpp=true
#   ninja -C extern/miniBox/build/meson-cpp)
sh waterbox/setup-guest.sh && ninja -C build/meson-guest

# the equivalence gate: native == sandbox == savestate-rerecord on video,
# audio, lag and every memory domain, over quickerSnes9x's homebrew movies
./waterbox/run-gate.sh

# the full movie manifest (commercial roms from tests/roms-local/)
./waterbox/tests/run-roms.sh
```
