"""Inspect the downloaded Boléro MIDI to find Theme A and Theme B note sequences."""
import mido

mid = mido.MidiFile("bolero_source.mid")
print(f"ticks_per_beat={mid.ticks_per_beat}, length={mid.length:.1f}s, tracks={len(mid.tracks)}")

# Walk all tracks, gather (track_idx, abs_tick, type, note, velocity, channel)
def collect(mid):
    events = []
    for ti, track in enumerate(mid.tracks):
        t = 0
        for msg in track:
            t += msg.time
            if msg.type in ("note_on", "note_off"):
                events.append((ti, t, msg.type, msg.note, getattr(msg, "velocity", 0), msg.channel))
            elif msg.type == "set_tempo":
                events.append((ti, t, "tempo", msg.tempo, 0, -1))
            elif msg.type == "time_signature":
                events.append((ti, t, "timesig", (msg.numerator, msg.denominator), 0, -1))
            elif msg.type == "program_change":
                events.append((ti, t, "program", msg.program, 0, msg.channel))
            elif msg.type == "key_signature":
                events.append((ti, t, "key", msg.key, 0, -1))
    return events

events = collect(mid)

# Print meta and program info
print("\n-- meta/program events --")
for e in events:
    if e[2] in ("tempo", "timesig", "program", "key"):
        print(e)

# Per-track note count
from collections import Counter
counts = Counter()
for e in events:
    if e[2] == "note_on" and e[4] > 0:
        counts[e[0]] += 1
print("\n-- note_on counts per track --", counts)

# Show first ~80 notes from each track
for ti in sorted(counts):
    print(f"\n-- track {ti} first notes --")
    notes = [(t, n) for (idx, t, ty, n, v, c) in events if idx == ti and ty == "note_on" and v > 0]
    for t, n in notes[:80]:
        names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        name = names[n%12] + str(n//12 - 1)
        print(f"  t={t:6d}  midi={n}  name={name}")
