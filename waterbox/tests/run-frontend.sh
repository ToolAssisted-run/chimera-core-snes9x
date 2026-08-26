#!/bin/bash
# The frontend half of the gate: load the Snes9x package in Chimera
# (under Mono, on a private Xvfb display), boot a homebrew cartridge (Christmas Craze) for a
# fixed number of frames with nothing pressed, and require the whole 68K RAM
# domain to be byte-identical to the native reference. Then prove a
# machine-shaping setting arrives (forceVDP=pal builds a different machine
# that still matches ITS native reference), and that the package's keybinds
# become the frontend's defaults.
#
# Usage: ./run-frontend.sh [--chimera-root <path>] [--frames N]
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
frames=300
chimera_root=""
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera-root) chimera_root="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
	shift
done

if [ -z "$chimera_root" ]; then
	for candidate in "$root/../chimera" "$HOME/chimera"; do
		[ -d "$candidate" ] && { chimera_root="$candidate"; break; }
	done
fi
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || {
	echo "chimera checkout not found; pass --chimera-root <path>" >&2; exit 1; }
chimera_root="$(cd "$chimera_root" && pwd)"

emu_exe="$chimera_root/build/Chimera.exe"
package="$chimera_root/build/Cores/snes9x.zip"
rn="$root/build/meson-native/run-native"
rom="$root/tests/roms/Christmas_Craze.smc"
[ -f "$emu_exe" ] || { echo "Chimera not built: $emu_exe" >&2; exit 1; }
[ -f "$package" ] || { echo "package not installed: $package (run ../build-package.sh)" >&2; exit 1; }
[ -x "$rn" ] || { echo "native reference not built" >&2; exit 1; }

work="$here/work"
mkdir -p "$work"

