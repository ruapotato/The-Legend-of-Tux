#!/usr/bin/env python3
"""One-shot compass pass per FILESYSTEM.md §v2.3 + §v2.4.

For every dungeon JSON:
  - classify each load_zone target as parent / child / sibling-shortcut
    based on PATH_MAP tree relations.
  - reposition load_zones onto compass-correct edges of the level's
    cell footprint (south=parent, north=children, east/west=siblings).
  - reposition `default` and `from_<X>` spawns to match.
  - for *small passthrough* levels (the 31 reshape candidates), REBUILD
    the cells array to a shape sized by child count.
  - leave the `props` array untouched.

Adds v2.4 non-tree shortcut load_zones:
  - sbin <-> usr_sbin (E/W)
  - lib  <-> usr_lib  (E/W)
  - proc_init <-> sys
  - var_mail <-> hearthold, brookhold, old_hold (a.k.a. /home/wyrdkin),
                 home_lirien   (4 mail loops; auto:false prompt)
  - dev_loop self-loop x 7 (counter is content-side; comment-only here)

Run from project root:
    python3 tools/_compass_pass.py
"""

import json
import math
import os
import sys

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

sys.path.insert(0, os.path.join(ROOT, "tools"))
from build_dungeon import PATH_MAP

# ---- tier classification --------------------------------------------------

# The 8 capital-D Dungeons (DESIGN.md §2). Cells are NOT rewritten.
# Most also have hand-authored interior puzzles whose load_zones must
# stay where they were placed — DUNGEON_HANDS_OFF skips LZ/spawn
# repositioning entirely. Forge + Scriptorium are dungeon-grade hubs
# that gained NEW children in v2; their LZs DO get re-aligned so the
# new children don't sit at random interior coordinates.
DUNGEON_TIER = {
    "dungeon_first", "sigilkeep", "stoneroost", "burnt_hollow",
    "forge", "mirelake", "scriptorium", "null_door",
}
DUNGEON_HANDS_OFF = {
    "dungeon_first", "sigilkeep", "stoneroost", "burnt_hollow",
    "mirelake", "null_door",
}

# Kingdom-grade hand-authored content levels — keep cells, but realign
# load_zones to compass edges of the existing footprint.
KINGDOM_TIER = {
    "sourceplain", "wyrdwood", "wyrdkin_glade",
    "hearthold", "brookhold", "burrows",
    "library", "cache", "stacks", "ledger",
    "backwater", "cache_wyrdmark",
    "wake", "drift", "murk", "sprawl",
    "binds", "sharers", "old_plays", "locals",
    "crown", "old_hold", "optional_yard", "wake_grub",
}

# Anything in PATH_MAP not in the above two sets is a small passthrough
# whose cells we may rebuild.

# Grottoes — not in PATH_MAP. Leaves of their host kingdom. Skip.
GROTTOES = {"grotto_burrows", "grotto_forge", "grotto_glade", "grotto_sourceplain"}


# ---- tree helpers ---------------------------------------------------------

def parent_of_path(p):
    if p == "/":
        return None
    if p.count("/") == 1:
        return "/"
    return p.rsplit("/", 1)[0]

ids_by_path = {p: lid for lid, p in PATH_MAP.items()}
parent_id = {}
children = {lid: [] for lid in PATH_MAP}
for lid, p in PATH_MAP.items():
    par_p = parent_of_path(p)
    if par_p and par_p in ids_by_path:
        parent_id[lid] = ids_by_path[par_p]
        children[ids_by_path[par_p]].append(lid)
    else:
        parent_id[lid] = None

# Sort children by their fs_path for stable ordering across north edge.
for lid in children:
    children[lid].sort(key=lambda c: PATH_MAP[c])


# ---- v2.4 shortcuts -------------------------------------------------------

# Each entry: (a, b, prompt_a, prompt_b, auto_a, auto_b)
# auto=True default; auto=False means [E] interaction prompt.
V2_SHORTCUTS = [
    ("sbin", "usr_sbin",
     "[E] Through to Sprawl Outpost", "[E] Through to Sentinel Hall",
     True, True),
    ("lib", "usr_lib",
     "[E] Through to Sprawl Library", "[E] Through to the Loomhouse",
     True, True),
    ("proc_init", "sys",
     "[E] Through to the Heartworks", "[E] Through to the First Process",
     True, True),
    # Mail loops: discreet; prompt-style.
    ("var_mail", "hearthold",
     "[E] Send a letter to Hearthold", "[E] Check the mailbox",
     False, False),
    ("var_mail", "brookhold",
     "[E] Send a letter to Brookhold", "[E] Check the mailbox",
     False, False),
    ("var_mail", "old_hold",
     "[E] Send a letter to the Old Hold", "[E] Check the mailbox",
     False, False),
    ("var_mail", "home_lirien",
     "[E] Send a letter to Lirien", "[E] Check the mailbox",
     False, False),
]


