#!/bin/bash
# The core-level equivalence gate: the sandboxed core must produce
# byte-identical video, audio, lag and memory-domain digests to the native
# reference build (the same cinterface.cpp compiled natively), and must
# survive a whole-machine savestate round-trip around every frame.
#
# The test base is quickerSnes9x's: real movies over the two homebrew roms
# that are free to distribute (the commercial entries run through
# tests/run-roms.sh from local files).
#
# Usage: ./run-gate.sh [-n <native build dir>] [-g <guest build dir>]
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
while getopts "n:g:" opt; do
	case "$opt" in
		n) nat="$OPTARG" ;;
		g) gst="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

[ -x "$nat/run-native" ] && [ -x "$nat/run-wbx" ] || {
	echo "native build missing: meson setup build/meson-native && ninja -C build/meson-native" >&2; exit 1; }
[ -f "$gst/core.wbx" ] || {
	echo "guest build missing: sh waterbox/setup-guest.sh && ninja -C build/meson-guest" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
digests() { grep -E '^(frames|vsync|videoHash|audioHash|lagFrames|domain\[)'; }
# What a turbo run can be held to: everything except the whole-run video hash,
# which a run that skipped the first half cannot possibly match - the second
# half it did draw is compared instead.
turboDigests() { grep -E '^(frames|vsync|tailVideoHash|audioHash|lagFrames|domain\[)'; }

ok=0
failed=0
report() { printf "%-30s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-30s %-6s %s\n" "Check" "Result" "Detail"
printf "%-30s %-6s %s\n" "-----" "------" "------"

# name rom ctl1 ctl2 movie(- = pad exercise)
tests=(
	"christmasCraze Christmas_Craze.smc joypad joypad christmasCraze.playaround.sol"
	"theLastSuper TheLastSuper.sfc joypad none theLastSuper.playaround.sol"
	"exercise Christmas_Craze.smc joypad none -"
)

for t in "${tests[@]}"; do
	read -r name rom ctl1 ctl2 movie <<< "$t"

	wd="$work/$name"
	mkdir -p "$wd"
	cp "$root/tests/roms/$rom" "$wd/"
	printf '{"cart":["%s"]}' "$rom" > "$wd/slots"
	python3 - "$wd/settings" "$ctl1" "$ctl2" <<'PYSET'
import json, sys
json.dump({"leftPort": sys.argv[2], "rightPort": sys.argv[3]}, open(sys.argv[1], "w"))
PYSET

	args=(--ctl1 "$ctl1" --ctl2 "$ctl2")
	if [ "$movie" = "-" ]; then
		args+=(--frames 600 --exercise)
	else
		args+=(--sol "$root/tests/movies/$movie")
	fi

	if ! "$nat/run-native" "$wd" "${args[@]}" 2>"$work/err" | digests > "$work/nat.txt"; then
		report "$name:equivalence" FAIL "native runner error: $(head -1 "$work/err")"; continue
	fi
	if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" 2>"$work/err" | digests > "$work/box.txt"; then
		report "$name:equivalence" FAIL "waterbox runner error: $(head -1 "$work/err")"; continue
	fi
	frames="$(sed -n 's/^frames=//p' "$work/box.txt")"
	cp "$work/box.txt" "$work/box.$name.txt"
	if cmp -s "$work/nat.txt" "$work/box.txt"; then
		report "$name:equivalence" PASS "$frames frames, native == waterboxed"
	else
		report "$name:equivalence" FAIL "$(diff "$work/nat.txt" "$work/box.txt" | tr '\n' ' ' | head -c 120)"
		continue
	fi

	# a hollow pass cannot sneak through: the input schedule must have shaped
	# the machine - an idle run of the same length must differ
	if [ "$movie" = "-" ]; then
		"$nat/run-wbx" "$gst/core.wbx" "$wd" --ctl1 "$ctl1" --ctl2 "$ctl2" \
			--frames "$frames" 2>/dev/null | digests > "$work/idle.txt"
		if cmp -s "$work/box.txt" "$work/idle.txt"; then
			report "$name:input-shaped" FAIL "the pad exercise changed nothing"
		else
			report "$name:input-shaped" PASS "input visibly shaped the machine"
		fi
	fi

	# Turbo: the core's drawing switched off for the first half of the run and
	# back on for the second. The machine, the sound, the lag count and every
	# picture of that second half must be what they would have been.
	# And the first half really must have gone undrawn. The comparison below is
	# blind to that on its own: it is held over tailVideoHash, the second half
	# only, so a SetRenderingEnabled that did nothing at all would leave every
	# compared digest identical and this leg would report "half of them undrawn"
	# about a run that drew every frame. That is not hypothetical - stubbing the
	# export to a no-op in the sibling stella core and rebuilding gave a fully
	# green gate. The whole-run videoHash is the witness, and the harness
	# already prints it: it covers the first half too, so the two runs cannot
	# agree on it unless the picture was never switched off.
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" 2>/dev/null > "$work/tnorm.raw"
	if "$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" --turbo 2>/dev/null > "$work/tturbo.raw"; then
		turboDigests < "$work/tnorm.raw" > "$work/tnorm.txt"
		turboDigests < "$work/tturbo.raw" > "$work/turbo.txt"
		nvh="$(grep -m1 '^videoHash=' "$work/tnorm.raw")"
		tvh="$(grep -m1 '^videoHash=' "$work/tturbo.raw")"
		if ! cmp -s "$work/tnorm.txt" "$work/turbo.txt"; then
			report "$name:turbo" FAIL "$(diff "$work/tnorm.txt" "$work/turbo.txt" | tr '\n' ' ' | head -c 120)"
		elif [ -z "$nvh" ] || [ -z "$tvh" ]; then
			report "$name:turbo" FAIL "no whole-run videoHash to tell a skipped frame from a drawn one"
		elif [ "$nvh" = "$tvh" ]; then
			report "$name:turbo" FAIL "the turbo run drew every frame - nothing was skipped"
		else
			report "$name:turbo" PASS "$frames frames, half of them really undrawn, same machine and same pictures"
		fi
	else
		report "$name:turbo" FAIL "turbo runner error"
	fi

if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/rr.txt"; then
		report "$name:savestate" FAIL "rerecord runner error"; continue
	fi
	if cmp -s "$work/box.txt" "$work/rr.txt"; then
		report "$name:savestate" PASS "per-frame round-trip is lossless"
	else
		report "$name:savestate" FAIL "$(diff "$work/box.txt" "$work/rr.txt" | tr '\n' ' ' | head -c 120)"
	fi
done

# ---- savedata export: any battery-backed pieces must come out identical ----
wd="$work/christmasCraze"
mkdir -p "$work/sd.nat" "$work/sd.box"
"$nat/run-native" "$wd" --frames 120 --exercise --savedata-out "$work/sd.nat" >/dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 120 --exercise --savedata-out "$work/sd.box" >/dev/null 2>&1
if diff -r "$work/sd.nat" "$work/sd.box" >/dev/null 2>&1; then
	nf="$(find "$work/sd.nat" -type f | wc -l)"
	report "savedata:export" PASS "$nf file(s), native == sandbox"
else
	report "savedata:export" FAIL "export trees differ"
fi

# ---- settings leg: leftPort=none must reach the guest - the movie's 1425
# P1 input frames become no-ops on an unplugged port, so the run diverges
# from the recorded one (and still matches ITS native reference) ----
wd="$work/portset"
mkdir -p "$wd"
cp "$root/tests/roms/Christmas_Craze.smc" "$wd/"
printf '{"cart":["Christmas_Craze.smc"]}' > "$wd/slots"
printf '{"leftPort":"none","rightPort":"none"}' > "$wd/settings"
solpath="$root/tests/movies/christmasCraze.playaround.sol"
"$nat/run-native" "$wd" --sol "$solpath" --ctl2 joypad 2>/dev/null | digests > "$work/pn.txt"
"$nat/run-wbx" "$gst/core.wbx" "$wd" --sol "$solpath" --ctl2 joypad 2>/dev/null | digests > "$work/pb.txt"
if ! cmp -s "$work/pn.txt" "$work/pb.txt"; then
	report "settings:leftPort" FAIL "$(diff "$work/pn.txt" "$work/pb.txt" | tr '\n' ' ' | head -c 120)"
elif cmp -s "$work/pb.txt" "$work/box.christmasCraze.txt" 2>/dev/null; then
	report "settings:leftPort" FAIL "unplugging the pads changed nothing"
else
	report "settings:leftPort" PASS "leftPort=none reached the guest and unplugged the pad"
fi

# ---- device legs: the multitap and the right-port analog devices. Their
# SEMANTICS need games that read them (the local movie set's job); these
# legs prove the plumbing - the same schedule lands on the same machine in
# both flavors, and survives per-frame savestate round-trips (the mouse's
# accumulated position is machine state).
device_leg() {
	# tag, the settings under test, and the settings the result must NOT match.
	local tag="$1" settings="$2" unlike="$3" unlikeName="$4"
	shift 4
	local wd="$work/dev.$tag"
	mkdir -p "$wd"
	cp "$root/tests/roms/Christmas_Craze.smc" "$wd/"
	printf '{"cart":["Christmas_Craze.smc"]}' > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	if ! "$nat/run-native" "$wd" "$@" 2>"$work/err" | digests > "$work/dn.txt"; then
		report "$tag:equivalence" FAIL "native runner error: $(head -1 "$work/err")"; return
	fi
	if ! "$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>"$work/err" | digests > "$work/db.txt"; then
		report "$tag:equivalence" FAIL "waterbox runner error: $(head -1 "$work/err")"; return
	fi
	if ! cmp -s "$work/dn.txt" "$work/db.txt"; then
		report "$tag:equivalence" FAIL "$(diff "$work/dn.txt" "$work/db.txt" | tr '\n' ' ' | head -c 120)"; return
	fi
	# Both sides of that comparison were built from the same settings, so it
	# says the two flavors agree and nothing at all about WHAT they agreed on.
	# The parser answers a device name it does not know with a joypad and a line
	# on stderr (cinterface.cpp, "unknown %s '%s', using joypad") that nothing
	# here reads - so deleting a device from it left both flavors building a
	# joypad, agreeing perfectly, and round-tripping a state with nothing in it.
	# Deleting the superScope line and rebuilding gave 22 ok, 0 failed. So each
	# leg also names a machine its own must not be.
	#
	# For the three right-port analog devices that machine is a plain pad, which
	# is exactly what the broken parser falls back to. The multitap cannot be
	# held to that here: Christmas_Craze reads ports one and two and never looks
	# further, so a multitap and a pad leave it byte-identical (measured). Its
	# control is the empty port instead, which proves the name reached the guest
	# without proving it arrived as a multitap - a game that reads a third pad
	# is what would close that, and the local movie set is where it belongs.
	printf '%s' "$unlike" > "$wd/settings"
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>/dev/null | digests > "$work/dp.txt"
	printf '%s' "$settings" > "$wd/settings"
	if cmp -s "$work/db.txt" "$work/dp.txt"; then
		report "$tag:equivalence" FAIL "the device built the machine $unlikeName builds - did the name reach the guest at all?"; return
	fi
	report "$tag:equivalence" PASS "native == waterboxed, and not the machine $unlikeName makes"
	if "$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" --rerecord 2>/dev/null | digests > "$work/dr.txt" \
		&& cmp -s "$work/db.txt" "$work/dr.txt"; then
		report "$tag:savestate" PASS "per-frame round-trip is lossless"
	else
		report "$tag:savestate" FAIL "rerecord differs"
	fi
}
device_leg "multitap" '{"leftPort":"multitap","rightPort":"none"}' \
	'{"leftPort":"none","rightPort":"none"}' "an empty port" --frames 300 --exercise --exercise-pad 3
device_leg "mouse" '{"rightPort":"mouse"}' \
	'{"leftPort":"joypad","rightPort":"joypad"}' "a plain pad" --frames 300 --exercise --wiggle-axes
device_leg "superScope" '{"rightPort":"superScope"}' \
	'{"leftPort":"joypad","rightPort":"joypad"}' "a plain pad" --frames 300 --exercise --wiggle-axes
device_leg "justifier" '{"rightPort":"justifier"}' \
	'{"leftPort":"joypad","rightPort":"joypad"}' "a plain pad" --frames 300 --exercise --wiggle-axes

# ---- MSU1: the expansion pack must be FOUND by both flavors (a game that
# never reads it leaves no trace in the digests, so the witness is the
# core's own boot report), and the machine must still run identically.
wd="$work/msu1"
mkdir -p "$wd"
cp "$root/tests/roms/Christmas_Craze.smc" "$wd/"
python3 "$here/tests/gen-msu1.py" "$wd" Christmas_Craze >/dev/null
printf '{"cart":["Christmas_Craze.smc"],"msu1":["Christmas_Craze.msu","Christmas_Craze-1.pcm"]}' > "$wd/slots"
"$nat/run-native" "$wd" --frames 300 --exercise 2>"$work/mn.err" | digests > "$work/mn.txt"
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 300 --exercise 2>"$work/mb.err" | digests > "$work/mb.txt"
if ! grep -q '\[snes9x\] MSU1 present' "$work/mn.err"; then
	report "msu1:detected" FAIL "the native run did not find the pack"
elif ! grep -q '\[snes9x\] MSU1 present' "$work/mb.err"; then
	report "msu1:detected" FAIL "the sandboxed run did not find the pack"
elif ! cmp -s "$work/mn.txt" "$work/mb.txt"; then
	report "msu1:detected" FAIL "$(diff "$work/mn.txt" "$work/mb.txt" | tr '\n' ' ' | head -c 120)"
else
	report "msu1:detected" PASS "both flavors mounted the pack and ran identically"
fi
rm -f "$wd/Christmas_Craze.msu" "$wd/Christmas_Craze-1.pcm"
printf '{"cart":["Christmas_Craze.smc"]}' > "$wd/slots"
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 5 2>"$work/mo.err" >/dev/null
if grep -q '\[snes9x\] MSU1 absent' "$work/mo.err"; then
	report "msu1:absent" PASS "without a pack the machine reports MSU1 absent"
else
	report "msu1:absent" FAIL "the pack-less machine still claims MSU1"
fi

echo ""
echo "$ok ok, $failed failed"
[ "$failed" -gt 0 ] && exit 1
exit 0
