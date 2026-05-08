#!/usr/bin/env python3
"""One-shot reshape of outdoor levels into irregular cell-painted
shapes with auto-derived tree-wall borders. Run from project root.

After this:
- sourceplain keeps the agent's irregular footprint but switches to
  has_walls + tree material (so the perimeter and any internal no-cell
  pockets become tree thickets you can't walk off the edge of).
- wyrdkin_glade is reshaped from a 16×16 rectangle into an organic
  teardrop clearing with carved-out forest clumps.
- wyrdwood is reshaped from a 16×22 rectangle into a winding forest
  trail with a north entry blob, a curving main path, an east spur to
  the dungeon, and a south stub to the sourceplain bridge.
- brookhold's yard floor gets a tree-wall border so the open lanes
  no longer drop off into the void.
"""

import json
import math
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")
CS       = 2.0


def _save(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def reshape_sourceplain():
    p = os.path.join(DUNGEONS, "sourceplain.json")
    with open(p) as f:
        d = json.load(f)
    f0 = d["grid"]["floors"][0]
    f0["has_walls"] = True
    f0["wall_material"] = "tree"
    # Auto-derived tree borders replace the legacy explicit polylines.
    d.pop("tree_walls", None)
    _save(p, d)
    return len(f0["cells"])


def reshape_glade():
    """Organic teardrop glade with two interior thickets carved out."""
    rx, rz = 8, 12
    cells = set()
    for i in range(-rx - 1, rx + 2):
        for j in range(-rz - 1, rz + 2):
            cx, cz = i + 0.5, j + 0.5
            nx, nz = cx / rx, cz / rz
            noise = (math.sin(cx * 1.7) * math.cos(cz * 1.3) * 0.15
                   + math.sin(cx * 0.9 + cz * 0.7) * 0.10)
            if nx * nx + nz * nz < 1.0 + noise:
                cells.add((i, j))
    # Carve interior thickets.
    clumps = [(-3, -2, 1.5), (4, 4, 1.4)]
    cells = {(i, j) for (i, j) in cells
             if all(math.hypot(i + 0.5 - cx, j + 0.5 - cz) > r
                    for cx, cz, r in clumps)}
    # Spawn / load-zone anchor cells must exist regardless of carving.
    required = [(0, 3), (0, -6), (0, -7)]
    cells.update(required)

    p = os.path.join(DUNGEONS, "wyrdkin_glade.json")
    with open(p) as f:
        d = json.load(f)
    f0 = d["grid"]["floors"][0]
    f0["cells"] = [[i, j] for (i, j) in sorted(cells)]
    f0["has_walls"] = True
    f0["wall_material"] = "tree"
    d.pop("tree_walls", None)
    _save(p, d)
    return len(cells)


def reshape_wyrdwood():
    """Winding north–south trail with branches to glade, dungeon, plain."""
    cells = set()
    # North entry / arrival from glade.
    for i in range(-4, 4):
        for j in range(5, 8):
            cells.add((i, j))
    # Winding main trail south, ~6 cells wide, sin-curved center.
    for j in range(-13, 6):
        center_i = math.sin(j * 0.42) * 2.5
        half = 3
        for i in range(int(center_i) - half, int(center_i) + half + 1):
            cells.add((i, j))
    # East spur leading to the Hollow.
    for i in range(-3, 8):
        for j in range(-14, -12):
            cells.add((i, j))
    # South stub leading to sourceplain bridge.
    for i in range(-4, 4):
        for j in range(-15, -13):
            cells.add((i, j))
    # Interior thickets to break up the trail.
    clumps = [(2, -5, 1.4), (-3, -8, 1.5), (4, -2, 1.1), (-2, 1, 1.0)]
    cells = {(i, j) for (i, j) in cells
             if all(math.hypot(i + 0.5 - cx, j + 0.5 - cz) > r
                    for cx, cz, r in clumps)}
    # Spawn / lz anchors.
    required = [(0, 6), (0, -14), (6, -13), (0, 7), (7, -14), (0, -15)]
    cells.update(required)

    p = os.path.join(DUNGEONS, "wyrdwood.json")
    with open(p) as f:
        d = json.load(f)
    f0 = d["grid"]["floors"][0]
    f0["cells"] = [[i, j] for (i, j) in sorted(cells)]
    f0["has_walls"] = True
    f0["wall_material"] = "tree"
    d.pop("tree_walls", None)
    _save(p, d)
    return len(cells)


def update_brookhold_yard():
    p = os.path.join(DUNGEONS, "brookhold.json")
    with open(p) as f:
        d = json.load(f)
    changed = 0
    for f0 in d["grid"]["floors"]:
        if f0.get("name") == "yard":
            f0["has_walls"] = True
            f0["wall_material"] = "tree"
            changed += 1
    _save(p, d)
    return changed


if __name__ == "__main__":
    print("sourceplain:    %d cells, tree-walled" % reshape_sourceplain())
    print("wyrdkin_glade:  %d cells, organic glade" % reshape_glade())
    print("wyrdwood:       %d cells, winding trail" % reshape_wyrdwood())
    print("brookhold:      yard tree-walled (%d floor)" % update_brookhold_yard())
