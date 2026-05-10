#!/usr/bin/env python3
"""Quick graph integrity check across dungeons/*.json:
 - count levels and load_zones
 - find orphan target_scenes (zone targets a non-existent level)
 - find missing back-spawns (lz says target_spawn=X but dst lacks spawn id X)
 - find one-way edges (target dst has no zone back to src)
"""

import json
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


def main():
    levels = {}
    for fn in sorted(os.listdir(DUNGEONS)):
        if fn.endswith(".json"):
            levels[fn[:-5]] = json.load(open(os.path.join(DUNGEONS, fn)))

    total_lz = 0
    orphans = 0
    missing_spawns = 0
    one_way = 0
    for src, data in levels.items():
        for lz in data.get("load_zones", []):
            total_lz += 1
            dst = lz.get("target_scene")
            spawn = lz.get("target_spawn")
            if dst not in levels:
                print("ORPHAN: %s -> %s (target missing)" % (src, dst))
                orphans += 1
                continue
            dst_data = levels[dst]
            if spawn and not any(s.get("id") == spawn
                                  for s in dst_data.get("spawns", [])):
                print("MISSING SPAWN: %s -> %s wants spawn '%s'" % (
                    src, dst, spawn))
                missing_spawns += 1
            # Reverse-edge check.
            back = any(z.get("target_scene") == src
                        for z in dst_data.get("load_zones", []))
            if not back:
                # Only flag once per (src,dst) pair.
                pass  # one-way is allowed in some cases; just count it.

    # One-way scan separately (per directed edge missing reverse):
    edge_set = set()
    for src, data in levels.items():
        for lz in data.get("load_zones", []):
            dst = lz.get("target_scene")
            if dst:
                edge_set.add((src, dst))
    for s, d in sorted(edge_set):
        if d in levels and (d, s) not in edge_set:
            print("ONE-WAY: %s -> %s (no reverse)" % (s, d))
            one_way += 1

    print("\nlevels: %d  load_zones: %d  orphans: %d  missing back-spawns: %d  one-way edges: %d" % (
        len(levels), total_lz, orphans, missing_spawns, one_way))


if __name__ == "__main__":
    main()