# ---- cell rect + shape helpers --------------------------------------------

def cells_rect(rx_min, rz_min, rx_max, rz_max):
    """[x,z] cells for half-open rect [rx_min..rx_max) x [rz_min..rz_max)."""
    return [[i, j] for i in range(rx_min, rx_max) for j in range(rz_min, rz_max)]


def passthrough_shape(n_children):
    """Returns (cells, rx, rz) for a centered footprint per child count.

    rx/rz here are the *half-extent* in cells. The full extent is 2*rx by
    2*rz. cells are emitted as a centered rect [-rx..rx) x [-rz..rz).
    """
    if n_children <= 0:
        rx, rz = 4, 4                  # leaf 8x8
    elif n_children == 1:
        rx, rz = 3, 12                 # 1-child corridor 6x24
    elif n_children == 2:
        rx, rz = 8, 8                  # T-junction 16x16
    elif n_children == 3:
        rx, rz = 11, 11                # Y/triangle 22x22
    else:
        rx, rz = 14, 14                # 4+ child hub 28x28
    return cells_rect(-rx, -rz, rx, rz), rx, rz


# ---- load_zone + spawn placement ------------------------------------------

# LZ y-position. Matches the existing convention.
LZ_Y = 1.4
# Spawn y-position.
SPAWN_Y = 0.5

# Standard LZ size for a north/south oriented gateway (player walks
# south-to-north or north-to-south through it).
LZ_SIZE_NS = [4.0, 3.0, 1.5]
# Standard LZ size for an east/west gateway.
LZ_SIZE_EW = [1.5, 3.0, 4.0]


def fan_axis(n, lo, hi, margin=2.0):
    """Return n coordinates evenly fanned across [lo+margin, hi-margin].
    For n==1, returns the midpoint of [lo, hi]."""
    if n <= 0:
        return []
    a = lo + margin
    b = hi - margin
    if b <= a:
        # Footprint too thin — fall back to single midpoint.
        mid = (lo + hi) / 2.0
        return [round(mid, 2)] * n
    if n == 1:
        return [round((a + b) / 2.0, 2)]
    step = (b - a) / (n - 1)
    return [round(a + step * i, 2) for i in range(n)]


def fan_x(n, half_width):
    """Symmetric fan on the X-axis (legacy)."""
    return fan_axis(n, -float(half_width), float(half_width))


def fan_z(n, half_depth):
    """Symmetric fan on the Z-axis (legacy)."""
    return fan_axis(n, -float(half_depth), float(half_depth))


def cell_bounds(data):
    """Return (xmin, xmax, zmin, zmax) of the level's cell footprint, in
    cell indices (NOT world units). Returns (-6, 5, -6, 5) on empty."""
    floors = data.get("grid", {}).get("floors", [])
    if not floors:
        return (-6, 5, -6, 5)
    cells = floors[0].get("cells", [])
    if not cells:
        return (-6, 5, -6, 5)
    xs = [int(c[0]) for c in cells]
    zs = [int(c[1]) for c in cells]
    return (min(xs), max(xs), min(zs), max(zs))


def world_edges(data):
    """Return floats (x_west, x_east, z_south, z_north, cs) where the
    edges are slightly inset from the perimeter so LZs sit on a walkable
    cell, not in the wall. Inset is 1 cell."""
    cs = float(data.get("grid", {}).get("cell_size", 1.0))
    xmin, xmax, zmin, zmax = cell_bounds(data)
    # Cell xmin covers world x in [xmin*cs, (xmin+1)*cs]. Centre of
    # outermost south cell is (zmin + 0.5)*cs. We want the LZ ON the
    # outermost row but centered such that the trigger volume sits half
    # outside (so the player walks INTO it).
    # Place LZ centre at cell-row index zmin + 0 (edge), with depth 1.5
    # — that's z = zmin*cs (just inside).
    return (
        round((xmin + 1) * cs, 2),       # x_west: 1 cell inset from west wall
        round((xmax) * cs, 2),           # x_east: 1 cell inset from east wall
        round((zmin + 1) * cs, 2),       # z_south
        round((zmax) * cs, 2),           # z_north
        cs,
    )


# ---- spawn helpers --------------------------------------------------------

