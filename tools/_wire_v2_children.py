#!/usr/bin/env python3
"""One-shot wire-up: add outgoing load_zones in v1 parent JSONs that
target the v2 new-child directories. Idempotent — skips if a zone
with the same target_scene already exists. Also adds back-spawns
(`from_<parent>`) on the child side via ensure_back_spawns.py."""

import json
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

# parent_id -> list of (child_id, prompt, pos_xyz, size_xyz)
# Positions chosen to lie ~1 cell outside the parent's existing cell
# footprint along the +Z (north) edge per the v2.3 compass rule (children
# to the north). Existing radial slots are left untouched.
WIRES = {
    "crown":  [  # 32x32 (x:[-16..15], z:[-16..15]); place on +Z edge at z=17.
        ("bin",        "[E] Into the Toolshed",         (-12.0, 17.0)),
        ("sbin",       "[E] Into Sentinel Hall",         (-8.0, 17.0)),
        ("lib",        "[E] Into the Loomhouse",         (-4.0, 17.0)),
        ("lost_found", "[E] Into the Hall of Lost Things",(0.0, 17.0)),
        ("root_hold",  "[E] To Root's Hold",              (4.0, 17.0)),
        ("srv",        "[E] Into the Servery",            (8.0, 17.0)),
        ("sys",        "[E] Into the Heartworks",         (12.0, 17.0)),
    ],
    "scriptorium": [  # 32x32; +Z edge at z=17.
        ("etc_initd",  "[E] To the Initiates",            (-6.0, 17.0)),
        ("etc_passwd", "[E] To the Names Hall",           (6.0, 17.0)),
    ],
    "burrows": [  # 32x32; +Z edge at z=17.
        ("home_lirien",   "[E] To Lirien's Chamber",      (-6.0, 17.0)),
        ("home_khorgaul", "[E] To the Khorgaul Roost",    (6.0, 17.0)),
    ],
    "murk": [  # 32x32; +Z edge at z=17 (only z=-13 is occupied).
        ("proc_init", "[E] To the First Process",         (-8.0, 17.0)),
        ("proc_sys",  "[E] Into the Murk Senate",          (0.0, 17.0)),
        ("proc_42",   "[E] To Process 42",                 (8.0, 17.0)),
    ],
    "sprawl": [  # 32x32; +Z edge at z=17.
        ("usr_lib",     "[E] Into the Sprawl Library",   (-12.0, 17.0)),
        ("usr_sbin",    "[E] To the Sprawl Outpost",      (-4.0, 17.0)),
        ("usr_src",     "[E] Into the Sourcerooms",        (4.0, 17.0)),
        ("usr_include", "[E] Into the Sprawl Index Hall", (12.0, 17.0)),
    ],
    "sharers": [  # 32x32; place at +Z just east of old_plays slot.
        ("usr_share_man", "[E] Into the Manuscripts",     (8.0, 17.0)),
    ],
    "library": [  # 56x56 (x:[-28..27], z:[-28..27]); +Z edge at z=29.
        ("var_mail",  "[E] To the Postmark",            (-12.0, 29.0)),
        ("var_run",   "[E] Into the Pulse Room",         (-4.0, 29.0)),
        ("var_tmp",   "[E] Into the Long Drift",          (4.0, 29.0)),
        ("var_games", "[E] To the Scoreroom",            (12.0, 29.0)),
    ],
    "forge": [  # 56x56; +Z edge at z=29 (null_door uses x=0, z=25).
        ("dev_zero",   "[E] Into the Quietness",        (-12.0, 29.0)),
        ("dev_random", "[E] Into the Wild Hum",          (-4.0, 29.0)),
        ("dev_tty",    "[E] Into the Speaker's Room",     (4.0, 29.0)),
        ("dev_loop",   "[E] Into the Recursion Hall",   (12.0, 29.0)),
    ],
}


def main():
    added = 0
    touched = 0
    for parent_id, children in WIRES.items():
        path = os.path.join(DUNGEONS, parent_id + ".json")
        if not os.path.exists(path):
            print("MISSING parent: %s" % parent_id)
            continue
        with open(path) as f:
            data = json.load(f)
        lz_list = data.setdefault("load_zones", [])
        existing_targets = {lz.get("target_scene") for lz in lz_list}
        local_added = 0
        for child_id, prompt, (px, pz) in children:
            if child_id in existing_targets:
                print("  %-12s -> %-15s already wired" % (parent_id, child_id))
                continue
            # +Z (north) edge: thin axis on Z so the box reads as a wall opening.
            lz_list.append({
                "pos":          [round(px, 2), 1.4, round(pz, 2)],
                "size":         [4.0, 3.0, 1.5],
                "rotation_y":   0.0,
                "target_scene": child_id,
                "target_spawn": "from_" + parent_id,
                "prompt":       prompt,
            })
            local_added += 1
            added += 1
            print("  %-12s -> %-15s wired (%g, %g)" % (
                parent_id, child_id, px, pz))
        if local_added:
            with open(path, "w") as f:
                json.dump(data, f, indent=2)
            touched += 1
    print("\nadded %d load_zones across %d parent JSONs" % (added, touched))


if __name__ == "__main__":
    main()
