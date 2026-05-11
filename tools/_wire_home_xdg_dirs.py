#!/usr/bin/env python3
"""Wire the 5 home-village parent dungeons to the 18 new XDG sub-dirs.

  hearthold     -> hearthold_documents, hearthold_music
  brookhold     -> brookhold_desktop, brookhold_documents,
                   brookhold_music, brookhold_downloads
  old_hold      -> wyrdkin_desktop, wyrdkin_documents,
                   wyrdkin_music, wyrdkin_downloads
  home_lirien   -> lirien_desktop, lirien_documents,
                   lirien_music, lirien_downloads
  home_khorgaul -> khorgaul_desktop, khorgaul_documents,
                   khorgaul_music, khorgaul_downloads

Each new outgoing load_zone is placed on the parent's interior at a
free spot. Pattern mirrors _wire_new_unix_dirs.py — circle around the
parent's centre, avoid existing zones.

Idempotent: re-running won't duplicate a zone whose target_scene matches.
"""

import json
import math
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


WIRING = {
    "hearthold": [
        ("hearthold_documents", "[E] Into the writing room"),
        ("hearthold_music",     "[E] Into the music hall"),
    ],
    "brookhold": [
        ("brookhold_desktop",   "[E] Out to the field-bench"),
        ("brookhold_documents", "[E] To the almanac shelf"),
        ("brookhold_music",     "[E] To the fiddle-on-the-fence"),
        ("brookhold_downloads", "[E] To the grain-sack room"),
    ],
    "old_hold": [
        ("wyrdkin_desktop",   "[E] To Grandmother's desk"),
        ("wyrdkin_documents", "[E] To the family-papers chest"),
        ("wyrdkin_music",     "[E] To the hung harp"),
        ("wyrdkin_downloads", "[E] To the pile by the door"),
    ],
    "home_lirien": [
        ("lirien_desktop",   "[E] To the astronomer's desk"),
        ("lirien_documents", "[E] To the star-charts"),
        ("lirien_music",     "[E] To the singing bowl"),
        ("lirien_downloads", "[E] To the basket of sealed letters"),
    ],
    "home_khorgaul": [
        ("khorgaul_desktop",   "[E] Into the charred desk-room"),
        ("khorgaul_documents", "[E] To the half-burned paper"),
        ("khorgaul_music",     "[E] To the broken drum"),
        ("khorgaul_downloads", "[E] Into the empty room"),
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


def far_enough(pt, others, min_dist=6.0):
    px, pz = pt
    for ox, oz in others:
        if math.hypot(px - ox, pz - oz) < min_dist:
            return False
    return True


def pick_spot(data, index, total_new, retry=0):
    """Choose an interior spot for a new load zone — angled around
    the parent's centre, on the inner side of its bbox."""
    xmin, zmin, xmax, zmax = cell_bbox(data)
    cx = (xmin + xmax + 1) * 0.5
    cz = (zmin + zmax + 1) * 0.5
    # Use a radius that scales with the parent size so we sit near the
    # edge, not in the middle.
    half_x = (xmax - xmin) * 0.5
    half_z = (zmax - zmin) * 0.5
    base_radius = max(6.0, min(half_x, half_z) - 3.0)
    # Try the south, east, west, north quadrants in order; vary radius
    # slightly per retry so we don't trip the proximity guard forever.
    radius = base_radius * (1.0 - 0.10 * (retry % 3))
    # Distribute around the south-east half-circle by default — most of
    # the existing exits sit on the north/west arc (back to the parent
    # hub), so the south-east is usually clear.
    n = max(1, total_new)
    # Sweep from south (angle = pi/2) clockwise across the east arc to
    # north-east (angle = -pi/4).
    angle_start = math.pi * 0.5
    angle_end   = -math.pi * 0.25
    # Stagger retries by half a slot so a second pass slots between the
    # first pass's choices.
    frac = (index + 0.5 + 0.5 * retry) / float(n + 1)
    angle = angle_start + (angle_end - angle_start) * frac
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
        for retry in range(12):
            cand = pick_spot(data, i, total, retry=retry)
            if far_enough(cand, occupied, min_dist=6.0):
                spot = cand
                break
        if spot is None:
            spot = pick_spot(data, i, total)
        x, z = spot
        # Thin-axis points outward — heuristic: thin on whichever axis
        # has the greater absolute (farther from origin in that dir).
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
        print("%-15s + %d load_zones" % (pid, added))


if __name__ == "__main__":
    main()
