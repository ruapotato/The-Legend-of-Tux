"""Render a Boléro melodic template (Theme A → Theme B) as a flute-like WAV.

Pulls the melody from the actual flutetunes MIDI of Ravel's Boléro:
- Theme A: bars 5-12 (first 8 bars of the diatonic theme starting on C5)
- Theme B: bars 41-48 (first 8 bars of the chromatic Phrygian-mode theme)

Filters out the snare-drum-style G4 ostinato that's mixed into the same flute
track in this MIDI arrangement. Synthesizes a soft flute-like timbre with
vibrato and ADSR envelope. Output: 44.1 kHz mono WAV, ~30 seconds.

Tempo is sped up to ~96 BPM (vs. Ravel's 72 BPM marking) so 8 bars of each
theme fit in the requested 30-second budget while staying recognizable.
"""
import math
import struct
import wave
import mido
import numpy as np

SOURCE_MIDI = "bolero_source.mid"
OUTPUT_WAV = "bolero_melody_template.wav"

SR = 44100
TARGET_BPM = 96.0
SECS_PER_BEAT = 60.0 / TARGET_BPM

# Bars to include (1-indexed, matching the MIDI's bar numbering)
THEME_A_BARS = (5, 12)
THEME_B_BARS = (41, 48)
GAP_SECS = 0.6  # silence between A and B


# ---------- 1. Parse MIDI and extract melody notes ----------

def extract_notes(midi_path):
    """Return list of (start_tick, end_tick, pitch) note events from track 1."""
    mid = mido.MidiFile(midi_path)
    tpb = mid.ticks_per_beat
    track = mid.tracks[1]

    active = {}      # pitch -> start_tick
    notes = []
    t = 0
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
    lo = (start_bar - 1) * bar_ticks
    hi = end_bar * bar_ticks
    return [(s, e, n) for (s, e, n) in notes if lo <= s < hi]


def filter_ostinato(seq):
    """Drop the rapid G4 ostinato; keep the melody.

    The ostinato is dense back-to-back G4s. A real melodic G4 is flanked
    by other pitches (or sits with a long duration). Heuristic: drop a G4
    iff its immediate neighbour (within 192 ticks ~ 8th note) is also G4.
    """
    out = []
    for i, (s, e, n) in enumerate(seq):
        if n != 67:
            out.append((s, e, n))
            continue
        prev_g = i > 0 and seq[i - 1][2] == 67 and (s - seq[i - 1][0]) <= 192
        next_g = i < len(seq) - 1 and seq[i + 1][2] == 67 and (seq[i + 1][0] - s) <= 192
        if not (prev_g or next_g):
            out.append((s, e, n))
    return out


# ---------- 2. Build the timed score ----------

def to_score(notes, tpb, bar_offset_ticks):
    """Convert (start, end, pitch) tick events into (start_sec, dur_sec, pitch)
    relative to the start of the slice, at TARGET_BPM."""
    score = []
    for s, e, n in notes:
        rel_s = s - bar_offset_ticks
        rel_e = e - bar_offset_ticks
        start_sec = (rel_s / tpb) * SECS_PER_BEAT
        dur_sec = max(0.05, ((rel_e - rel_s) / tpb) * SECS_PER_BEAT)
        score.append((start_sec, dur_sec, n))
    return score


def section_duration(notes, tpb, start_bar, end_bar):
    bar_ticks = tpb * 3
    section_ticks = (end_bar - start_bar + 1) * bar_ticks
    return (section_ticks / tpb) * SECS_PER_BEAT


# ---------- 3. Flute-like synthesizer ----------

def midi_to_freq(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)


def adsr(n_samples, attack, decay, sustain, release, sr=SR):
    """Build an ADSR envelope of length n_samples.

    attack/decay/release in seconds; sustain is amplitude 0..1.
    Release is taken from the END of the note (not added on top), to keep
    the note bounded inside its scheduled duration.
    """
    a = int(attack * sr)
    d = int(decay * sr)
    r = int(release * sr)
    # clamp so a+d+r doesn't exceed n_samples
    while a + d + r > n_samples and (a + d + r) > 0:
        a = int(a * 0.7); d = int(d * 0.7); r = int(r * 0.7)
    s = max(0, n_samples - a - d - r)
    env = np.empty(n_samples, dtype=np.float32)
    if a > 0:
        env[:a] = np.linspace(0.0, 1.0, a, dtype=np.float32)
    if d > 0:
        env[a:a + d] = np.linspace(1.0, sustain, d, dtype=np.float32)
    if s > 0:
        env[a + d:a + d + s] = sustain
    if r > 0:
        env[a + d + s:] = np.linspace(sustain, 0.0, r, dtype=np.float32)
    return env


