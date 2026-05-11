#!/usr/bin/env python3
"""Wire the 5 parent dungeons to the 10 new canonical-Unix sub-dirs.

  hearthold     -> hearthold_desktop, hearthold_downloads
  old_hold      -> wyrdkin_config, wyrdkin_cache, wyrdkin_bash_history
  scriptorium   -> etc_hosts, etc_motd, etc_fstab
  ledger        -> var_log_syslog
  drift         -> tmp_x11_unix

Each new outgoing load_zone is placed on the parent's interior at a
free spot near a wall. We pick spots in a circle around the level's
median cell, ensure no overlap with existing zones, and write the
target_spawn as `from_<parent_id>`. Subsequent grow_filesystem.py runs
will keep these zones (it preserves load_zones it didn't author).

Idempotent: re-running won't duplicate a zone whose target_scene matches.
"""

import json
import math
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


WIRING = {
    "hearthold": [
        ("hearthold_desktop",   "[E] Step onto the Desktop"),
        ("hearthold_downloads", "[E] Into the Downloads room"),
    ],
    "old_hold": [
        ("wyrdkin_config",       "[E] Behind the ash-grey curtain"),
        ("wyrdkin_cache",        "[E] Into the stale pantry"),
        ("wyrdkin_bash_history", "[E] Down the hall of carved tablets"),
    ],
    "scriptorium": [
        ("etc_hosts", "[E] To the Hosts tablet"),
        ("etc_motd",  "[E] Hear the day's message"),
        ("etc_fstab", "[E] To the Mount Table"),
    ],
    "ledger": [
        ("var_log_syslog", "[E] Down the Syslog hall"),
    ],
    "drift": [
        ("tmp_x11_unix", "[E] Into the X11 socket room"),
    ],
}


def load(level_id):
    p = os.path.join(DUNGEONS, level_id + ".json")
    return json.load(open(p)), p


def existing_targets(data):
    return {lz.get("target_scene")
            for lz in data.get("load_zones", [])}


def existing_zone_xz(data):
    out = []
    for lz in data.get("load_zones", []):
        pos = lz.get("pos", [0, 0, 0])
        if len(pos) >= 3:
            out.append((float(pos[0]), float(pos[2])))
    return out


def cell_bbox(data):
    cells = (data.get("grid", {})
             .get("floors", [{}])[0]
             .get("cells", []))
    if not cells:
        return -10, -10, 10, 10
    xs = [int(c[0]) for c in cells]
    zs = [int(c[1]) for c in cells]
    return min(xs), min(zs), max(xs), max(zs)


def far_enough(pt, others, min_dist=4.0):
    px, pz = pt
    for ox, oz in others:
        if math.hypot(px - ox, pz - oz) < min_dist:
            return False
    return True


def pick_spot(data, index, total_new):
    """Choose an interior spot for a new load zone — angled around
    the parent's centre, on the inner side of its bbox."""
    xmin, zmin, xmax, zmax = cell_bbox(data)
    cx = (xmin + xmax + 1) * 0.5
    cz = (zmin + zmax + 1) * 0.5
    radius = max(4.0, min(xmax - cx, zmax - cz) - 2.0)
    # Slot new zones around the +x quadrant (east) so we don't overlap
    # existing canonical N/S/W exits used elsewhere.
    # Use a small arc of 120° from north to south-east.
    angle = (math.pi * 0.5) + (math.pi * 0.66 * (index + 1)
                                / float(total_new + 1))
    return (round(cx + math.cos(angle) * radius, 2),
            round(cz + math.sin(angle) * radius, 2))


def add_zones(parent_id):
    data, path = load(parent_id)
    targets = existing_targets(data)
    occupied = existing_zone_xz(data)
    to_add = [(t, p) for t, p in WIRING[parent_id] if t not in targets]
    if not to_add:
        return 0, path
    total = len(to_add)
    placed = 0
    for i, (target, prompt) in enumerate(to_add):
        # Try several angle slots until we find one not overlapping
        # an existing zone.
        spot = None
        for retry in range(8):
            cand = pick_spot(data, i + retry * total, total * 2)
            if far_enough(cand, occupied, min_dist=4.0):
                spot = cand
                break
        if spot is None:
            spot = pick_spot(data, i, total)
        x, z = spot
        # Thin-axis points outward — heuristic: away-from-centre is the
        # bigger absolute, so the thin axis is the AXIS of bigger abs.
        if abs(x) > abs(z):
            size = [1.5, 3.0, 4.0]
        else:
            size = [4.0, 3.0, 1.5]
        data.setdefault("load_zones", []).append({
            "pos":    [x, 1.4, z],
            "size":   size,
            "rotation_y":  0.0,
            "target_scene": target,
            "target_spawn": "from_" + parent_id,
            "prompt": prompt,
            "auto": False,
        })
        occupied.append(spot)
        placed += 1
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return placed, path


def main():
    for pid in WIRING:
        added, p = add_zones(pid)
        print("%-12s + %d load_zones" % (pid, added))


if __name__ == "__main__":
    main()