export LD_LIBRARY_PATH="$chimera_root/build/dll:$chimera_root/build:/usr/lib/x86_64-linux-gnu"
export MONO_CRASH_NOFILE=1 MONO_WINFORMS_XIM_STYLE=disabled ALSOFT_DRIVERS=null
xvfb_pid=""
cleanup() { [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null; }
trap cleanup EXIT
if [ -z "${DISPLAY:-}" ]; then
	command -v Xvfb >/dev/null || { echo "Xvfb not found (apt install xvfb)" >&2; exit 1; }
	for n in 90 91 92 93 94 95 96; do
		if [ ! -e "/tmp/.X11-unix/X$n" ]; then
			Xvfb ":$n" -screen 0 640x480x24 -nolisten tcp & xvfb_pid=$!
			export DISPLAY=":$n"; break
		fi
	done
	sleep 1
fi

config="$work/config.ini"
if [ ! -f "$config" ]; then
	( cd "$chimera_root" && timeout 120 mono "$emu_exe" --headless "--config=$config" \
		"--lua=$here/exit.lua" ) > "$work/bootstrap.log" 2>&1
	[ -f "$config" ] || { echo "config bootstrap failed (see $work/bootstrap.log)" >&2; exit 1; }
fi
sed -i 's/"DispMethod": [0-9]/"DispMethod": 1/' "$config"

ok=0
failed=0
report() { printf "%-28s %-9s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-28s %-9s %s\n" "Check" "Result" "Detail"
printf "%-28s %-9s %s\n" "-----" "------" "------"

run_frontend() {
	local tag="$1" cfg="$2" nframes="$3" shot="${4:-}" hold="${5:-}"
	local job="$work/job.$tag.txt"
	{
		echo "frames=$nframes"
		echo "out=$work/$tag.ram.bin"
		echo "meta=$work/$tag.meta.txt"
		echo "shot=$shot"
		echo "hold=$hold"
	} > "$job"
	rm -f "$work/$tag.ram.bin" "$work/$tag.meta.txt"
	[ -n "$shot" ] && rm -f "$shot"
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout 900 mono "$emu_exe" --headless \
		"--config=$cfg" "--core=$package" \
		"--lua=$here/frontend-ram.lua" "$rom" ) > "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}

# a native reference run: same rom and schedule; settings JSON in $2, an
# optional movie in $3 (the input-leg twin of the lua hold)
native_ram() {
	local tag="$1" settings="$2" sol="${3:-}"
	local wd="$work/native.$tag"
	rm -rf "$wd"
	mkdir -p "$wd"
	cp "$rom" "$wd/"
	printf '{"cart":["%s"]}' "$(basename "$rom")" > "$wd/slots"
	[ -n "$settings" ] && printf '%s' "$settings" > "$wd/settings"
	local extra=(--frames "$frames")
	[ -n "$sol" ] && extra=(--sol "$sol" --ctl2 none --frames "$frames")
	"$rn" "$wd" "${extra[@]}" --dump-domain "WRAM" "$work/native.$tag.ram.bin" \
		> "$work/native.$tag.txt" 2>&1
}

settings_config() { python3 "$here/settings-config.py" "$config" "$1" "$2"; }

# --- the machine the frontend builds must be the one the gate signed off on ---
settings_config "$work/config.base.ini" '{}'
if ! native_ram "base" ""; then
	report "cart:frontend" FAIL "native runner error (see tests/work/native.base.txt)"
elif ! run_frontend "base" "$work/config.base.ini" "$frames" "$work/base.png"; then
	report "cart:frontend" FAIL "no OK meta (see tests/work/base.log)"
elif cmp -s "$work/native.base.ram.bin" "$work/base.ram.bin"; then
	report "cart:frontend" PASS "$frames frames, WRAM identical to the native reference"
else
	report "cart:frontend" FAIL "WRAM differs from the native reference"
fi

# --- input through the frontend, and a machine-shaping setting on top ---
# lua holds P1 Right+Start on every frame; the native twin replays a movie
# with the same two columns held. Then the same schedule with leftPort=none
# must land on a DIFFERENT machine (the held buttons go dead) that still
# matches ITS native reference.
solhold="$work/hold.sol"
python3 - "$solhold" "$frames" <<'PYSOL'
import sys
line = "|..|...R.S......|"
open(sys.argv[1], "w").write((line + "\n") * int(sys.argv[2]))
PYSOL
if ! native_ram "hold" "" "$solhold"; then
	report "input:frontend" FAIL "native runner error (see tests/work/native.hold.txt)"
elif ! run_frontend "hold" "$work/config.base.ini" "$frames" "" "P1 Right,P1 Start"; then
	report "input:frontend" FAIL "run did not report OK (see tests/work/hold.log)"
elif ! cmp -s "$work/native.hold.ram.bin" "$work/hold.ram.bin"; then
	report "input:frontend" FAIL "held-input WRAM differs from the native reference"
elif cmp -s "$work/hold.ram.bin" "$work/base.ram.bin"; then
	report "input:frontend" FAIL "holding buttons changed nothing"
else
	report "input:frontend" PASS "P1 Right+Start through the frontend matches the native movie twin"
fi

settings_config "$work/config.noport.ini" '{"leftPort": "none"}'
if ! native_ram "noport" '{"leftPort":"none"}' "$solhold"; then
	report "settings:leftPort" FAIL "native runner error (see tests/work/native.noport.txt)"
elif ! run_frontend "noport" "$work/config.noport.ini" "$frames" "" "P1 Right,P1 Start"; then
	report "settings:leftPort" FAIL "run did not report OK (see tests/work/noport.log)"
elif ! cmp -s "$work/native.noport.ram.bin" "$work/noport.ram.bin"; then
	report "settings:leftPort" FAIL "unplugged WRAM differs from its native reference"
elif cmp -s "$work/noport.ram.bin" "$work/hold.ram.bin"; then
	report "settings:leftPort" FAIL "leftPort=none built the same machine as the default"
else
	report "settings:leftPort" PASS "leftPort=none arrived and made the held buttons go dead"
fi

# --- the bindings the package ships must become the frontend's defaults ---
python3 "$here/forget-controller.py" "$work/config.base.ini" "$work/config.keys.ini" "SNES Controller"
if run_frontend "keys" "$work/config.keys.ini" 1; then
	if python3 "$here/check-keybinds.py" "$work/config.keys.ini" \
		"$wb/default_keybinds.json" "SNES Controller" > "$work/keys.txt" 2>&1; then
		report "keybinds" PASS "$(cat "$work/keys.txt")"
	else
		report "keybinds" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "keybinds" FAIL "run did not report OK (see tests/work/keys.log)"
fi

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