def _set_spawn(spawns, sid, pos, rotation_y):
    """Add or update spawn `sid`. Returns the spawn dict."""
    for s in spawns:
        if s.get("id") == sid:
            s["pos"] = [round(p, 2) for p in pos]
            s["rotation_y"] = rotation_y
            return s
    spawns.append({
        "id": sid,
        "pos": [round(p, 2) for p in pos],
        "rotation_y": rotation_y,
    })
    return spawns[-1]


# ---- core ----------------------------------------------------------------

def classify(lid, target):
    """Return 'parent' | 'child' | 'sibling' relative to lid."""
    if parent_id.get(lid) == target:
        return "parent"
    if target in children.get(lid, []):
        return "child"
    return "sibling"


def reshape_passthrough_cells(data, n_children, palette_floor=None, palette_wall=None):
    """Rewrite cells, has_floor/walls/roof for a passthrough-tier level."""
    cells, rx, rz = passthrough_shape(n_children)
    floors = data.get("grid", {}).get("floors", [])
    if not floors:
        floors = [{}]
        data.setdefault("grid", {})["floors"] = floors
    fl = floors[0]
    fl["cells"] = cells
    fl.setdefault("y", 0.0)
    fl.setdefault("name", "ground")
    fl.setdefault("wall_height", 4.0)
    if palette_wall is not None:
        fl.setdefault("wall_color", palette_wall)
    if palette_floor is not None:
        fl.setdefault("floor_color", palette_floor)
    fl.setdefault("wall_material", fl.get("wall_material", "stone"))
    fl["has_floor"] = True
    fl["has_walls"] = True
    fl["has_roof"]  = False
    data["grid"]["cell_size"] = float(data.get("grid", {}).get("cell_size", 1.0))
    return rx, rz


def reposition_loadzones(data, lid):
    """Compass-place every existing load_zone's pos/size. Targets are
    grouped by direction (parent/children/siblings) and fanned across
    each edge."""
    lzs = data.get("load_zones", [])
    if not lzs:
        return

    x_w, x_e, z_s, z_n, cs = world_edges(data)
    # World extent for asymmetric fanning.
    xmin, xmax, zmin, zmax = cell_bounds(data)
    world_x_min = xmin * cs
    world_x_max = (xmax + 1) * cs
    world_z_min = zmin * cs
    world_z_max = (zmax + 1) * cs

    parent_lzs   = []
    child_lzs    = []
    sibling_lzs  = []
    for lz in lzs:
        # Skip grotto-trip zones — they're hand-placed interior portals,
        # not perimeter exits.
        if lz.get("target_scene", "").startswith("grotto_"):
            continue
        cls = classify(lid, lz["target_scene"])
        if cls == "parent":
            parent_lzs.append(lz)
        elif cls == "child":
            child_lzs.append(lz)
        else:
            sibling_lzs.append(lz)

    # Parent: fan across south edge (rare for >1 parent, but tolerate).
    if parent_lzs:
        xs = fan_axis(len(parent_lzs), world_x_min, world_x_max)
        for lz, x in zip(parent_lzs, xs):
            lz["pos"] = [x, LZ_Y, z_s]
            lz["size"] = list(LZ_SIZE_NS)
            lz["rotation_y"] = 0.0

    # Children: fan across north edge.
    if child_lzs:
        # Sort by target fs_path for stable layout.
        child_lzs.sort(key=lambda lz: PATH_MAP.get(lz["target_scene"], lz["target_scene"]))
        xs = fan_axis(len(child_lzs), world_x_min, world_x_max)
        for lz, x in zip(child_lzs, xs):
            lz["pos"] = [x, LZ_Y, z_n]
            lz["size"] = list(LZ_SIZE_NS)
            lz["rotation_y"] = 0.0

    # Siblings/shortcuts: alternate east, west, fanned along Z.
    if sibling_lzs:
        sibling_lzs.sort(key=lambda lz: lz["target_scene"])
        n_e = (len(sibling_lzs) + 1) // 2
        n_w = len(sibling_lzs) - n_e
        zs_e = fan_axis(n_e, world_z_min, world_z_max)
        zs_w = fan_axis(n_w, world_z_min, world_z_max)
        e_idx = 0
        w_idx = 0
        for i, lz in enumerate(sibling_lzs):
            if i % 2 == 0:
                z = zs_e[e_idx]; e_idx += 1
                lz["pos"] = [x_e, LZ_Y, z]
            else:
                z = zs_w[w_idx]; w_idx += 1
                lz["pos"] = [x_w, LZ_Y, z]
            lz["size"] = list(LZ_SIZE_EW)
            lz["rotation_y"] = 0.0


