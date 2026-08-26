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

echo ""
echo "$ok ok, $failed failed"
[ "$failed" -gt 0 ] && exit 1
exit 0
