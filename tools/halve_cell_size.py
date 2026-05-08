#!/usr/bin/env python3
"""Halve the cell size of every dungeon (cell_size 2.0 → 1.0) without
shrinking the worlds. Each old cell becomes a 2×2 block of new cells
with the same y_offset / color so the resulting geometry is identical
in world space — just at twice the resolution. Future edits in the
editor can then vary the four sub-cells independently for finer
detail (paths, raised tiles, dirt patches, etc.).

Run from the project root:
    python3 tools/halve_cell_size.py
"""

import json
import os
import sys

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


def split_cell(c):
    """Yield 4 sub-cells covering the same world rect as the input,
    preserving any y_offset / color override."""
    if isinstance(c, dict):
        ci = int(c["i"]); cj = int(c["j"])
        y_off = c.get("y", None)
        color = c.get("color", None)
    else:
        ci = int(c[0]); cj = int(c[1])
        y_off = c[2] if len(c) >= 3 else None
        color = c[3] if len(c) >= 4 else None

    for di in (0, 1):
        for dj in (0, 1):
            ni = ci * 2 + di
            nj = cj * 2 + dj
            if y_off is None and color is None:
                yield [ni, nj]
            elif color is None:
                yield [ni, nj, y_off]
            else:
                yield [ni, nj, y_off if y_off is not None else 0.0, color]


def halve(data):
    grid = data.get("grid")
    if not grid:
        return False, "no grid"
    if abs(float(grid.get("cell_size", 2.0)) - 2.0) > 0.001:
        return False, "cell_size not 2.0"
    grid["cell_size"] = 1.0
    for floor in grid.get("floors", []):
        old_cells = floor.get("cells", [])
        new_cells = []
        for c in old_cells:
            new_cells.extend(split_cell(c))
        floor["cells"] = new_cells
    return True, "ok"


def main():
    paths = sorted(
        os.path.join(DUNGEONS, f) for f in os.listdir(DUNGEONS)
        if f.endswith(".json")
    )
    targets = set(sys.argv[1:])
    for p in paths:
        if targets and os.path.basename(p).rsplit(".", 1)[0] not in targets:
            continue
        with open(p) as f:
            data = json.load(f)
        before = sum(len(f.get("cells", []))
                     for f in data.get("grid", {}).get("floors", []))
        ok, msg = halve(data)
        if ok:
            with open(p, "w") as f:
                json.dump(data, f, indent=2)
            after = sum(len(f.get("cells", []))
                        for f in data.get("grid", {}).get("floors", []))
            print("halved   %-22s  %d → %d cells"
                  % (os.path.basename(p), before, after))
        else:
            print("skipped  %-22s  %s" % (os.path.basename(p), msg))


if __name__ == "__main__":
    main()
