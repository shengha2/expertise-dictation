#!/usr/bin/env python3
"""Generate the short UI sounds (start / stop / cancel / error) as 44.1 kHz mono 16-bit WAV files.
Pure standard library so it runs anywhere. Sounds are soft two-tone blips, similar in feel to
Typeless's 0.44 s cues but synthesised here so nothing is copied from another app."""
import math, struct, wave, os, sys

RATE = 44100

def tone(freq, dur, vol=0.5, attack=0.006, release=0.06, harmonics=((1, 1.0), (2, 0.25), (3, 0.08))):
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        env = 1.0
        if t < attack:
            env = t / attack
        if t > dur - release:
            env = max(0.0, (dur - t) / release)
        s = 0.0
        for mult, amp in harmonics:
            s += amp * math.sin(2 * math.pi * freq * mult * t)
        out.append(vol * env * s)
    return out

def silence(dur):
    return [0.0] * int(RATE * dur)

def write(path, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = 0.85 / peak if peak > 0.85 else 1.0
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples))
    print("wrote", path, f"{len(samples)/RATE:.2f}s")

def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    # start: rising pair (C6 -> E6), light and quick
    write(os.path.join(outdir, "start.wav"), tone(1046.5, 0.09, 0.45) + tone(1318.5, 0.13, 0.42))
    # stop: falling pair (E6 -> C6)
    write(os.path.join(outdir, "stop.wav"), tone(1318.5, 0.09, 0.42) + tone(1046.5, 0.15, 0.40))
    # cancel: single low soft tap
    write(os.path.join(outdir, "cancel.wav"), tone(523.3, 0.12, 0.35))
    # error: two low tones
    write(os.path.join(outdir, "error.wav"), tone(392.0, 0.12, 0.42) + silence(0.04) + tone(311.1, 0.18, 0.42))

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds"))
