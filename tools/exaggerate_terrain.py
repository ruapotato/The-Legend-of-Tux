#!/usr/bin/env python3
"""Pump up the hills + add deliberate elevation features so the
outdoor levels actually read as terrain instead of subtle wobble.
The refinement pass kept y_offs in a quiet ±1.6 range; this raises
the amplitude on existing y_offs and stamps in additional dramatic
features (a few proper hills + valleys per outdoor level).

Run from project root:
    python3 tools/exaggerate_terrain.py
"""

import json
import math
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

# Outdoor levels — these get pumped. Indoor (dungeon_first, hearthold,
# sigilkeep) stay flat by design.
OUTDOOR = ["sourceplain", "wyrdkin_glade", "wyrdwood", "mirelake",
           "stoneroost", "burnt_hollow", "brookhold"]

# Per-level dramatic features: list of (cx, cz, radius, amplitude).
# cx/cz are world meters, radius is meters of falloff, amplitude is
# peak y_off (positive = hill, negative = valley).
FEATURES = {
    "sourceplain": [
        (  0,   0, 14, 3.5),    # central monolith plateau (taller)
        ( 30, -40, 18, 4.2),    # north-east hill
        (-45, -10, 16, 3.0),    # west bluff
        ( 50,  35, 14, 2.6),    # south-east mound
        (-30,  40, 12, 2.0),
        ( 20,  60, 10, 1.6),
        ( 60,   0,  9,-1.4),    # east depression
        (-15, -55, 10,-1.6),    # north sunken meadow
        ( 15,  20,  8,-1.0),
    ],
    "burnt_hollow": [
        (50, 50, 16, 4.5),
        (30, 25, 12, 3.2),
        (75, 35, 10,-2.5),       # central caldera deeper
        (15, 60, 12, 2.4),
        (40, 80, 14, 3.0),
    ],
    "stoneroost": [
        (10, -10, 14, 5.0),     # main summit
        (-5,  20, 10, 2.4),
        ( 18,   5,  8, 1.6),
        (-15,  10, 10, 3.0),
    ],
    "mirelake": [
        (  0, -20, 12, 2.4),    # north peninsula bluff
        ( 15,  15,  9, 1.6),    # rotunda island bump
        (-15,  20,  8, 1.4),
        (  0,  40,  6,-1.6),    # drowned shrine sink
        ( 25,  -5, 10,-1.0),
    ],
    "wyrdkin_glade": [
        ( -6,  -2,  7, 2.0),    # gentle hill on glade west
        (  4,   4,  5, 1.5),
    ],
    "wyrdwood": [
        ( -5, -15,  8, 2.6),    # hill to navigate around
        (  5,  -2,  6, 1.8),
        (  0,   3,  4,-0.8),    # small dell
    ],
    "brookhold": [
        ( 0, -15,  8, 1.8),
        ( 0,  15,  8, 1.8),
        (15,   0,  6, 1.4),
    ],
}

NOISE_PHASE = 0.0


def smoothstep(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def parse_cell(c):
    """Returns (i, j, y_off, color) — y_off and color may be None."""
    if isinstance(c, dict):
        return (int(c["i"]), int(c["j"]),
                float(c["y"]) if "y" in c else None,
                c.get("color"))
    i = int(c[0]); j = int(c[1])
    y = float(c[2]) if len(c) >= 3 and c[2] is not None else None
    col = c[3] if len(c) >= 4 else None
    return (i, j, y, col)


def emit_cell(i, j, y, col):
    if y is None and col is None:
        return [i, j]
    if col is None:
        return [i, j, y]
    return [i, j, y if y is not None else 0.0, col]


def sample_features(features, cx, cz):
    """Returns the maximum-magnitude feature offset at (cx, cz).
    Picks the dominant feature rather than summing so overlapping
    features don't pile up to absurd heights."""
    best = 0.0
    for (fx, fz, fr, amp) in features:
        d = math.hypot(cx - fx, cz - fz)
        if d >= fr:
            continue
        falloff = math.cos(d / fr * math.pi * 0.5)
        offset = amp * falloff * falloff   # squared cosine for plateau-ish tops
        if abs(offset) > abs(best):
            best = offset
    return best


def process(level_id):
    path = os.path.join(DUNGEONS, level_id + ".json")
    if not os.path.exists(path):
        return False, "missing"
    with open(path) as f:
        data = json.load(f)
    grid = data.get("grid")
    if not grid:
        return False, "no grid"
    cs = float(grid.get("cell_size", 1.0))
    feats = FEATURES.get(level_id, [])
    for floor in grid.get("floors", []):
        new_cells = []
        for c in floor.get("cells", []):
            i, j, y, col = parse_cell(c)
            cx = (float(i) + 0.5) * cs
            cz = (float(j) + 0.5) * cs
            base = (y if y is not None else 0.0) * 1.4    # bump existing hills
            feat = sample_features(feats, cx, cz)
            ny = base + feat
            if abs(ny) < 0.01:
                ny = None
            new_cells.append(emit_cell(i, j, ny, col))
        floor["cells"] = new_cells
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return True, "ok"


def main():
    for lvl in OUTDOOR:
        ok, msg = process(lvl)
        print("%-18s  %s" % (lvl, msg))


if __name__ == "__main__":
    main()
