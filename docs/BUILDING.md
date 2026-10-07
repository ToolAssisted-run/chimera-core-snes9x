# Building the Snes9x core

This repository builds Snes9x as a sandboxed guest (`core.wbx`) and packages
it as one file, `snes9x.chimeraCore`, which Chimera loads as a Super Nintendo.
The steps below are the ones `.github/workflows/chimera.yml` runs from a fresh
clone on a public Ubuntu runner, where they pass.

Two placeholders are used throughout:

- `<chimera>` is the absolute path of a Chimera checkout
  (https://github.com/ToolAssisted-run/chimera).
- `<minibox>` is `<chimera>/extern/chimera-common-minibox`, the miniBox
  submodule of that checkout. miniBox is the sandbox host and the guest
  toolchain.

## Requirements

- Linux on x86_64. CI uses GitHub's `ubuntu-latest` runner. Cores are built on
  Linux; the package that comes out also runs on Windows.
- git.
- For the core, the package and the core gate:

  ```
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends meson ninja-build build-essential python3
  ```

  The compilers are the distribution's gcc and g++ from `build-essential`. The
  workflow pins no compiler version. The guest is compiled by the same gcc and
  g++ through miniBox's musl specs file, so there is no separate cross
  compiler to install.
- For the frontend gate only, a built Chimera, which needs more packages:

  ```
  sudo apt-get install -y --no-install-recommends \
    meson ninja-build build-essential cmake pkg-config python3 \
    mono-complete xvfb \
    libgl1-mesa-dev libx11-dev libxext-dev libasound2-dev
  ```

  and the .NET SDK 8.0. The workflow installs it with
  `actions/setup-dotnet@v4` and `dotnet-version: '8.0'`. By hand, Chimera's
  README gives this command:

  ```
  curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0
  ```

- One download happens during the build, and miniBox does it itself. Snes9x is
  C++, so the guest needs a C++ standard library built for the sandbox.
  miniBox's C++ guest toolchain fetches the GCC source that matches the
  installed gcc (about 84 MB, with `curl`, from the GNU mirrors) and builds
  libstdc++ from it. The machine needs network access for that one step. The
  tarball is kept in the miniBox build directory, so a rebuild does not fetch
  it again.

## Get the sources

This repository, with its submodule. The workflow uses `actions/checkout@v6`
with `submodules: true`, which is:

```
git clone https://github.com/ToolAssisted-run/chimera-core-snes9x.git
cd chimera-core-snes9x
git submodule update --init
```

The submodule is `extern/snes9x`, pinned to an unmodified upstream commit.

A Chimera checkout, for miniBox. The workflow checks out Chimera's `main`
branch and then only the miniBox submodule:

```
git clone https://github.com/ToolAssisted-run/chimera.git <chimera>
git -C <chimera> submodule update --init extern/chimera-common-minibox
```

The frontend gate builds Chimera itself and needs all of its submodules
(`submodules: recursive` in the workflow):

```
git -C <chimera> submodule update --init --recursive
```

Where the scripts look when no path is given:

- `waterbox/build-package.sh` and `waterbox/tests/run-frontend.sh` look for
  Chimera at `../chimera` beside this repository, then at `$HOME/chimera`.
- `meson.build` (the native build) looks for miniBox at
  `../chimera/extern/chimera-common-minibox`.
- `waterbox/setup-guest.sh` (the guest build) looks for miniBox at
  `$HOME/chimera/extern/chimera-common-minibox`.

These defaults differ from each other. Pass the paths explicitly, as CI does
and as every command below does.

## Build miniBox

Build it with the C++ guest toolchain, in the build directory `meson-cpp`:

```
meson setup <minibox>/build/meson-cpp <minibox> -Dguest_cpp=true
meson compile -C <minibox>/build/meson-cpp
```

This builds, under `<minibox>/build/meson-cpp`:

- the sandbox host library, `source/host/libminiboxhost.so`, which the
  `run-wbx` test driver links;
- the guest toolchain: `guest-sysroot/` (musl and libstdc++) and the objects
  the guest links.

The directory name matters. Both this repository's `meson.build` and
`waterbox/setup-guest.sh` look in `<minibox>/build/meson-cpp` and nowhere
else. A miniBox built only as `build/meson-linux`, the plain C flavor, is not
enough for this core.

The workflow keeps this directory in a cache (`actions/cache@v4`) and skips
`meson setup` when `build.ninja` is already there. By hand, keep the directory
and run only `meson compile` the next time.

## Build the core

### Patches

The whole change to Snes9x is `patches/0001-chimera-hooks.patch`: one line in
`apu/apu.cpp` that sizes the resampler buffer from the input rate.
`waterbox/apply-patches.sh` applies the patches to the working tree of
`extern/snes9x`. `meson.build` runs that script at every configure, so there
is no need to run it by hand.

How the script behaves:

- It looks for the string `ensure resampler buffer size` in
  `extern/snes9x/apu/apu.cpp`. If the string is there, the tree counts as
  patched and the script does nothing.
- Otherwise it runs `git apply` for each file in `patches/`, in order, and
  prints `applied <name>` for each.

After the first configure `git status` shows the submodule as modified. That
is the applied patch, and it is expected.

### The native reference and the sandbox driver

```
meson setup build/meson-native -Dminibox_dir=<minibox>
ninja -C build/meson-native
```

This builds two programs in `build/meson-native`:

- `run-native` is the reference: the same `waterbox/cinterface.cpp` and the
  same Snes9x sources, compiled for the host with no sandbox. The gates
  compare the sandboxed core against it.
- `run-wbx` runs `core.wbx` through the miniBox host library and prints the
  same digests as `run-native`.

`ninja -C build/meson-native run-native` builds the reference alone. That is
enough for the frontend gate.

### The guest core

```
MINIBOX_DIR=<minibox> sh waterbox/setup-guest.sh -- -Dminibox_dir=<minibox>
ninja -C build/meson-guest
```

`setup-guest.sh` writes the meson cross file `build/guest-cross.ini` (paths of
this machine; do not commit it) and configures `build/meson-guest`. It takes
the miniBox path from `-m <miniBox dir>` or from `MINIBOX_DIR`. Arguments
after `--` go to `meson setup`. The result is `build/meson-guest/core.wbx`.

## Build the package

```
./waterbox/build-package.sh -m <minibox> -r <chimera>
```

Options:

- `-m <miniBox dir>`: the miniBox checkout. Default: `MINIBOX_DIR`, then
  `<chimera root>/extern/chimera-common-minibox`.
- `-r <chimera root>`: the Chimera checkout the package is written into.
  Default: `../chimera`, then `$HOME/chimera`.

There is no option for another output directory.

What the script does:

1. Runs `waterbox/setup-guest.sh` if `build/meson-guest` is not configured,
   then builds `core.wbx`.
2. Runs miniBox's `source/guest/check-wbx.sh` on `core.wbx`.
3. Stages `core.wbx`, `waterbox.config`, `default_keybinds.json`,
   `file_slots.json`, the licence texts and `build.json` (what built the
   package) under `build/package-staging`.
4. Stamps `version` and `versionDate` into the staged `waterbox.config`.
5. Writes the package twice, compares the SHA-1 of both and prints it.
6. Removes `<chimera>/build/CoreCache/snes9x-*`.

The file lands at `<chimera>/build/Cores/snes9x.chimeraCore`.

The version is the commit the package was built from:

- CI sets `CORE_VERSION` to the full commit SHA, and the package carries that.
- Without `CORE_VERSION` the script stamps the first 12 digits of `HEAD` and
  `+local`, with `-dirty` before it when `git diff --quiet HEAD` reports
  changes: `0123456789ab+local` or `0123456789ab-dirty+local`.
- `versionDate` is the date of that commit in UTC, never the build's date.

A package built by hand is for testing. Chimera's publishing script refuses a
version that carries `+local` or `-dirty`.

In CI the frontend gate job builds the package with `CORE_VERSION` set, runs
the frontend gate on it and uploads it as the artifact `snes9x-<commit SHA>`
(`actions/upload-artifact@v7`). The `publish` job hands that artifact to
Chimera's reusable workflow `publish-core.yml`. Nothing is published from a
pull request. A run started by hand takes an input `kind`, `dev` or `nightly`;
blank means `dev`.

## Install it into Chimera

Chimera ships no cores and downloads nothing: it has no network code. A core
gets into Chimera because somebody puts its file in the cores folder.

- In a Chimera source checkout the cores folder is `<chimera>/build/Cores/`.
  `build-package.sh -r <chimera>` has already written the package there.
- In a release bundle the cores folder is `Cores` beside `Chimera.exe`, or
  another folder chosen in File > Core Manager > Change folder... Copy
  `snes9x.chimeraCore` into it.

File > Core Manager lists what is in that folder. Refresh List rescans it, so
a package copied in while Chimera runs is found without a restart.

The same package file works on Linux and on Windows: Chimera's sandbox,
miniBox, runs the guest inside it on either.

You do not have to build it. CI publishes the package on this repository's
Releases page
(https://github.com/ToolAssisted-run/chimera-core-snes9x/releases) as
`snes9x-<version>.chimeraCore`:

- `dev`: replaced on every push to main that passes the gates.
- `nightly-YYYY-MM-DD`: dated, from the scheduled run (04:00 UTC), and only
  when main moved since the last one.

To use the core, start Chimera (`build/ChimeraMono.sh` on Linux,
`build\Chimera.exe` on Windows in a source checkout), choose
File > New Project... and pick the core. To play a ROM with no project, pass
`--core=<package> <rom>` on the command line.

## Run the gates

CI runs all three and all three must pass before anything is published.

### Core gate

```
./waterbox/run-gate.sh
```

It needs `build/meson-native/run-native`, `build/meson-native/run-wbx`,
`build/meson-guest/core.wbx` and python3. It needs no Chimera build, no .NET,
no Mono and no X display. `-n <native build dir>` and `-g <guest build dir>`
point it at other build directories. It does not rebuild anything: build both
flavors first.

It runs over the two homebrew ROMs and their movies in `tests/`, so no check
is skipped for lack of content. It prints one line per check:

- `<name>:equivalence`: the sandboxed core and the native reference give the
  same frame count, vsync rate, video hash, audio hash, lag count and memory
  domain digests. Run over the two homebrew movies and a 600-frame pad
  exercise.
- `exercise:input-shaped`: the pad exercise differs from an idle run of the
  same length, so the input reached the machine.
- `<name>:turbo`: with drawing switched off for the first half of the run,
  the machine, the audio, the lag count and the second half's pictures are
  unchanged, and the whole-run video hash differs, which shows that frames
  really went undrawn.
- `<name>:savestate`: saving and loading the whole machine around every frame
  changes nothing.
- `savedata:export`: the exported save files are identical from both flavors.
- `settings:leftPort`: `leftPort=none` reaches the guest and unplugs the pad
  the movie plays on.
- `multitap`, `mouse`, `superScope`, `justifier`, each with `:equivalence` and
  `:savestate`: the device builds the same machine in both flavors, that
  machine is not the one a plain pad (for the multitap, an empty port) builds,
  and it survives per-frame savestates.
- `msu1:detected` and `msu1:absent`: both flavors find a synthetic MSU1 pack
  made by `waterbox/tests/gen-msu1.py` and run identically with it, and
  without a pack the machine reports MSU1 absent.

The last line is `<n> ok, <m> failed`. A complete run has 22 checks. The exit
status is non-zero when any check fails.

### Manifest replays

```
./waterbox/tests/run-roms.sh
```

It needs the same three build outputs as the core gate. It replays every
entry of `tests/movies/manifest.json` whose ROM it can find and requires
native == sandbox == per-frame savestate round-trip over the whole movie.

- The two homebrew entries run from `tests/roms/`.
- Every other entry reports SKIP until its ROM is in `tests/roms-local/`
  (gitignored). The SKIP line names the file.

A SKIP is not a pass: it means the check did not run. In CI only the homebrew
half runs.

### Frontend gate

This gate runs the package inside Chimera, headless, under Mono. Build Chimera
first, as the workflow does:

```
cd <chimera>
meson setup build/meson-linux --prefix "$PWD/build" --libdir dll
meson compile -C build/meson-linux
meson install -C build/meson-linux
dotnet build source/gui/Chimera.sln -c Release /nodeReuse:false -p:UseSharedCompilation=false
```

Then, in this repository, with the package built and `run-native` built:

```
./waterbox/tests/run-frontend.sh --chimera-root <chimera>
```

It needs `<chimera>/build/Chimera.exe`,
`<chimera>/build/Cores/snes9x.chimeraCore`, `build/meson-native/run-native`,
mono and python3. With `DISPLAY` unset it starts its own Xvfb and stops it on
exit; with `DISPLAY` set it uses that display. `--frames N` changes the run
length (default 300). Its checks:

- `cart:frontend`: after 300 idle frames of a homebrew cartridge, the WRAM
  inside Chimera is byte-identical to the native reference.
- `input:frontend`: P1 Right and Start, held through the frontend, give the
  WRAM of a native run of a movie holding the same buttons, and not the WRAM
  of the idle run.
- `settings:leftPort`: `leftPort=none`, set through Chimera's config, makes
  the held buttons dead: a different machine that matches its own native
  reference.
- `keybinds`: the package's `default_keybinds.json` becomes Chimera's default
  bindings for the SNES controller.

Its logs and dumps stay in `waterbox/tests/work/` (gitignored). CI uploads
that directory when the gate fails.

## Files the core needs at run time

Game files are never in this repository or in the package. The user provides
them. A project is:

| Slot | Files | Required |
| --- | --- | --- |
| Cartridge | one ROM: `.sfc`, `.smc`, `.swc`, `.fig`, `.bs` | yes |
| MSU1 audio pack | the `.msu` data file and the `-1.pcm`, `-2.pcm` ... tracks | no |

The MSU1 files must share the cartridge's stem (`rom.msu`, `rom-1.pcm` ...).
That is how the machine finds them. Without a pack the cartridge runs with
MSU1 absent.

`waterbox/waterbox.config` declares no firmware: this core needs no BIOS.

Two settings shape the machine: `leftPort` (`joypad`, `none`, `multitap`) and
`rightPort` (`joypad`, `none`, `multitap`, `mouse`, `superScope`,
`justifier`).

## Troubleshooting

- `pass -Dminibox_dir=<miniBox checkout>` from `meson setup`: the native build
  did not find miniBox at `../chimera/extern/chimera-common-minibox`. Pass
  `-Dminibox_dir=<minibox>`.
- `miniBox C++ guest toolchain missing under <minibox>/build/meson-cpp.` from
  `setup-guest.sh`: miniBox is not built with `-Dguest_cpp=true` in
  `build/meson-cpp`. Run the two commands of "Build miniBox".
- `run-wbx` does not link: it takes `libminiboxhost.so` from
  `<minibox>/build/meson-cpp/source/host`. Build miniBox in `build/meson-cpp`.
- `could not download the GCC <version> source from any mirror` while building
  miniBox: the C++ guest toolchain needs the network once.
- `chimera checkout not found; pass -r <path>` from `build-package.sh`: pass
  `-r <chimera>`.
- `native build missing` or `guest build missing` from `run-gate.sh`: the gate
  builds nothing. Build both flavors first.
- `Chimera not built`, `package not installed` or `native reference not built`
  from `run-frontend.sh`: build Chimera, run `build-package.sh`, and build
  `run-native`, in that order.
- `Xvfb not found (apt install xvfb)` from `run-frontend.sh`: `DISPLAY` is
  unset and Xvfb is not installed.
- `config bootstrap failed` from `run-frontend.sh`: Chimera did not start.
  Read `waterbox/tests/work/bootstrap.log`.
- A hand-built package is stamped `-dirty+local` even with nothing edited. The
  applied patch makes the submodule's working tree differ from its pin, and
  `git diff --quiet HEAD` counts that as a change.
- `setup-guest.sh` runs `meson setup` with its error output hidden and, when
  that fails, runs `meson setup --reconfigure`. The error you see comes from
  the second command.
- `packaging is not deterministic` from `build-package.sh`: the package was
  written twice and the two files differ. The package's SHA-1 is the core's
  identity, so the script stops.
- An unknown port device name in a settings file is not an error: the guest
  prints `unknown ... using joypad` and builds a joypad.
