"""Extract Theme A and Theme B melodic lines from the MIDI.

The MIDI has the snare-drum-style ostinato (rapid G4s) interleaved with the melody.
Theme A starts at bar 5 (after 4-bar intro). Each theme = 18 bars in 3/4.
ticks_per_beat=384, so 1 bar = 1152 ticks.
"""
import mido

mid = mido.MidiFile("bolero_source.mid")
TPB = mid.ticks_per_beat  # 384
BAR = TPB * 3  # 1152

names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
def nm(n): return f"{names[n%12]}{n//12 - 1}"

# Collect note_on events with abs tick (only velocity > 0)
notes = []
t = 0
for msg in mid.tracks[1]:
    t += msg.time
    if msg.type == "note_on" and msg.velocity > 0:
        notes.append((t, msg.note))

# Theme A starts at bar 5 (t = 4*BAR = 4608) — first non-G4 note is C5 there.
# Theme B starts after Theme A is played twice (bars 5..40 → t = 4*BAR through t = 40*BAR).
# Per Wikipedia: each theme 18 bars, played twice alternately. So:
#   bars 5-22  = Theme A (1st)
#   bars 23-40 = Theme A (2nd)
#   bars 41-58 = Theme B (1st)
#   bars 59-76 = Theme B (2nd)
#   then repeat A,A,B,B,A,A,B,B etc.

def slice_bars(start_bar, end_bar):
    lo = (start_bar - 1) * BAR
    hi = (end_bar) * BAR  # exclusive
    return [(t, n) for (t, n) in notes if lo <= t < hi]

theme_a_first = slice_bars(5, 22)   # bars 5..22 inclusive
theme_b_first = slice_bars(41, 58)

# The ostinato is mostly G4 (and F4 etc — actually it's two snare-rhythms but the
# flute MIDI fakes it with G4 repetitions). Filter those out: any note whose
# pitch is G4 (67) AND whose duration in ticks is short (< 96 = 16th note) AND
# is in a fast pattern. Simpler: drop all G4 in the early ostinato section, but
# also drop G4 notes when they appear back-to-back at high density.

def filter_ostinato(seq):
    # Drop runs of G4 that appear in the rapid ostinato pattern.
    # The ostinato G4s come in clusters with very short gaps (<= 96 ticks ~ 16th).
    # Real melodic G4 in the theme is preceded/followed by other pitches with
    # more typical gaps. Heuristic: drop a G4 if the previous AND next notes
    # within 96 ticks are also G4 (forming a dense G4 cluster).
    out = []
    for i, (t, n) in enumerate(seq):
        if n != 67:
            out.append((t, n))
            continue
        # G4 — check if it's part of a cluster of G4s
        prev_g = i > 0 and seq[i-1][1] == 67 and (t - seq[i-1][0]) <= 192
        next_g = i < len(seq)-1 and seq[i+1][1] == 67 and (seq[i+1][0] - t) <= 192
        if prev_g or next_g:
            continue  # ostinato
        out.append((t, n))
    return out

a = filter_ostinato(theme_a_first)
b = filter_ostinato(theme_b_first)

print(f"Theme A first statement: {len(theme_a_first)} raw, {len(a)} after ostinato filter")
print(f"Theme B first statement: {len(theme_b_first)} raw, {len(b)} after ostinato filter")

def show(seq, label):
    print(f"\n=== {label} ===")
    for i, (t, n) in enumerate(seq):
        bar = t // BAR + 1
        beat = (t % BAR) / TPB
        print(f"  bar {bar:2d} beat {beat:5.2f}  t={t:6d}  {nm(n):4s} ({n})")

show(a, "Theme A — first statement")
show(b, "Theme B — first statement")
