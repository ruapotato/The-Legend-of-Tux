"""Render a Zelda-flavored interpolation of the Boléro melody.

Keeps the Boléro melodic skeleton (note sequence + rhythm from the source MIDI)
but dresses it in a Zelda-style arrangement:

  - Transposed -2 semitones to Bb major (classic Hyrule Field key)
  - Mild Mixolydian flavor: lower the leading-tone (A4 in Bb) to Ab in two
    spots where the melody approaches it as a passing tone, giving the
    modal "heroic" feel without rewriting the theme
  - Heroic 4-note ascending pickup before Theme A (D-F-Bb arpeggio fanfare)
  - Tempo bumped to 108 BPM for an energetic, march-like feel
  - Layered timbre:
      Lead: brass/horn-like additive synth (rich harmonics, soft saturation)
      Harp: rolled-chord arpeggios, one per bar, decaying plucks
      Pad: detuned-saw string pad sustaining I-V harmonic plan
  - No specific Zelda melodic phrases are quoted — only stylistic elements
    (instrumentation, key, mode flavor, heroic intervals).
"""
import math
import wave

import mido
import numpy as np

SOURCE_MIDI = "bolero_source.mid"
OUTPUT_WAV = "bolero_zelda_template.wav"

SR = 44100
TARGET_BPM = 108.0
SECS_PER_BEAT = 60.0 / TARGET_BPM

TRANSPOSE = -2  # C major → Bb major

THEME_A_BARS = (5, 12)
THEME_B_BARS = (41, 48)
GAP_SECS = 0.7


# ---------- 1. MIDI extraction (same approach as the plain template) ----------

def extract_notes(midi_path):
    mid = mido.MidiFile(midi_path)
    tpb = mid.ticks_per_beat
    track = mid.tracks[1]
    active, notes, t = {}, [], 0
    for msg in track:
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            active[msg.note] = t
        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            if msg.note in active:
                notes.append((active.pop(msg.note), t, msg.note))
    return notes, tpb


def slice_bars(notes, tpb, start_bar, end_bar):
    bar_ticks = tpb * 3
    return [(s, e, n) for (s, e, n) in notes
            if (start_bar - 1) * bar_ticks <= s < end_bar * bar_ticks]


def filter_ostinato(seq):
    out = []
    for i, (s, e, n) in enumerate(seq):
        if n != 67:
            out.append((s, e, n)); continue
        prev_g = i > 0 and seq[i - 1][2] == 67 and (s - seq[i - 1][0]) <= 192
        next_g = i < len(seq) - 1 and seq[i + 1][2] == 67 and (seq[i + 1][0] - s) <= 192
        if not (prev_g or next_g):
            out.append((s, e, n))
    return out


def to_score(notes, tpb, bar_offset_ticks, pitch_shift=0):
    score = []
    for s, e, n in notes:
        rel_s = s - bar_offset_ticks
        rel_e = e - bar_offset_ticks
        start_sec = (rel_s / tpb) * SECS_PER_BEAT
        dur_sec = max(0.05, ((rel_e - rel_s) / tpb) * SECS_PER_BEAT)
        score.append((start_sec, dur_sec, n + pitch_shift))
    return score


def section_duration(start_bar, end_bar):
    return (end_bar - start_bar + 1) * 3 * SECS_PER_BEAT


# ---------- 2. Mixolydian-flavor pass (mild) ----------

def mixolydian_flavor(score):
    """In Bb major after the -2 transpose, Boléro's B4(71)/B5(83) become
    A4(69)/A5(81) — the major 7th scale degree. Lower them to Ab (68/80)
    when they sit between scale-step neighbours (i.e. acting as a passing/
    upper-neighbour tone on the way to the tonic). This adds the subtle
    Mixolydian / "heroic-modal" colour without touching structural pitches.
    """
    out = list(score)
    pitches = [p for _, _, p in out]
    for i, (s, d, p) in enumerate(out):
        if p in (69, 81):
            prev_p = pitches[i - 1] if i > 0 else None
            next_p = pitches[i + 1] if i < len(pitches) - 1 else None
            # Only flatten if the note is a quick non-structural passing tone
            # (short duration, between a tonic-area note and another step).
            if d < 0.45 and prev_p is not None and next_p is not None:
                if abs(prev_p - p) <= 2 and abs(next_p - p) <= 2:
                    out[i] = (s, d, p - 1)
    return out


# ---------- 3. Synthesizers ----------

def midi_to_freq(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)


def adsr(n_samples, attack, decay, sustain, release, sr=SR):
    a = int(attack * sr); d = int(decay * sr); r = int(release * sr)
    while a + d + r > n_samples and (a + d + r) > 0:
        a = int(a * 0.7); d = int(d * 0.7); r = int(r * 0.7)
    s = max(0, n_samples - a - d - r)
    env = np.empty(n_samples, dtype=np.float32)
    if a > 0: env[:a] = np.linspace(0, 1, a, dtype=np.float32)
    if d > 0: env[a:a + d] = np.linspace(1, sustain, d, dtype=np.float32)
    if s > 0: env[a + d:a + d + s] = sustain
    if r > 0: env[a + d + s:] = np.linspace(sustain, 0, r, dtype=np.float32)
    return env