def synth_note(freq, dur_sec, sr=SR):
    """Soft flute-like timbre: fundamental + small octave harmonic + breath noise,
    with delayed vibrato and ADSR envelope."""
    n = max(1, int(dur_sec * sr))
    t = np.arange(n, dtype=np.float32) / sr

    # Vibrato: 5.2 Hz, depth ramps in after 120 ms so short notes stay clean
    vib_freq = 5.2
    vib_depth = 0.0028  # ~5 cents at full depth
    ramp = np.clip((t - 0.12) / 0.30, 0.0, 1.0)
    vib = vib_depth * ramp * np.sin(2 * np.pi * vib_freq * t)

    # Phase = integral of instantaneous frequency
    inst_freq = freq * (1.0 + vib)
    phase = 2 * np.pi * np.cumsum(inst_freq) / sr

    # Additive: fundamental + 2nd harmonic (octave) + tiny 3rd
    sig = (1.00 * np.sin(phase)
           + 0.18 * np.sin(2 * phase)
           + 0.06 * np.sin(3 * phase))

    # Breath noise (lowpassed-ish via simple smoothing), proportional to envelope
    rng = np.random.default_rng(int(freq * 100) & 0xFFFF)
    noise = rng.standard_normal(n).astype(np.float32)
    # crude lowpass: 4-tap moving average
    k = 8
    if n > k:
        noise = np.convolve(noise, np.ones(k, dtype=np.float32) / k, mode="same")
    sig = sig + 0.04 * noise

    env = adsr(n, attack=0.04, decay=0.06, sustain=0.85, release=0.08)
    return (sig * env).astype(np.float32)


# ---------- 4. Render score onto a buffer ----------

def render(score, total_secs, sr=SR):
    buf = np.zeros(int(total_secs * sr) + sr, dtype=np.float32)
    for start_sec, dur_sec, pitch in score:
        f = midi_to_freq(pitch)
        wave = synth_note(f, dur_sec, sr)
        i0 = int(start_sec * sr)
        i1 = i0 + len(wave)
        if i1 > len(buf):
            wave = wave[:len(buf) - i0]
            i1 = len(buf)
        buf[i0:i1] += wave
    return buf


def write_wav(path, samples, sr=SR):
    peak = float(np.max(np.abs(samples))) or 1.0
    samples = samples / peak * 0.85
    pcm = np.clip(samples * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


# ---------- main ----------

def main():
    notes, tpb = extract_notes(SOURCE_MIDI)
    bar_ticks = tpb * 3

    # Theme A
    a_raw = slice_bars(notes, tpb, *THEME_A_BARS)
    a_notes = filter_ostinato(a_raw)
    a_offset = (THEME_A_BARS[0] - 1) * bar_ticks
    a_score = to_score(a_notes, tpb, a_offset)
    a_dur = section_duration(notes, tpb, *THEME_A_BARS)

    # Theme B (offset placement onto the timeline after Theme A + gap)
    b_raw = slice_bars(notes, tpb, *THEME_B_BARS)
    b_notes = filter_ostinato(b_raw)
    b_offset = (THEME_B_BARS[0] - 1) * bar_ticks
    b_score_local = to_score(b_notes, tpb, b_offset)
    b_dur = section_duration(notes, tpb, *THEME_B_BARS)

    section_offset_b = a_dur + GAP_SECS
    score = list(a_score) + [(s + section_offset_b, d, n) for (s, d, n) in b_score_local]
    total = a_dur + GAP_SECS + b_dur + 0.8  # tail

    print(f"tempo: {TARGET_BPM} BPM")
    print(f"Theme A: bars {THEME_A_BARS[0]}-{THEME_A_BARS[1]}, {len(a_score)} notes, {a_dur:.2f}s")
    print(f"Theme B: bars {THEME_B_BARS[0]}-{THEME_B_BARS[1]}, {len(b_score_local)} notes, {b_dur:.2f}s")
    print(f"Total render: {total:.2f}s")

    buf = render(score, total)
    write_wav(OUTPUT_WAV, buf)
    print(f"Wrote {OUTPUT_WAV}")


if __name__ == "__main__":
    main()