def _spawn_from_lz(lz, x_w, x_e, z_s, z_n):
    """Compute (pos, rotation_y) for a spawn 2m INSIDE the LZ."""
    lx, _ly, lz_pos = lz["pos"]
    if abs(lz_pos - z_s) < 0.5:        # south LZ
        return [lx, SPAWN_Y, lz_pos + 2.0], math.pi
    if abs(lz_pos - z_n) < 0.5:        # north LZ
        return [lx, SPAWN_Y, lz_pos - 2.0], 0.0
    if abs(lx - x_e) < 0.5:            # east LZ
        return [lx - 2.0, SPAWN_Y, lz_pos], -math.pi / 2.0
    if abs(lx - x_w) < 0.5:            # west LZ
        return [lx + 2.0, SPAWN_Y, lz_pos], math.pi / 2.0
    return [lx, SPAWN_Y, lz_pos], math.pi


def reposition_spawns(data, lid, rewrite_default=True, all_levels=None):
    """For each outgoing LZ in `data`, inset a `from_<target>` spawn just
    inside this side of that LZ. Optionally also rewrite `default`.

    Also handles legacy spawn-id aliases: if some OTHER level B has an
    LZ targeting `(this_level, target_spawn=S)` where S is not the
    canonical `from_<B>`, we still need spawn `S` to land near the LZ
    going back to B."""
    spawns = data.setdefault("spawns", [])
    x_w, x_e, z_s, z_n, cs = world_edges(data)

    if rewrite_default:
        _set_spawn(spawns, "default", [0.0, SPAWN_Y, z_s + 1.5], math.pi)

    # Index our outgoing LZs by target.
    out_by_target = {lz["target_scene"]: lz for lz in data.get("load_zones", [])}

    # Step 1: canonical `from_<target>` per outgoing LZ.
    for target, lz in out_by_target.items():
        pos, rot = _spawn_from_lz(lz, x_w, x_e, z_s, z_n)
        _set_spawn(spawns, "from_" + target, pos, rot)

    # Step 2: legacy aliases. For each OTHER level B with an LZ pointing
    # at us with a non-canonical target_spawn S, place S near our LZ to B.
    if all_levels is not None:
        for b_lid, b_data in all_levels.items():
            if b_lid == lid:
                continue
            for blz in b_data.get("load_zones", []):
                if blz.get("target_scene") != lid:
                    continue
                S = blz.get("target_spawn")
                if not S:
                    continue
                if S == "default":
                    continue
                if S == "from_" + b_lid:
                    continue   # already handled above
                # Place S near OUR outgoing LZ to b_lid (if any).
                back_lz = out_by_target.get(b_lid)
                if back_lz is None:
                    continue   # no outgoing LZ; let ensure_back_spawns
                               # pick a fallback later.
                pos, rot = _spawn_from_lz(back_lz, x_w, x_e, z_s, z_n)
                _set_spawn(spawns, S, pos, rot)


# ---- v2.4 shortcut injection ---------------------------------------------

def _has_edge(data, target):
    return any(lz.get("target_scene") == target
               for lz in data.get("load_zones", []))


def add_v2_shortcuts(levels):
    """Mutate level dicts in-place to add v2.4 shortcut load_zones if
    missing. Returns count added."""
    added = 0
    for a, b, prompt_a, prompt_b, auto_a, auto_b in V2_SHORTCUTS:
        if a not in levels or b not in levels:
            continue
        da, db = levels[a], levels[b]
        if not _has_edge(da, b):
            lz = {
                "pos":  [0.0, LZ_Y, 0.0],   # placed for real later
                "size": list(LZ_SIZE_EW),
                "rotation_y": 0.0,
                "target_scene": b,
                "target_spawn": "from_" + a,
                "prompt": prompt_a,
            }
            if not auto_a:
                lz["auto"] = False
            da.setdefault("load_zones", []).append(lz)
            added += 1
        if not _has_edge(db, a):
            lz = {
                "pos":  [0.0, LZ_Y, 0.0],
                "size": list(LZ_SIZE_EW),
                "rotation_y": 0.0,
                "target_scene": a,
                "target_spawn": "from_" + b,
                "prompt": prompt_b,
            }
            if not auto_b:
                lz["auto"] = False
            db.setdefault("load_zones", []).append(lz)
            added += 1
    # dev_loop self-loop x 7 (perimeter ring; counter is content-side).
    if "dev_loop" in levels:
        d = levels["dev_loop"]
        # Strip any existing self-loops first.
        d["load_zones"] = [lz for lz in d.get("load_zones", [])
                           if lz.get("target_scene") != "dev_loop"]
        for i in range(7):
            d["load_zones"].append({
                # Comment baked into the data via prompt only — JSON has no comments.
                "pos":  [0.0, LZ_Y, 0.0],
                "size": list(LZ_SIZE_EW),
                "rotation_y": 0.0,
                "target_scene": "dev_loop",
                "target_spawn": "loop_%d" % i,
                "prompt": "[E] Walk through (loop %d/7)" % (i + 1),
                "auto": False,
            })
            added += 1
        # Add the corresponding spawn ids on dev_loop itself.
        spawns = d.setdefault("spawns", [])
        for i in range(7):
            sid = "loop_%d" % i
            if not any(s.get("id") == sid for s in spawns):
                spawns.append({
                    "id": sid,
                    "pos": [0.0, SPAWN_Y, 0.0],
                    "rotation_y": math.pi,
                })
    return added


