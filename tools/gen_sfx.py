#!/usr/bin/env python3
"""Synthesize the new Tux-specific SFX (sword swing, shield, charge,
spin, roll, pickup, gate, blob noises). Pure stdlib — `wave` + `math` +
`struct` + `random`. Output drops into godot/assets/sounds/.

Each function below is a sound recipe; tune the constants to taste, or
just replace the produced WAVs with hand-authored audio. File names are
stable so the runtime SoundBank doesn't care which way they got there.

Run from repo root:
    python3 tools/gen_sfx.py
"""

import math
import os
import random
import struct
import wave

SR = 22050
BITS = 16
OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "godot", "assets", "sounds",
)
OUT_DIR = os.path.abspath(OUT_DIR)


# ---- DSP primitives -----------------------------------------------------

def n_samples(seconds):
    return int(round(seconds * SR))


def sine(freq, seconds, amp=1.0, freq_end=None):
    N = n_samples(seconds)
    if freq_end is None:
        freq_end = freq
    out = [0.0] * N
    p = 0.0
    for i in range(N):
        t = i / max(N - 1, 1)
        f = freq + (freq_end - freq) * t
        p += 2 * math.pi * f / SR
        out[i] = amp * math.sin(p)
    return out


def saw(freq, seconds, amp=1.0):
    N = n_samples(seconds)
    out = [0.0] * N
    p = 0.0
    for i in range(N):
        p += freq / SR
        p -= math.floor(p)
        out[i] = amp * (2.0 * p - 1.0)
    return out


def noise(seconds, amp=1.0):
    N = n_samples(seconds)
    return [amp * (random.random() * 2.0 - 1.0) for _ in range(N)]


def lowpass(buf, cutoff_hz):
    rc = 1.0 / (2 * math.pi * max(cutoff_hz, 1.0))
    dt = 1.0 / SR
    a = dt / (rc + dt)
    out = [0.0] * len(buf)
    y = 0.0
    for i, x in enumerate(buf):
        y += a * (x - y)
        out[i] = y
    return out


def highpass(buf, cutoff_hz):
    rc = 1.0 / (2 * math.pi * max(cutoff_hz, 1.0))
    dt = 1.0 / SR
    a = rc / (rc + dt)
    out = [0.0] * len(buf)
    prev_x = 0.0
    prev_y = 0.0
    for x in buf:
        y = a * (prev_y + x - prev_x)
        out.append(y) if False else None
        prev_x = x
        prev_y = y
    out = [0.0] * len(buf)
    prev_x = 0.0
    prev_y = 0.0
    for i, x in enumerate(buf):
        y = a * (prev_y + x - prev_x)
        out[i] = y
        prev_x = x
        prev_y = y
    return out


def bandpass(buf, center, width=400):
    return highpass(lowpass(buf, center + width), max(center - width, 20))


def exp_decay(N, tau_sec):
    return [math.exp(-i / (tau_sec * SR)) for i in range(N)]


def linear_decay(N, hold_frac=0.0):
    out = [0.0] * N
    hold = int(N * hold_frac)
    for i in range(N):
        if i < hold:
            out[i] = 1.0
        else:
            out[i] = max(0.0, 1.0 - (i - hold) / max(N - hold - 1, 1))
    return out


def apply_env(buf, env):
    n = min(len(buf), len(env))
    return [buf[i] * env[i] for i in range(n)]


def mix(*bufs, gains=None):
    """Mix any number of buffers (extends to longest, sums sample-wise)."""
    if not bufs:
        return []
    n = max(len(b) for b in bufs)
    if gains is None:
        gains = [1.0] * len(bufs)
    out = [0.0] * n
    for b, g in zip(bufs, gains):
        for i in range(len(b)):
            out[i] += b[i] * g
    return out