def horn_voice(freq, dur_sec, sr=SR):
    """Brassy / French-horn-like additive synth with soft saturation."""
    n = max(1, int(dur_sec * sr))
    t = np.arange(n, dtype=np.float32) / sr
    # vibrato: slower, deeper than flute
    vib = 0.0035 * np.clip((t - 0.18) / 0.35, 0, 1) * np.sin(2 * np.pi * 4.6 * t)
    phase = 2 * np.pi * np.cumsum(freq * (1 + vib)) / sr
    # rich harmonic stack — horn-like
    sig = (1.00 * np.sin(phase)
           + 0.55 * np.sin(2 * phase)
           + 0.32 * np.sin(3 * phase)
           + 0.18 * np.sin(4 * phase)
           + 0.10 * np.sin(5 * phase))
    # soft saturation for a brassier edge
    sig = np.tanh(1.4 * sig) * 0.85
    env = adsr(n, attack=0.045, decay=0.10, sustain=0.78, release=0.09)
    return (sig * env).astype(np.float32)


def harp_pluck(freq, dur_sec, sr=SR):
    """Decaying harp pluck via Karplus-Strong-flavored synthesis (additive
    sines with fast individual decays per harmonic)."""
    n = max(1, int(dur_sec * sr))
    t = np.arange(n, dtype=np.float32) / sr
    # 5 harmonics each with their own decay rate (higher = faster decay)
    sig = np.zeros(n, dtype=np.float32)
    for h, (amp, tau) in enumerate([(1.0, 1.4), (0.55, 1.0), (0.30, 0.7),
                                    (0.16, 0.45), (0.08, 0.30)], start=1):
        decay = np.exp(-t / tau)
        sig += amp * decay * np.sin(2 * np.pi * freq * h * t)
    # Short attack click (filtered noise) for pluck character
    rng = np.random.default_rng(int(freq * 13) & 0xFFFF)
    click = rng.standard_normal(int(0.008 * sr)).astype(np.float32)
    out = sig.copy()
    out[:len(click)] += click * 0.3
    # Quick fade at the end to avoid clicks
    fade = min(int(0.03 * sr), n)
    if fade > 0:
        out[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
    return (out * 0.45).astype(np.float32)


def string_pad(freq, dur_sec, sr=SR):
    """Soft sustaining strings: two slightly-detuned sawtooth voices, lowpass-y."""
    n = max(1, int(dur_sec * sr))
    t = np.arange(n, dtype=np.float32) / sr

    def saw(f):
        # band-limited-ish saw via summed sines (cheap)
        s = np.zeros(n, dtype=np.float32)
        for h in range(1, 9):
            s += (1.0 / h) * np.sin(2 * np.pi * f * h * t)
        return s

    sig = 0.55 * saw(freq * 0.997) + 0.55 * saw(freq * 1.003)
    # rolling-off the brightness
    k = 12
    if n > k:
        sig = np.convolve(sig, np.ones(k, dtype=np.float32) / k, mode="same")
    env = adsr(n, attack=0.30, decay=0.25, sustain=0.65, release=0.45)
    return (sig * env * 0.20).astype(np.float32)


# ---------- 4. Compose accompaniment ----------

def heroic_pickup_score(downbeat_sec):
    """Four-note ascending pickup leading into the Theme A downbeat:
    D5 - F5 - Bb5 (heroic Bb-major arpeggio rising 4th + 3rd).
    Lands on the downbeat 1 beat = SECS_PER_BEAT before downbeat_sec.
    """
    pickup_total = SECS_PER_BEAT * 1.5
    start = downbeat_sec - pickup_total
    notes = [
        (start + 0.0 * SECS_PER_BEAT, SECS_PER_BEAT * 0.45, 74),  # D5
        (start + 0.5 * SECS_PER_BEAT, SECS_PER_BEAT * 0.45, 77),  # F5
        (start + 1.0 * SECS_PER_BEAT, SECS_PER_BEAT * 0.5,  82),  # Bb5
    ]
    return notes


def harp_accompaniment(start_sec, end_sec, chord_plan):
    """Generate harp arpeggio events.

    chord_plan is a list of (start_sec, root_midi, chord_quality) where
    chord_quality is "maj", "min", or "dom". One rolled arpeggio per bar:
    root, 5th, octave, 3rd, 5th, octave (six 8th-notes across the bar).
    """
    notes = []
    bar_dur = 3 * SECS_PER_BEAT
    for ch_start, root, qual in chord_plan:
        # chord pitches relative to root
        if qual == "maj":  intervals = [0, 7, 12, 16, 19, 24]
        elif qual == "min": intervals = [0, 7, 12, 15, 19, 24]
        else:               intervals = [0, 7, 12, 16, 19, 24]
        for i, iv in enumerate(intervals):
            t = ch_start + i * (bar_dur / 6)
            d = bar_dur * 0.9  # let strings ring
            notes.append((t, d, root + iv))
    return notes


def pad_accompaniment(chord_plan):
    """Sustained-string pad: hold the chord triad across each bar."""
    notes = []
    bar_dur = 3 * SECS_PER_BEAT
    for ch_start, root, qual in chord_plan:
        third = 4 if qual == "maj" else 3
        triad = [root, root + third, root + 7]
        for p in triad:
            notes.append((ch_start, bar_dur * 0.95, p))
    return notes


def make_chord_plan(theme_offset_sec, num_bars):
    """Bb major: alternate I (Bb) and V (F) every 2 bars, with a vi (Gm)
    on bar 6 of the 8-bar phrase for a Zelda-typical emotional lift, then
    V back to I to close.
    Pattern: I I V V I vi V I  (over 8 bars)
    Roots in MIDI (one octave below the lead's range): Bb3=58, F3=53, G3=55
    """
    plan = []
    Bb, F, Gm = (58, "maj"), (53, "maj"), (55, "min")
    sequence = [Bb, Bb, F, F, Bb, Gm, F, Bb][:num_bars]
    for i, (root, q) in enumerate(sequence):
        plan.append((theme_offset_sec + i * 3 * SECS_PER_BEAT, root, q))
    return plan


# ---------- 5. Render mixer ----------

def render_voice(score, voice_fn, total_secs, gain=1.0):
    buf = np.zeros(int(total_secs * SR) + SR, dtype=np.float32)
    for start_sec, dur_sec, pitch in score:
        wave_arr = voice_fn(midi_to_freq(pitch), dur_sec)
        i0 = int(max(0, start_sec) * SR)
        i1 = i0 + len(wave_arr)
        if i1 > len(buf):
            wave_arr = wave_arr[: len(buf) - i0]
            i1 = len(buf)
        if i0 < 0: continue
        buf[i0:i1] += wave_arr * gain
    return buf


def write_wav(path, samples, sr=SR):
    peak = float(np.max(np.abs(samples))) or 1.0
    if peak > 1.0:
        samples = samples / peak * 0.92
    pcm = np.clip(samples * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(pcm.tobytes())


# ---------- main ----------

def main():
    notes, tpb = extract_notes(SOURCE_MIDI)
    bar_ticks = tpb * 3

    # --- Theme A ---
    a_raw = slice_bars(notes, tpb, *THEME_A_BARS)
    a_filt = filter_ostinato(a_raw)
    a_offset_ticks = (THEME_A_BARS[0] - 1) * bar_ticks
    a_score = to_score(a_filt, tpb, a_offset_ticks, pitch_shift=TRANSPOSE)
    a_score = mixolydian_flavor(a_score)
    a_dur = section_duration(*THEME_A_BARS)

    # --- Theme B ---
    b_raw = slice_bars(notes, tpb, *THEME_B_BARS)
    b_filt = filter_ostinato(b_raw)
    b_offset_ticks = (THEME_B_BARS[0] - 1) * bar_ticks
    b_score_local = to_score(b_filt, tpb, b_offset_ticks, pitch_shift=TRANSPOSE)
    b_dur = section_duration(*THEME_B_BARS)

    # Place sections on master timeline. Pickup adds 1.5 beats of lead-in.
    pickup_dur = 1.5 * SECS_PER_BEAT
    theme_a_start = pickup_dur
    theme_b_start = theme_a_start + a_dur + GAP_SECS

    pickup = heroic_pickup_score(theme_a_start)

    lead_score = (
        pickup
        + [(s + theme_a_start, d, p) for (s, d, p) in a_score]
        + [(s + theme_b_start, d, p) for (s, d, p) in b_score_local]
    )

    # Accompaniment chord plan covers both themes
    chord_plan_a = make_chord_plan(theme_a_start, num_bars=8)
    chord_plan_b = make_chord_plan(theme_b_start, num_bars=8)
    chord_plan = chord_plan_a + chord_plan_b

    harp_score = harp_accompaniment(theme_a_start, theme_b_start + b_dur, chord_plan)
    pad_score = pad_accompaniment(chord_plan)

    total = pickup_dur + a_dur + GAP_SECS + b_dur + 1.2

    print(f"Tempo {TARGET_BPM} BPM, key Bb major (Mixolydian-flavored)")
    print(f"Pickup: 3 notes lead-in ({pickup_dur:.2f}s)")
    print(f"Theme A: {len(a_score)} notes, {a_dur:.2f}s")
    print(f"Theme B: {len(b_score_local)} notes, {b_dur:.2f}s")
    print(f"Harp arpeggio events: {len(harp_score)}")
    print(f"String pad events: {len(pad_score)}")
    print(f"Total render: {total:.2f}s")

    lead = render_voice(lead_score, horn_voice, total, gain=1.00)
    harp = render_voice(harp_score, harp_pluck, total, gain=0.55)
    pad = render_voice(pad_score, string_pad, total, gain=1.00)

    mix = lead + harp + pad
    write_wav(OUTPUT_WAV, mix)
    print(f"Wrote {OUTPUT_WAV}")


if __name__ == "__main__":
    main()