# ---- main ----------------------------------------------------------------

def is_passthrough(lid):
    if lid in DUNGEON_TIER:        return False
    if lid in KINGDOM_TIER:        return False
    if lid in GROTTOES:            return False
    if lid not in PATH_MAP:        return False
    return True


def main():
    levels = {}
    for fn in sorted(os.listdir(DUNGEONS)):
        if not fn.endswith(".json"):
            continue
        lid = fn[:-5]
        levels[lid] = json.load(open(os.path.join(DUNGEONS, fn)))

    n_reshape = 0
    n_lz_only = 0

    # Pass 1: reshape passthroughs (cells + LZs + spawns).
    for lid, data in levels.items():
        if not is_passthrough(lid):
            continue
        n_kids = len(children.get(lid, []))
        # Inherit existing palette colors so the rebuild keeps the look.
        floors = data.get("grid", {}).get("floors", [{}])
        fl = floors[0] if floors else {}
        wall_c  = fl.get("wall_color")
        floor_c = fl.get("floor_color")
        reshape_passthrough_cells(data, n_kids, floor_c, wall_c)
        n_reshape += 1

    # Pass 2: add v2.4 shortcut LZs (BEFORE LZ repositioning so the new
    # LZs get placed onto compass edges in pass 3).
    n_added = add_v2_shortcuts(levels)

    # Pass 3: reposition LZs and spawns. Skip the grottoes (interior
    # portals authored by hand). Skip hand-authored Dungeons (DUNGEON_
    # HANDS_OFF) entirely — their LZs are part of the dungeon puzzle.
    # For Dungeon hubs (forge, scriptorium) we DO reposition LZs/spawns
    # to compass edges (per spec) but never the `default` spawn.
    # ALSO: kingdom-tier levels with sparse cell footprints (outdoor
    # hand-shaped maps like sourceplain, wyrdwood) keep their LZs in
    # place — moving them risks landing the LZ in null space.
    n_skipped_sparse = 0
    for lid, data in levels.items():
        if lid in GROTTOES:
            continue
        if lid not in PATH_MAP:
            continue
        if lid in DUNGEON_HANDS_OFF:
            continue

        # Density check: if non-passthrough kingdom level has < 0.9
        # cell density, treat it as outdoor and don't move LZs.
        if lid in KINGDOM_TIER:
            floors = data.get("grid", {}).get("floors", [])
            cells = floors[0].get("cells", []) if floors else []
            if cells:
                xs = [int(c[0]) for c in cells]; zs = [int(c[1]) for c in cells]
                bbox = (max(xs) - min(xs) + 1) * (max(zs) - min(zs) + 1)
                density = len(cells) / float(bbox)
                if density < 0.9:
                    # Just update from_<X> spawns to existing LZ positions
                    # (so back-spawns track LZ moves done by other tools).
                    reposition_spawns(data, lid,
                                      rewrite_default=False,
                                      all_levels=levels)
                    n_skipped_sparse += 1
                    continue

        reposition_loadzones(data, lid)
        reposition_spawns(data, lid,
                          rewrite_default=is_passthrough(lid),
                          all_levels=levels)
        if not is_passthrough(lid):
            n_lz_only += 1
    if n_skipped_sparse:
        print("  (kept sparse-footprint LZs in place: %d levels)" % n_skipped_sparse)

    # Write back.
    for lid, data in levels.items():
        with open(os.path.join(DUNGEONS, lid + ".json"), "w") as f:
            json.dump(data, f, indent=2)

    print("compass pass: %d reshaped, %d kingdom-tier rotated, %d v2.4 shortcuts added"
          % (n_reshape, n_lz_only, n_added))


if __name__ == "__main__":
    main()
