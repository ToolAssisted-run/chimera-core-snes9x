# chimera-core-snes9x: Snes9x in miniBox's sandbox, as a Chimera core.
#
# Native reference build (run-native + run-wbx under the build dir):
#     meson setup build/meson-native && ninja -C build/meson-native
# Guest (core.wbx) build via the cross file waterbox/setup-guest.sh writes
# (needs miniBox's C++ guest toolchain, build/meson-cpp):
#     sh waterbox/setup-guest.sh && ninja -C build/meson-guest core.wbx
#
# The source list is the author's TASEmulators/snes9x Makefile list; the
# defines match it (SNES_JOY_READ_CALLBACKS is upstream's own lag hook).
# Both flavors compile the SAME cinterface.cpp; only emulibc.h differs.
project('chimera-core-snes9x', ['c', 'cpp'],
  default_options: ['c_std=gnu99', 'cpp_std=c++17', 'optimization=2', 'debug=false', 'warning_level=0'])

s9x = 'extern/snes9x'

# the submodule pin is pristine upstream; overlay the chimera patch set
# (idempotent, ONE line - see docs/PLAN.md)
run_command(files('waterbox/apply-patches.sh'), check: true)

mb = get_option('minibox_dir')
if mb == ''
  mb_candidate = meson.current_source_dir() / '../chimera/extern/miniBox'
  if import('fs').is_dir(mb_candidate)
    mb = mb_candidate
  else
    error('pass -Dminibox_dir=<miniBox checkout> (or keep one at ../chimera/extern/miniBox)')
  endif
endif

defs = [
  '-DNDEBUG',
  '-DHAVE_STRINGS_H',
  '-DHAVE_STDINT_H',
  '-DRIGHTSHIFT_IS_SAR',
  '-D__LIBRETRO__',
  '-DSNES_JOY_READ_CALLBACKS',
]
quiet = [
  '-fno-strict-aliasing',
  '-Wall',
  '-Wfatal-errors',
  '-fomit-frame-pointer',
]
add_project_arguments(defs + quiet, language: ['c', 'cpp'])

inc = include_directories(
  'waterbox',
  s9x,
  s9x / 'apu',
  s9x / 'apu/bapu',
)

core_sources = files(
  s9x / 'apu/apu.cpp',
  s9x / 'apu/bapu/dsp/sdsp.cpp',
  s9x / 'apu/bapu/smp/smp.cpp',
  s9x / 'apu/bapu/smp/smp_state.cpp',
  s9x / 'bml.cpp',
  s9x / 'bsx.cpp',
  s9x / 'c4.cpp',
  s9x / 'c4emu.cpp',
  s9x / 'cheats.cpp',
  s9x / 'cheats2.cpp',
  s9x / 'clip.cpp',
  s9x / 'conffile.cpp',
  s9x / 'controls.cpp',
  s9x / 'cpu.cpp',
  s9x / 'cpuexec.cpp',
  s9x / 'cpuops.cpp',
  s9x / 'crosshairs.cpp',
  s9x / 'dma.cpp',
  s9x / 'dsp.cpp',
  s9x / 'dsp1.cpp',
  s9x / 'dsp2.cpp',
  s9x / 'dsp3.cpp',
  s9x / 'dsp4.cpp',
  s9x / 'fscompat.cpp',
  s9x / 'fxinst.cpp',
  s9x / 'fxemu.cpp',
  s9x / 'gfx.cpp',
  s9x / 'globals.cpp',
  s9x / 'memmap.cpp',
  s9x / 'movie.cpp',
  s9x / 'msu1.cpp',
  s9x / 'obc1.cpp',
  s9x / 'ppu.cpp',
  s9x / 'stream.cpp',
  s9x / 'sa1.cpp',
  s9x / 'sa1cpu.cpp',
  s9x / 'screenshot.cpp',
  s9x / 'sdd1.cpp',
  s9x / 'sdd1emu.cpp',
  s9x / 'seta.cpp',
  s9x / 'seta010.cpp',
  s9x / 'seta011.cpp',
  s9x / 'seta018.cpp',
  s9x / 'sha256.cpp',
  s9x / 'snapshot.cpp',
  s9x / 'snes9x.cpp',
  s9x / 'spc7110.cpp',
  s9x / 'srtc.cpp',
  s9x / 'tile.cpp',
  s9x / 'tileimpl-n1x1.cpp',
  s9x / 'tileimpl-n2x1.cpp',
  s9x / 'tileimpl-h2x1.cpp',
  'waterbox/cinterface.cpp',
)

if meson.is_cross_build()
  # ---- the guest: core.wbx --------------------------------------------------
  # miniBox's musl/libstdc++ toolchain arrives through the cross file; the
  # link recipe is the C++ guest kit's (cxxglue for the unwinder, weak
  # pthread pulls for libgcc_eh) - the chimera-core-dosbox-x recipe.
  mbdir = meson.get_external_property('minibox_dir')
  mbuild = meson.get_external_property('minibox_build')
  sr = meson.get_external_property('guest_sysroot')

  executable('core', core_sources,
    name_suffix: 'wbx',
    include_directories: inc,
    link_args: [
      '-static', '-no-pie',
      '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax', '-Wl,-z,stack-size=8388608',
      '-T', mbdir / 'source/guest/linkscript.T',
      '-Wl,-u,pthread_once', '-Wl,-u,pthread_cond_wait',
      '-Wl,-u,pthread_cond_broadcast', '-Wl,-u,pthread_key_create',
      mbuild / 'source/guest/cxxglue.c.o',
      mbuild / 'source/guest/emulibc.c.o',
      '-L' + sr / 'lib', '-lstdc++', '-lgcc', '-lgcc_eh', '-lc'])
else
  # ---- the native reference -------------------------------------------------
  m = meson.get_compiler('c').find_library('m', required: false)
  executable('run-native', core_sources + files('waterbox/run-native.c'),
    include_directories: [include_directories('waterbox/native-shim'), inc],
    c_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    cpp_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    dependencies: [m])

  mbhost = mb / 'build/meson-linux/source/host'
  executable('run-wbx', files('waterbox/run-wbx.c'),
    c_args: ['-I' + mb / 'source/host'],
    link_args: [mbhost / 'libminiboxhost.so', '-Wl,-rpath,' + mbhost])
endif
