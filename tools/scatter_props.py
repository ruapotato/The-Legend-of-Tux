#!/usr/bin/env python3
"""Scatter trees and rocks across every outdoor dungeon. Reads the
walking-cell footprint of each level, picks N candidate cells, and
appends `tree` / `rock` props at those world positions to the JSON.
Existing props (signs, chests, bushes) are preserved.

Run from the project root:
    python3 tools/scatter_props.py
"""

import json
import math
import os
import random

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

# How many of each prop to drop per level. Indoor dungeons get nothing
# (rocks fine but trees feel weird inside). Outdoor levels get the full
# treatment.
TARGETS = {
    "sourceplain":   {"trees": 24, "rocks": 18},
    "wyrdkin_glade": {"trees":  6, "rocks":  4},
    "wyrdwood":      {"trees": 10, "rocks":  4},
    "mirelake":      {"trees":  8, "rocks":  6},
    "stoneroost":    {"trees":  6, "rocks": 10},
    "burnt_hollow":  {"trees":  5, "rocks": 12},
    "brookhold":     {"trees": 10, "rocks":  4},
    "hearthold":     {"trees":  0, "rocks":  3},
    "sigilkeep":     {"trees":  0, "rocks":  2},
    "dungeon_first": {"trees":  0, "rocks":  2},
}

EXCLUSION_RADIUS = 4.0   # don't drop a prop within this many meters
                         # of an existing entity / spawn / load_zone
TREE_TREE_MIN = 4.5      # minimum spacing between two trees
ROCK_ROCK_MIN = 2.5      # rocks can pack tighter than trees


def cell_world_center(c, cell_size):
    if isinstance(c, dict):
        i, j = int(c["i"]), int(c["j"])
    else:
        i, j = int(c[0]), int(c[1])
    return (
        (float(i) + 0.5) * cell_size,
        (float(j) + 0.5) * cell_size,
    )


def existing_no_go_points(data):
    """Return [(x, z, radius), ...] for everything we shouldn't drop a
    prop on top of: spawns, load_zones, doors, chests, signs, existing
    bushes, existing trees / rocks."""
    out = []
    for sp in data.get("spawns", []):
        p = sp.get("pos", [0, 0, 0])
        out.append((float(p[0]), float(p[2]), 2.5))
    for lz in data.get("load_zones", []):
        p = lz.get("pos", [0, 0, 0])
        sz = lz.get("size", [4, 3, 1.5])
        out.append((float(p[0]), float(p[2]),
                    max(float(sz[0]), float(sz[2])) * 0.6 + 1.0))
    for d in data.get("doors", []):
        p = d.get("pos", [0, 0, 0])
        out.append((float(p[0]), float(p[2]), 2.5))
    for pr in data.get("props", []):
        p = pr.get("pos", [0, 0, 0])
        radius = 1.5 if pr.get("type") in ("sign", "chest") else 2.0
        out.append((float(p[0]), float(p[2]), radius))
    return out


def scatter_one(level_id, target_trees, target_rocks):
    path = os.path.join(DUNGEONS, level_id + ".json")
    if not os.path.exists(path):
        return False, "missing"
    with open(path) as f:
        data = json.load(f)
    grid = data.get("grid")
    if not grid:
        return False, "no grid"
    cell_size = float(grid.get("cell_size", 1.0))
    candidates = []
    for floor in grid.get("floors", []):
        for c in floor.get("cells", []):
            cx, cz = cell_world_center(c, cell_size)
            candidates.append((cx, cz))
    if not candidates:
        return False, "no cells"

    # Shuffle deterministically per level so re-runs are stable.
    rng = random.Random(hash(level_id) & 0xFFFFFFFF)
    rng.shuffle(candidates)

    no_go = existing_no_go_points(data)
    placed_trees = []
    placed_rocks = []

    def try_place(cx, cz, kind):
        for nx, nz, nr in no_go:
            if math.hypot(cx - nx, cz - nz) < nr:
                return False
        if kind == "tree":
            for tx, tz in placed_trees:
                if math.hypot(cx - tx, cz - tz) < TREE_TREE_MIN:
                    return False
            for rx, rz in placed_rocks:
                if math.hypot(cx - rx, cz - rz) < TREE_TREE_MIN * 0.6:
                    return False
        else:
            for rx, rz in placed_rocks:
                if math.hypot(cx - rx, cz - rz) < ROCK_ROCK_MIN:
                    return False
            for tx, tz in placed_trees:
                if math.hypot(cx - tx, cz - tz) < TREE_TREE_MIN * 0.6:
                    return False
        return True

    props = data.setdefault("props", [])
    for cx, cz in candidates:
        if len(placed_trees) >= target_trees and len(placed_rocks) >= target_rocks:
            break
        # Alternate trees / rocks while both still need filling.
        if (len(placed_trees) < target_trees
                and (len(placed_rocks) >= target_rocks
                     or rng.random() < 0.6)):
            if try_place(cx, cz, "tree"):
                placed_trees.append((cx, cz))
                props.append({
                    "type": "tree",
                    "pos": [round(cx, 2), 0.0, round(cz, 2)],
                    "rotation_y": rng.uniform(-3.14, 3.14),
                    "pebble_chance": rng.choice([0.20, 0.30, 0.30, 0.45]),
                    "trunk_height": rng.uniform(3.5, 5.5),
                    "canopy_radius": rng.uniform(1.4, 2.1),
                })
        elif len(placed_rocks) < target_rocks:
            if try_place(cx, cz, "rock"):
                placed_rocks.append((cx, cz))
                props.append({
                    "type": "rock",
                    "pos": [round(cx, 2), 0.5, round(cz, 2)],
                    "pebble_chance": rng.choice([0.30, 0.40, 0.55]),
                })

    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return True, "trees=%d rocks=%d" % (len(placed_trees), len(placed_rocks))


def main():
    for lvl, t in TARGETS.items():
        ok, info = scatter_one(lvl, t["trees"], t["rocks"])
        print("%-18s  %s" % (lvl, info if ok else ("skip: " + info)))


if __name__ == "__main__":
    main()