def fade_edges(buf, ms=10):
    f = min(int(SR * ms / 1000), len(buf) // 2)
    if f <= 0:
        return buf
    for i in range(f):
        k = i / f
        buf[i] *= k
        buf[-1 - i] *= k
    return buf


def normalize(buf, target=0.85):
    peak = max((abs(s) for s in buf), default=0.0)
    if peak < 1e-9:
        return buf
    g = target / peak
    return [s * g for s in buf]


def clip(buf):
    return [max(-1.0, min(1.0, s)) for s in buf]


def write_wav(name, samples):
    samples = fade_edges(list(samples))
    samples = clip(normalize(samples))
    path = os.path.join(OUT_DIR, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(BITS // 8)
        w.setframerate(SR)
        frames = bytearray()
        for s in samples:
            v = int(round(s * 32767))
            v = max(-32768, min(32767, v))
            frames += struct.pack("<h", v)
        w.writeframes(bytes(frames))
    print("wrote", os.path.relpath(path))


# ---- Tux sound recipes --------------------------------------------------
# Each one returns a list of float samples in [-1, 1]. write_wav handles
# fades + normalize + 16-bit PCM packing. All numbers below are choices,
# not derived from anywhere — tweak freely.

def sfx_sword_swing():
    # Filtered noise burst that sweeps from mid → high → silence. Sells
    # a fast horizontal slash through air.
    dur = 0.28
    n = noise(dur, 0.9)
    n = bandpass(n, 1800, 1200)
    env = exp_decay(len(n), 0.06)
    out = apply_env(n, env)
    # Add a faint pitched body so it's not purely hiss.
    body = sine(420, dur, 0.18, freq_end=240)
    return mix(out, apply_env(body, exp_decay(len(body), 0.05)))


def sfx_sword_jab():
    # Tighter, snappier than swing — quick poke whoosh.
    dur = 0.17
    n = bandpass(noise(dur, 0.9), 2500, 1500)
    out = apply_env(n, exp_decay(len(n), 0.04))
    body = sine(520, dur, 0.2, freq_end=300)
    return mix(out, apply_env(body, exp_decay(len(body), 0.03)))


def sfx_sword_hit():
    # Metallic clang on contact: short bright stack of harmonics + fast
    # decay tail.
    dur = 0.30
    a = sine(880, dur, 0.5)
    b = sine(1320, dur, 0.35)
    c = sine(2200, dur, 0.20)
    body = mix(a, b, c)
    body = apply_env(body, exp_decay(len(body), 0.07))
    edge = apply_env(noise(0.04, 0.9), exp_decay(n_samples(0.04), 0.012))
    out = mix(body, edge)
    return out


def sfx_sword_charge():
    # Rising buzz that builds — used as a one-shot wind-up for the
    # charge attack. Sustained loop variants are easy to add later.
    dur = 0.9
    s = saw(110, dur, 0.55)
    s2 = saw(165, dur, 0.30)
    body = mix(s, s2)
    body = lowpass(body, 1200)
    # Slow ramp-in envelope.
    env = [min(1.0, i / (0.5 * SR)) for i in range(len(body))]
    return apply_env(body, env)


def sfx_sword_charge_ready():
    # Bright bell-ish chime: stacked sines with decaying envelope.
    dur = 0.6
    fund = sine(880, dur, 0.6)
    h2 = sine(1320, dur, 0.30)
    h3 = sine(1760, dur, 0.18)
    body = mix(fund, h2, h3)
    return apply_env(body, exp_decay(len(body), 0.20))


def sfx_spin_attack():
    # Two overlapping whooshes 180° apart in phase, with a falling pitch
    # base. Reads as the body whirling.
    dur = 0.55
    n1 = bandpass(noise(dur, 0.9), 1400, 1000)
    n2 = bandpass(noise(dur, 0.9), 2600, 1400)
    n1 = apply_env(n1, exp_decay(len(n1), 0.18))
    n2 = apply_env(n2, exp_decay(len(n2), 0.10))
    body = sine(280, dur, 0.4, freq_end=140)
    body = apply_env(body, exp_decay(len(body), 0.20))
    return mix(n1, n2, body, gains=[1.0, 0.7, 1.0])


def sfx_jump_strike():
    # Descending whoosh — pitch drops, noise sweeps high to low. The
    # impact thud comes from sfx_land_hard at the moment of contact.
    dur = 0.5
    n = bandpass(noise(dur, 0.9), 1800, 1100)
    n = apply_env(n, linear_decay(len(n), 0.0))
    body = sine(440, dur, 0.5, freq_end=110)
    body = apply_env(body, exp_decay(len(body), 0.25))
    return mix(n, body)


def sfx_shield_raise():
    # Short woody clack: low thump + brief mid-band noise.
    dur = 0.12
    thump = sine(160, dur, 0.7, freq_end=110)
    thump = apply_env(thump, exp_decay(len(thump), 0.03))
    crinkle = bandpass(noise(dur, 0.7), 800, 400)
    crinkle = apply_env(crinkle, exp_decay(len(crinkle), 0.03))
    return mix(thump, crinkle)


def sfx_shield_block():
    # Heavier than raise: thud + metallic ring on impact.
    dur = 0.45
    thud = sine(110, 0.18, 0.9, freq_end=70)
    thud = apply_env(thud, exp_decay(len(thud), 0.05))
    ring = mix(sine(660, dur, 0.4), sine(990, dur, 0.25))
    ring = apply_env(ring, exp_decay(len(ring), 0.18))
    out = [0.0] * n_samples(dur)
    for i, s in enumerate(thud):
        if i < len(out):
            out[i] += s
    for i, s in enumerate(ring):
        if i < len(out):
            out[i] += s
    return out


def sfx_parry():
    # Sharp metallic ping — perfect block reward sound.
    dur = 0.35
    a = sine(1320, dur, 0.6)
    b = sine(1980, dur, 0.4)
    c = sine(2640, dur, 0.25)
    body = mix(a, b, c)
    return apply_env(body, exp_decay(len(body), 0.10))


def sfx_roll():
    # Cloth/leather whoosh: short noise sweep with low body.
    dur = 0.40
    n = bandpass(noise(dur, 0.8), 1100, 600)
    n = apply_env(n, exp_decay(len(n), 0.13))
    body = sine(180, dur, 0.4, freq_end=100)
    body = apply_env(body, exp_decay(len(body), 0.13))
    return mix(n, body)


def sfx_pebble_get():
    # Light glassy pickup chime.
    dur = 0.30
    a = sine(1320, dur, 0.55)
    b = sine(1760, dur, 0.35)
    body = mix(a, b)
    return apply_env(body, exp_decay(len(body), 0.13))


def sfx_crystal_hit():
    # Glassy / icy ring with a slight pitch waver.
    dur = 0.55
    a = sine(1480, dur, 0.55, freq_end=1520)
    b = sine(2220, dur, 0.40, freq_end=2300)
    c = sine(2960, dur, 0.20)
    body = mix(a, b, c)
    return apply_env(body, exp_decay(len(body), 0.22))


def sfx_gate_open():
    # Mechanical creak: low rumble + slow noise sweep upward.
    dur = 0.7
    rumble = sine(70, dur, 0.7, freq_end=110)
    rumble = apply_env(rumble, exp_decay(len(rumble), 0.4))
    creak = bandpass(noise(dur, 0.6), 600, 400)
    creak = apply_env(creak, exp_decay(len(creak), 0.5))
    return mix(rumble, creak)


def sfx_gate_close():
    # Heavy slam: short thud body + low rumble tail.
    dur = 0.45
    thud = sine(95, 0.20, 1.0, freq_end=55)
    thud = apply_env(thud, exp_decay(len(thud), 0.07))
    rumble = sine(60, dur, 0.5)
    rumble = apply_env(rumble, exp_decay(len(rumble), 0.18))
    out = [0.0] * n_samples(dur)
    for i, s in enumerate(thud):
        if i < len(out):
            out[i] += s
    for i, s in enumerate(rumble):
        if i < len(out):
            out[i] += s
    return out


def sfx_blob_alert():
    # Squelchy chirp — low rising sine + noise burst.
    dur = 0.25
    body = sine(220, dur, 0.6, freq_end=460)
    body = apply_env(body, exp_decay(len(body), 0.10))
    squelch = lowpass(noise(dur, 0.5), 800)
    squelch = apply_env(squelch, exp_decay(len(squelch), 0.08))
    return mix(body, squelch)


def sfx_blob_attack():
    # Wind-up growl: low saw with a slight rise then drop.
    dur = 0.45
    growl = saw(140, dur, 0.6, )
    growl = lowpass(growl, 700)
    pitch = sine(160, dur, 0.4, freq_end=240)
    body = mix(growl, pitch)
    return apply_env(body, exp_decay(len(body), 0.18))


def sfx_blob_die():
    # Wet splat: filtered noise burst + descending sine.
    dur = 0.30
    splat = lowpass(noise(dur, 0.9), 600)
    splat = apply_env(splat, exp_decay(len(splat), 0.10))
    drop = sine(240, dur, 0.6, freq_end=80)
    drop = apply_env(drop, exp_decay(len(drop), 0.12))
    return mix(splat, drop)


# ---- Driver -------------------------------------------------------------

RECIPES = {
    "sword_swing":         sfx_sword_swing,
    "sword_jab":           sfx_sword_jab,
    "sword_hit":           sfx_sword_hit,
    "sword_charge":        sfx_sword_charge,
    "sword_charge_ready":  sfx_sword_charge_ready,
    "spin_attack":         sfx_spin_attack,
    "jump_strike":         sfx_jump_strike,
    "shield_raise":        sfx_shield_raise,
    "shield_block":        sfx_shield_block,
    "parry":               sfx_parry,
    "roll":                sfx_roll,
    "pebble_get":          sfx_pebble_get,
    "crystal_hit":         sfx_crystal_hit,
    "gate_open":           sfx_gate_open,
    "gate_close":          sfx_gate_close,
    "blob_alert":          sfx_blob_alert,
    "blob_attack":          sfx_blob_attack,
    "blob_die":            sfx_blob_die,
}


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    random.seed(20260507)   # deterministic noise so re-runs are stable
    for name, fn in RECIPES.items():
        write_wav(name, fn())


if __name__ == "__main__":
    main()
