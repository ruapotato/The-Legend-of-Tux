#!/usr/bin/env python3
"""For every load_zone that targets a `from_<src>` spawn, ensure the
destination level has that spawn id. Picks a reasonable spawn position
near the destination's centre. Idempotent."""

import json
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


def main():
    levels = {}
    for fn in sorted(os.listdir(DUNGEONS)):
        if not fn.endswith(".json"): continue
        levels[fn[:-5]] = (fn, json.load(open(os.path.join(DUNGEONS, fn))))

    edits = 0
    for src_id, (src_fn, src) in levels.items():
        for lz in src.get("load_zones", []):
            dst = lz.get("target_scene")
            spawn = lz.get("target_spawn")
            if not dst or not spawn:
                continue
            if dst not in levels:
                continue
            dst_fn, dst_data = levels[dst]
            if any(s.get("id") == spawn for s in dst_data.get("spawns", [])):
                continue
            # Pick a position near dst's footprint centre.
            grid = dst_data.get("grid", {})
            cs = float(grid.get("cell_size", 1.0))
            cells = grid.get("floors", [{}])[0].get("cells", [])
            if cells:
                xs = [int(c[0]) for c in cells]
                zs = [int(c[1]) for c in cells]
                cx = ((min(xs) + max(xs) + 1) * 0.5) * cs
                cz = ((min(zs) + max(zs) + 1) * 0.5) * cs
            else:
                cx, cz = 0.0, 0.0
            dst_data.setdefault("spawns", []).append({
                "id": spawn,
                "pos": [round(cx, 2), 0.5, round(cz, 2)],
                "rotation_y": 0.0,
            })
            edits += 1

    for level_id, (fn, data) in levels.items():
        with open(os.path.join(DUNGEONS, fn), "w") as f:
            json.dump(data, f, indent=2)
    print("added %d back-spawns" % edits)


if __name__ == "__main__":
    main()
