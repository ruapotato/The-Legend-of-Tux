#!/usr/bin/env python3
"""Add a parent-directory load_zone to each existing level so the
filesystem is fully navigable. Each existing level currently only
links to its old peers (e.g. wyrdkin_glade → wyrdwood). After this
they also link "up" to their parent directory, completing the FHS.

Idempotent: reruns skip levels that already have a parent zone.
"""

import json
import math
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

# (existing_level_id, parent_id, parent_friendly_name)
PARENTS = [
    ("wyrdkin_glade", "wyrdmark_gateway", "Wyrdmark Gateway"),
    ("wyrdwood",      "wyrdmark_gateway", "Wyrdmark Gateway"),
    ("sourceplain",   "wyrdmark_gateway", "Wyrdmark Gateway"),
    ("hearthold",     "burrows",          "the Burrows"),
    ("brookhold",     "burrows",          "the Burrows"),
    ("sigilkeep",     "scriptorium",      "the Scriptorium"),
    ("dungeon_first", "cache_wyrdmark",   "Wyrdmark Records"),
    ("stoneroost",    "wyrdmark_mounts",  "Wyrdmark Mounts"),
    ("mirelake",      "backwater",        "the Backwater"),
    ("burnt_hollow",  "drift",            "the Drift"),
]


def add_parent_zone(level_id: str, parent_id: str, parent_name: str) -> str:
    path = os.path.join(DUNGEONS, level_id + ".json")
    if not os.path.exists(path):
        return "missing"
    with open(path) as f:
        data = json.load(f)
    lz_list = data.setdefault("load_zones", [])
    spawns  = data.setdefault("spawns",     [])
    # Skip if there's already a zone targeting this parent.
    for lz in lz_list:
        if lz.get("target_scene") == parent_id:
            return "already wired"

    # Pick a free spot on the perimeter. Strategy: scan an outward
    # arc starting north and step around the compass; pick the first
    # angle whose proposed zone doesn't sit within 6m of an existing
    # zone.
    grid = data.get("grid", {})
    cell_size = float(grid.get("cell_size", 1.0))
    floors = grid.get("floors", [])
    if not floors:
        return "no grid"
    # Bounding box of the walking footprint.
    cells = floors[0].get("cells", [])
    if not cells:
        return "no cells"
    xs = [int(c[0]) for c in cells]
    zs = [int(c[1]) for c in cells]
    min_x = min(xs) * cell_size; max_x = (max(xs) + 1) * cell_size
    min_z = min(zs) * cell_size; max_z = (max(zs) + 1) * cell_size
    cx = (min_x + max_x) * 0.5
    cz = (min_z + max_z) * 0.5
    # Outward radius — just beyond the shorter half-extent so the zone
    # sits at the level's edge rather than the middle.
    r = min((max_x - min_x), (max_z - min_z)) * 0.5 - 1.0

    candidates = []
    for k in range(8):
        angle = math.radians(-90 + k * 45)
        x = round(cx + math.cos(angle) * r, 2)
        z = round(cz + math.sin(angle) * r, 2)
        candidates.append((x, z, angle))

    def too_close(x, z):
        for lz in lz_list:
            p = lz.get("pos", [0, 0, 0])
            if math.hypot(x - float(p[0]), z - float(p[2])) < 8.0:
                return True
        return False

    chosen = None
    for x, z, ang in candidates:
        if not too_close(x, z):
            chosen = (x, z, ang)
            break
    if chosen is None:
        chosen = candidates[0]
    x, z, ang = chosen

    # Thin axis points outward; align the zone box accordingly.
    if abs(math.cos(ang)) > abs(math.sin(ang)):
        size = [1.5, 3.0, 4.0]
    else:
        size = [4.0, 3.0, 1.5]

    lz_list.append({
        "pos": [x, 1.4, z],
        "size": size,
        "rotation_y": 0.0,
        "target_scene": parent_id,
        "target_spawn": "from_" + level_id,
        "prompt": "[E] Up to %s" % parent_name,
    })

    # Add a from_<parent> spawn marker so coming back here lands
    # cleanly. Use a position just inside the level from the zone.
    spawn_x = round(x - math.cos(ang) * 2.0, 2)
    spawn_z = round(z - math.sin(ang) * 2.0, 2)
    spawn_id = "from_" + parent_id
    if not any(s.get("id") == spawn_id for s in spawns):
        spawns.append({
            "id": spawn_id,
            "pos": [spawn_x, 0.5, spawn_z],
            "rotation_y": math.atan2(-math.cos(ang), -math.sin(ang)) - math.pi * 0.5,
        })

    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return "wired (%.1f, %.1f)" % (x, z)


def main():
    for level_id, parent_id, parent_name in PARENTS:
        result = add_parent_zone(level_id, parent_id, parent_name)
        print("%-15s -> %-20s  %s" % (level_id, parent_id, result))


if __name__ == "__main__":
    main()
