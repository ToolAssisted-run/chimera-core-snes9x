#!/usr/bin/env python3
# Generates a deterministic synthetic MSU1 pack for a cartridge: the .msu
# data file plus one -1.pcm audio track. Not a real soundtrack - the point
# is that the machine SEES the expansion (Settings.MSU1 flips, the MSU1
# registers answer, S9xMSU1Generate mixes the track into the output) and
# that both flavors see exactly the same thing.
#
# Usage: gen-msu1.py <outdir> <rom stem>
import struct
import sys

outdir, stem = sys.argv[1], sys.argv[2]

def rng(n, seed):
    out = bytearray()
    x = seed
    while len(out) < n:
        x = (x * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
        out += struct.pack("<Q", x)
    return bytes(out[:n])

# the data file the cartridge reads through the MSU1 data port
open(f"{outdir}/{stem}.msu", "wb").write(rng(64 * 1024, 4242))

# a track: "MSU1" + little-endian loop point, then 44.1kHz stereo s16 frames
frames = 44100  # one second
pcm = bytearray(b"MSU1" + struct.pack("<I", 0))
noise = rng(frames * 4, 777)
pcm += noise
open(f"{outdir}/{stem}-1.pcm", "wb").write(bytes(pcm))

print(f"{stem}.msu (64KB) + {stem}-1.pcm ({frames} frames)")
