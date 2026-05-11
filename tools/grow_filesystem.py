#!/usr/bin/env python3
"""grow_filesystem.py — the L-system rooting algorithm (FILESYSTEM.md §v3).

Reads PATH_MAP from build_dungeon.py to learn the directory tree.
Computes (world_pos, trunk_dir) per directory via depth-first L-system walk
from Crown.

For the 27 algorithm-owned v2 directories (+ 4 grottoes), it then:
  - generates an organic, branching root-shaped cell footprint
    (spine + thickened body + bulb + prongs + knots)
  - re-emits spawn anchors (from_<parent>, from_<child>) at the spine
    south end and prong tips
  - re-emits load_zone POSITIONS at compass-correct edges (parent at
    south, children at north prongs, siblings/shortcuts at east/west)
  - appends pillar clusters (3-5 trees + 1-2 rocks) between every pair
    of adjacent tree-wall gaps, so multi-child hubs no longer look like
    one giant black wall
  - re-binds existing handcrafted props (NPCs, signs, chests,
    owl_statues) of those levels to the nearest valid walking cell

Hand-authored levels (~30 listed in §v3.3) are PRESERVED — their cells
and spawns are not touched. Their load_zones to algorithm-owned dirs
keep their existing positions (the algorithm's incoming spine reaches
them from outside).

Idempotent: re-running yields the same footprints (the noise is
deterministically seeded from the directory id).

Usage:
    python3 tools/grow_filesystem.py
"""

import json
import math
import os
import random
import sys

# Import PATH_MAP from build_dungeon to stay in sync.
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from build_dungeon import PATH_MAP  # noqa: E402

DUNGEONS = os.path.join(ROOT, "dungeons")

# 27 v2 algorithm-owned dirs + 4 grottoes (per the task spec).
ALGO_OWNED = {
    # 27 v2 dirs:
    "bin", "sbin", "lib", "lost_found", "root_hold", "srv", "sys",
    "etc_initd", "etc_passwd",
    "home_lirien", "home_khorgaul",
    "proc_init", "proc_sys", "proc_42",
    "usr_lib", "usr_sbin", "usr_src", "usr_include", "usr_share_man",
    "var_mail", "var_run", "var_tmp", "var_games",
    "dev_zero", "dev_random", "dev_tty", "dev_loop",
    # 4 grottoes:
    "grotto_glade", "grotto_burrows", "grotto_forge", "grotto_sourceplain",
}

# Big-city special-case (40+ cell bulb) — among algorithm-owned dirs
# with several connections.
BIG_CITY = {"usr_src", "var_mail"}

# Cell size matches every dungeon (cell_size=1.0 throughout the project).
CELL_SIZE = 1.0


# ---------------------------------------------------------------------------
# Tree
# ---------------------------------------------------------------------------

def build_tree():
    """Build the parent/child tree from PATH_MAP. Returns
    (parent_of, children_of, depth_of, by_path)."""
    by_path = {fs: lid for lid, fs in PATH_MAP.items() if fs}
    parent_of = {}
    children_of = {lid: [] for lid in PATH_MAP}
    for lid, fs in PATH_MAP.items():
        if fs == "/" or not fs:
            parent_of[lid] = None
            continue
        # Find longest strict-prefix path that is also a level.
        best = None
        best_len = -1
        for p_fs, p_lid in by_path.items():
            if p_fs == fs:
                continue
            if not (p_fs == "/" or fs.startswith(p_fs + "/")):
                continue
            if len(p_fs) > best_len:
                best_len = len(p_fs)
                best = p_lid
        parent_of[lid] = best
        if best is not None:
            children_of[best].append(lid)

    # Stable child order — sort by id for determinism.
    for lid in children_of:
        children_of[lid].sort()

    # Grottoes don't appear in PATH_MAP-derived hierarchy (their fs_path
    # is /var/spool/grotto/<x>, which makes them children of `backwater`
    # via prefix). The actual game wiring is grotto_X is a cellar of a
    # specific surface level (wyrdkin_glade, hearthold, forge, sourceplain).
    # Walk the JSON load_zones to discover the true grotto parents.
    grotto_parents = {
        "grotto_glade":       "wyrdkin_glade",
        "grotto_burrows":     "hearthold",
        "grotto_forge":       "forge",
        "grotto_sourceplain": "sourceplain",
    }
    for g, p in grotto_parents.items():
        # Inject the grotto into the tree even though it's not in PATH_MAP.
        if p not in children_of:
            continue
        old = parent_of.get(g)
        if old is not None and old != p and g in children_of.get(old, []):
            children_of[old].remove(g)
        parent_of[g] = p
        children_of.setdefault(g, [])
        if g not in children_of[p]:
            children_of[p].append(g)
            children_of[p].sort()

    depth_of = {}
    def compute_depth(lid, d=0):
        depth_of[lid] = d
        for c in children_of[lid]:
            compute_depth(c, d + 1)
    root = next(lid for lid, p in parent_of.items() if p is None)
    compute_depth(root, 0)
    return parent_of, children_of, depth_of, root


# ---------------------------------------------------------------------------
# L-system: world_pos + trunk_dir
# ---------------------------------------------------------------------------

def compute_layout(root_id, parent_of, children_of):
    """DFS from Crown. Returns world_pos[lid] and trunk_dir[lid]."""
    world_pos = {root_id: (0.0, 0.0)}
    trunk_dir = {root_id: (0.0, 1.0)}  # +y in world ≡ +Z in scene ≡ NORTH
    order = [root_id]
    i = 0
    while i < len(order):
        node = order[i]
        i += 1
        kids = children_of.get(node, [])
        if not kids:
            continue
        sib_count = len(kids)
        parent_angle = math.atan2(trunk_dir[node][1], trunk_dir[node][0])
        # 4+ children: fan across full 360° perimeter so the hub doesn't
        # have all its child trunks crowd into one arc. First kid sits at
        # +y (north, math angle = π/2); subsequent kids walk CLOCKWISE
        # (decreasing math angle) around the perimeter.
        full_perim = sib_count >= 4
        if full_perim:
            base_dist = 45
        else:
            base_dist = 30 + (15 if sib_count > 2 else 0)
            spread_deg = max(30, min(140, 30 * sib_count))
            spread_rad = math.radians(spread_deg)
        for idx, kid in enumerate(kids):
            if full_perim:
                # Place i-th kid at math angle (π/2) - (2π/N)*i
                # i=0 → +π/2 (north / +y).  Going clockwise in XZ.
                my_angle = math.pi / 2 - (2.0 * math.pi / sib_count) * idx
            elif sib_count == 1:
                my_angle = parent_angle
            else:
                # fan across arc centred on parent_angle
                offset = (idx - (sib_count - 1) / 2.0) * (spread_rad / sib_count)
                my_angle = parent_angle + offset
            tdx = math.cos(my_angle)
            tdy = math.sin(my_angle)
            px, py = world_pos[node]
            world_pos[kid] = (px + tdx * base_dist, py + tdy * base_dist)
            trunk_dir[kid] = (tdx, tdy)
            order.append(kid)
    return world_pos, trunk_dir


# ---------------------------------------------------------------------------
# Deterministic value-noise (Perlin substitute) — pure Python, no deps.
# ---------------------------------------------------------------------------

def _hash01(seed_str, *args):
    """Deterministic hash → [0, 1). Uses sha256 because Python's
    built-in hash() is randomised across processes (PEP 456)."""
    import hashlib
    key = repr((seed_str,) + tuple(args)).encode("utf-8")
    digest = hashlib.sha256(key).digest()
    h = int.from_bytes(digest[:4], "little")
    return (h % 1000003) / 1000003.0


def perlin1d(seed, t):
    """Return a smooth 1D noise value in [-1, 1] for parameter t."""
    t = float(t)
    i0 = int(math.floor(t))
    i1 = i0 + 1
    frac = t - i0
    a = _hash01(seed, i0) * 2 - 1
    b = _hash01(seed, i1) * 2 - 1
    # Smoothstep ease.
    s = frac * frac * (3 - 2 * frac)
    return a * (1 - s) + b * s


# ---------------------------------------------------------------------------
# Cell generation per algorithm-owned directory
# ---------------------------------------------------------------------------

def generate_cells(level_id, role, spine_length, sibling_count_of_self,
                   prong_dirs_local, big_city=False):
    """Generate cells in LOCAL coordinates (so the level's own JSON
    `cells` array is self-contained — the L-system world_pos shows up
    only as the relative direction in `prong_dirs_local`).

    Local axes: +y = north (toward children), -y = south (toward parent).
    The south anchor is at local (0, -1); the spine grows along +y.

    Returns:
        cells: set of (i, j) cell coords
        spine_cells: list of (i, j) along the spine, south-to-north
        prong_tips: dict child_local_dir → (i, j) tip cell
    """
    seed = "fs::" + level_id
    rng = random.Random(seed)
    cells = set()

    # 1. Spine: south to north along +y, perturbed in x by perlin.
    # Range ±3 cells perpendicular for a more curved/winding profile.
    spine_cells = []
    for k in range(spine_length):
        t = k / max(1, spine_length - 1)
        ox = perlin1d(seed + ":spine_x", t * 4.0) * 3.0
        ix = int(round(ox))
        iy = k  # 0..spine_length-1
        spine_cells.append((ix, iy))

    # 2. Thicken: at each spine cell, add cells perpendicular within
    # a radius that varies along the spine.
    base_r_mid = 6
    if big_city:
        base_r_mid = 11  # 22+ cells across at the wide bulge
    for k, (sx, sy) in enumerate(spine_cells):
        t = k / max(1, spine_length - 1)
        # Radius profile:
        #   stem (t=0): narrow ~3
        #   mid  (t=0.5): wide ~base_r_mid
        #   tip  (t=1): tapers to ~base_r_mid // 2 (then bulb adds more)
        if t < 0.4:
            r_base = 3 + int(round((base_r_mid - 3) * (t / 0.4)))
        elif t < 0.7:
            r_base = base_r_mid
        else:
            tail = (t - 0.7) / 0.3
            r_base = max(3, base_r_mid - int(round((base_r_mid - 3) * tail * 0.6)))
        # Perlin-perturb the thickness on each side independently for
        # an organic, asymmetric edge.
        r_left  = max(2, r_base + int(round(perlin1d(seed + ":r_left",  t * 6) * 2)))
        r_right = max(2, r_base + int(round(perlin1d(seed + ":r_right", t * 6) * 2)))
        for j in range(-r_left, r_right + 1):
            cells.add((sx + j, sy))
            # Also fill a small vertical tile to make the body feel
            # less like a thin ribbon — duplicate each row slightly so
            # the wall renderer doesn't see a 1-cell-thick comb pattern.
            if k > 0:
                # interpolate between this row and the previous one
                psx, psy = spine_cells[k - 1]
                if abs(sx - psx) > 1:
                    midx = (sx + psx) // 2
                    cells.add((midx + j, sy))
                    cells.add((midx + j, psy))

    # 3. Tip bulb / prongs.
    last_sx, last_sy = spine_cells[-1]
    if role == "leaf":
        bulb_r = 8
        for di in range(-bulb_r - 1, bulb_r + 2):
            for dj in range(-bulb_r - 1, bulb_r + 2):
                jitter = perlin1d(seed + ":bulb",
                                  (di * 0.7) + (dj * 0.31)) * 1.5
                if di * di + dj * dj <= (bulb_r + jitter) ** 2:
                    cells.add((last_sx + di, last_sy + dj))
    elif role == "single":
        # Spine merges into the child's stem — no extra bulb. Round
        # the tip a bit so it's not a flat plate.
        for di in range(-3, 4):
            for dj in range(-2, 3):
                if di * di + dj * dj <= 8:
                    cells.add((last_sx + di, last_sy + dj))
    else:
        # multi-child junction: fat bulb + prongs to each child.
        bulb_r = 8 if not big_city else 12
        for di in range(-bulb_r - 1, bulb_r + 2):
            for dj in range(-bulb_r - 1, bulb_r + 2):
                jitter = perlin1d(seed + ":hub",
                                  (di * 0.5) + (dj * 0.27)) * 1.5
                if di * di + dj * dj <= (bulb_r + jitter) ** 2:
                    cells.add((last_sx + di, last_sy + dj))
        # Prongs reaching toward each child.
        prong_len = 6
        for cd in prong_dirs_local:
            cdx, cdy = cd
            for step in range(1, prong_len + 1):
                cx = last_sx + int(round(cdx * step))
                cy = last_sy + int(round(cdy * step))
                # 3-cell-wide prong (perpendicular to direction).
                pdx, pdy = -cdy, cdx  # perpendicular in 2D
                for j in range(-1, 2):
                    cells.add((cx + int(round(pdx * j)),
                               cy + int(round(pdy * j))))

    # 4. Knots: 2-4 small bulges along the perimeter, far from the south
    # anchor so we don't interfere with the entrance corridor.
    perim = []
    cell_list = list(cells)
    for c in cell_list:
        ci, cj = c
        if cj < 2:
            continue
        if (ci + 1, cj) not in cells or (ci - 1, cj) not in cells \
           or (ci, cj + 1) not in cells or (ci, cj - 1) not in cells:
            perim.append(c)
    if perim:
        for _ in range(rng.randint(2, 4)):
            base = rng.choice(perim)
            bi, bj = base
            for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
                if (bi + ddi, bj + ddj) not in cells and bj + ddj >= 2:
                    cells.add((bi + ddi, bj + ddj))
                    cells.add((bi + ddi * 2, bj + ddj * 2))
                    break

    # 5. Stem: ensure a clean corridor from south anchor (0, -1) up to
    # the spine start. Carve a 4-cell-wide entrance.
    for j in range(-2, spine_cells[0][1] + 2):
        for i in range(-3, 4):
            cells.add((i, j))

    # 6. Sanity: minimum 12x12 effective cell-rect. If our bounding box
    # is too small, expand the bulb a bit. (Also enforces the multi-child
    # hub at-least-18×18 rule and big-city at-least-40×40 rule.)
    cells = _ensure_min_size(cells, level_id, role, big_city, last_sx, last_sy)

    return cells, spine_cells


def _ensure_min_size(cells, level_id, role, big_city, cx, cy):
    """Pad the bulb area with concentric circles until the bbox meets
    the required minimum dimensions."""
    min_dim = 12
    if role == "multi":
        min_dim = 18
    if big_city:
        min_dim = 40
    safety = 0
    while True:
        is_ = [c[0] for c in cells]
        js_ = [c[1] for c in cells]
        if not is_:
            return cells
        bx = max(is_) - min(is_) + 1
        bz = max(js_) - min(js_) + 1
        if min(bx, bz) >= min_dim or safety > 40:
            return cells
        safety += 1
        # Add another ring around (cx, cy).
        r_extra = (min_dim - min(bx, bz)) // 2 + 1
        for di in range(-r_extra - 1, r_extra + 2):
            for dj in range(-r_extra - 1, r_extra + 2):
                jitter = perlin1d("fs::pad::" + level_id,
                                  (di * 0.4) + (dj * 0.21)) * 1.0
                if di * di + dj * dj <= (r_extra + jitter) ** 2:
                    cells.add((cx + di, cy + dj))


def bfs_reachable(cells, start):
    """Return set of (i,j) cells in `cells` reachable from `start`
    via 4-connectivity. Used to drop disconnected fragments."""
    if start not in cells:
        # Find the closest cell to `start` and use that.
        si, sj = start
        best = None; best_d2 = None
        for c in cells:
            d2 = (c[0] - si) ** 2 + (c[1] - sj) ** 2
            if best_d2 is None or d2 < best_d2:
                best_d2 = d2; best = c
        if best is None:
            return set()
        start = best
    seen = {start}
    stack = [start]
    while stack:
        ci, cj = stack.pop()
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            nb = (ci + ddi, cj + ddj)
            if nb in cells and nb not in seen:
                seen.add(nb)
                stack.append(nb)
    return seen


# ---------------------------------------------------------------------------
# Snap-helpers
# ---------------------------------------------------------------------------

def cells_to_world_xz(ci, cj):
    """A cell (i, j) covers world rect [i*cs .. (i+1)*cs] × [j*cs .. (j+1)*cs].
    Its centre is at ((i+0.5)*cs, (j+0.5)*cs)."""
    return ((ci + 0.5) * CELL_SIZE, (cj + 0.5) * CELL_SIZE)


def world_xz_to_cell(x, z):
    return (int(math.floor(x / CELL_SIZE)),
            int(math.floor(z / CELL_SIZE)))


def nearest_walking_cell(cells, target_xz):
    """Return the (i, j) cell in `cells` whose centre is closest to
    target_xz in world coords."""
    if not cells:
        return None
    tx, tz = target_xz
    best = None; best_d2 = None
    for c in cells:
        cx, cz = cells_to_world_xz(c[0], c[1])
        d2 = (cx - tx) ** 2 + (cz - tz) ** 2
        if best_d2 is None or d2 < best_d2:
            best_d2 = d2; best = c
    return best


def perimeter_cells_in_arc(cells, centre_cell, dir_vec, half_arc=0.6,
                           exclude_stem=False):
    """Find perimeter cells of `cells` whose direction from
    centre_cell is within ±half_arc radians of dir_vec. Returns list
    sorted by distance from centre, farthest first (so we pick true
    edge cells).

    If exclude_stem is True, drop perimeter cells in the south stem
    region (j < 1) where the south anchor entrance is. This keeps
    shortcut/sibling load_zones off the entrance corridor."""
    cx, cy = centre_cell
    dx, dy = dir_vec
    target_ang = math.atan2(dy, dx)
    out = []
    for c in cells:
        ci, cj = c
        if exclude_stem and cj < 1:
            continue
        # Perimeter: at least one neighbor outside.
        is_perim = False
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            if (ci + ddi, cj + ddj) not in cells:
                is_perim = True
                break
        if not is_perim:
            continue
        rdx = ci - cx
        rdy = cj - cy
        if rdx == 0 and rdy == 0:
            continue
        ang = math.atan2(rdy, rdx)
        diff = (ang - target_ang + math.pi) % (2 * math.pi) - math.pi
        if abs(diff) <= half_arc:
            d2 = rdx * rdx + rdy * rdy
            out.append((d2, c))
    out.sort(reverse=True)
    return [c for _, c in out]


# ---------------------------------------------------------------------------
# Main per-level processing
# ---------------------------------------------------------------------------

def process_algorithm_level(level_id, data, parent_of, children_of,
                            world_pos, trunk_dir, level_world_centre):
    """Mutates `data` in place. Returns dict of stats for the report."""
    parent = parent_of.get(level_id)
    kids = list(children_of.get(level_id, []))
    # Number of "real" children for shape selection — exclude the
    # grottos that were grafted in as cellar trapdoors (those don't
    # appear in the v3 tree's prong calculation).
    real_kids = [k for k in kids if k in PATH_MAP]

    n_kids = len(real_kids)
    if n_kids == 0:
        role = "leaf"
        spine_length = 24
    elif n_kids == 1:
        role = "single"
        spine_length = 28
    else:
        role = "multi"
        spine_length = 24

    big_city = level_id in BIG_CITY

    # Compute prong directions in LOCAL coords. Local +y = the level's
    # trunk_dir in world coords. So we rotate the world-relative child
    # offsets so that trunk_dir becomes local (0, 1).
    tdx, tdy = trunk_dir[level_id]
    # Rotation matrix that maps trunk_dir to (0, 1):
    #   [[ tdy, -tdx], [ tdx,  tdy ]]  (rotates trunk_dir → (0, 1))
    def world_to_local(wx, wy):
        lx = tdy * wx - tdx * wy
        ly = tdx * wx + tdy * wy
        return (lx, ly)

    my_wx, my_wy = world_pos[level_id]

    prong_dirs_local = []
    for k in real_kids:
        if k not in world_pos:
            continue
        kwx, kwy = world_pos[k]
        rdx = kwx - my_wx
        rdy = kwy - my_wy
        lx, ly = world_to_local(rdx, rdy)
        mag = math.hypot(lx, ly)
        if mag < 1e-6:
            prong_dirs_local.append((0.0, 1.0))
        else:
            prong_dirs_local.append((lx / mag, ly / mag))

    # Generate organic cells.
    cells, spine_cells = generate_cells(
        level_id, role, spine_length, n_kids, prong_dirs_local, big_city
    )

    # Connectivity check: keep only the connected component containing
    # the south anchor (0, -1) so isolated knots don't strand cells.
    south_anchor = (0, -1)
    cells.add(south_anchor)
    cells.add((0, -2))
    reachable = bfs_reachable(cells, south_anchor)
    cells = reachable
    if not cells:
        # Fallback: emit a small 12×12 square. Shouldn't happen.
        for i in range(-6, 6):
            for j in range(-6, 6):
                cells.add((i, j))

    # Determine north spine tip (post-connectivity) so prong load_zones
    # can find a perimeter cell along their direction from the centroid.
    tip_cell = spine_cells[-1] if spine_cells[-1] in cells else south_anchor
    centroid = (0, max(0, tip_cell[1] // 2))

    # Bounding box of the new footprint.
    is_ = [c[0] for c in cells]
    js_ = [c[1] for c in cells]
    bbox_i = (min(is_), max(is_))
    bbox_j = (min(js_), max(js_))

    # --- spawns ---
    spawns_out = []
    # `default` spawn sits a couple of cells inside from the south anchor.
    south_x, south_z = cells_to_world_xz(0, -1)
    spawns_out.append({
        "id": "default",
        "pos": [round(south_x, 2), 0.5, round(south_z, 2)],
        "rotation_y": math.pi,
    })

    # Spawn for each load_zone target. We figure out spawn ids from
    # existing load_zones (preserve them) plus parent.
    existing_lz = data.get("load_zones", [])
    seen_targets = set()
    # Map original target_scene → (target_spawn, prompt, size, auto)
    lz_meta = []
    for lz in existing_lz:
        ts = lz.get("target_scene")
        tsp = lz.get("target_spawn", "default")
        meta = {
            "target_scene": ts,
            "target_spawn": tsp,
            "prompt":       lz.get("prompt"),
            "size":         lz.get("size", [4.0, 3.0, 1.5]),
            "auto":         lz.get("auto", True),
            "rotation_y":   lz.get("rotation_y", 0.0),
        }
        lz_meta.append(meta)

    # If we have a parent and the existing lzs don't include the parent,
    # synthesize one. (Algorithm-owned dirs always had a parent edge, so
    # this is just defensive.)
    if parent is not None and parent not in [m["target_scene"] for m in lz_meta]:
        lz_meta.insert(0, {
            "target_scene": parent,
            "target_spawn": "from_" + level_id,
            "prompt": None,
            "size": [4.0, 3.0, 1.5],
            "auto": True,
            "rotation_y": 0.0,
        })

    # Now compute placement per load_zone.
    # We treat each load_zone's outward direction as the LOCAL direction
    # from this level's centre to the target's world_pos.
    # Self-targets (dev_loop's loop_*) get distributed around the bulb
    # perimeter on the east/west sides.
    self_target_count = sum(1 for m in lz_meta if m["target_scene"] == level_id)
    self_target_idx = 0

    # 360° distribution mode: when this hub has 4+ auto:true LZs, override
    # the world-direction-based local_dir with a canonical angle per LZ
    # so the doorways spread evenly around the perimeter rather than
    # crowding into one arc. Parent (south) is anchored; the rest fan
    # CW starting at +y (north).
    auto_meta = [m for m in lz_meta if m["auto"]]
    forced_angles = {}  # id(meta) -> radians
    if len(auto_meta) >= 4:
        # Separate parent vs others.
        non_parent = [m for m in auto_meta if m["target_scene"] != parent]
        M = len(non_parent)
        if M > 0:
            # Distribute M slots across 360°, first at +π/2 (north),
            # going CW. If a parent exists and M is even, shift the
            # start by half-step so no slot lands exactly at south.
            step = 2.0 * math.pi / M
            start = math.pi / 2.0
            if parent is not None and M > 0 and M % 2 == 0:
                start += step / 2.0
            for i, m in enumerate(non_parent):
                ang = start - step * i
                # Wrap into (-π, π]
                ang = ((ang + math.pi) % (2.0 * math.pi)) - math.pi
                forced_angles[id(m)] = ang

    new_lz_list = []
    extra_spawns = []
    used_spawn_ids = {"default"}
    # Track perimeter cells we've already dropped a load_zone on so we
    # don't stack two doors on the same cell.
    used_perim_cells = set()

    def _claim_perim_cell(candidates):
        """Pick the first candidate perimeter cell that's not yet used.
        Falls back to the closest unused cell anywhere on the perimeter."""
        for c in candidates:
            if c not in used_perim_cells:
                used_perim_cells.add(c)
                return c
        # all in arc are used — pick from full perimeter
        for c in cells:
            ci, cj = c
            if c in used_perim_cells:
                continue
            is_perim = False
            for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
                if (ci + ddi, cj + ddj) not in cells:
                    is_perim = True; break
            if is_perim:
                used_perim_cells.add(c)
                return c
        # exhausted: reuse the first candidate
        if candidates:
            return candidates[0]
        return (0, 0)

    # Grottoes (trap-door cellars) are always interior to the parent's
    # footprint — leave their parent's load_zone alone, they're auto:false.
    # For grotto LEVELS themselves, the parent is treated as south.

    for meta in lz_meta:
        ts = meta["target_scene"]
        if ts == parent:
            # Place at south anchor.
            local_dir = (0.0, -1.0)
            placement_cell = nearest_walking_cell(cells, cells_to_world_xz(0, -2)) or (0, -1)
            used_perim_cells.add(placement_cell)
            # Push the trigger one cell south of last walking cell.
            lz_pos_x, lz_pos_z = cells_to_world_xz(placement_cell[0], placement_cell[1])
            # Outward direction is -y (south) → push in -z direction.
            lz_pos_z -= CELL_SIZE * 0.5  # half cell south
            sp_x, sp_z = cells_to_world_xz(placement_cell[0], placement_cell[1])
            sp_rot = math.pi  # face south (toward parent)
        elif ts == level_id:
            # Self-target (dev_loop loops). Distribute around perimeter.
            angle = -math.pi / 2 + math.pi * (self_target_idx + 0.5) / max(1, self_target_count)
            self_target_idx += 1
            local_dir = (math.cos(angle), math.sin(angle))
            cand = perimeter_cells_in_arc(cells, centroid, local_dir, half_arc=0.5)
            placement_cell = _claim_perim_cell(cand)
            sp_x, sp_z = cells_to_world_xz(placement_cell[0], placement_cell[1])
            lz_pos_x = sp_x + local_dir[0] * CELL_SIZE * 0.5
            lz_pos_z = sp_z + local_dir[1] * CELL_SIZE * 0.5
            sp_rot = math.atan2(-local_dir[1], -local_dir[0])
        else:
            # Treat as a child / sibling / shortcut. Compute world
            # direction → local direction → put on the closest
            # perimeter cell along that direction.
            if id(meta) in forced_angles:
                # 360° distribution overrides world-direction.
                ang = forced_angles[id(meta)]
                local_dir = (math.cos(ang), math.sin(ang))
            else:
                tw = world_pos.get(ts)
                if tw is None:
                    # Unknown target. Default to north.
                    local_dir = (0.0, 1.0)
                else:
                    rdx = tw[0] - my_wx
                    rdy = tw[1] - my_wy
                    lx, ly = world_to_local(rdx, rdy)
                    mag = math.hypot(lx, ly)
                    if mag < 1e-6:
                        local_dir = (0.0, 1.0)
                    else:
                        local_dir = (lx / mag, ly / mag)
                    # If this target is a child of mine: it should be NORTH
                    # (positive local y). Force at least slightly +y so it
                    # ends up at the bulb.
                    if ts in real_kids and local_dir[1] < 0.2:
                        local_dir = (local_dir[0], 0.4)
                        # renormalize
                        m = math.hypot(*local_dir)
                        local_dir = (local_dir[0] / m, local_dir[1] / m)
            # Use the centroid (not (0,0)) so children pick perimeter
            # cells out at the bulb. Narrower initial arc means
            # neighbouring shortcut targets each get distinct cells.
            # exclude_stem keeps shortcuts off the south entrance corridor.
            cand = perimeter_cells_in_arc(
                cells, centroid, local_dir, half_arc=0.45, exclude_stem=True
            )
            if not [c for c in cand if c not in used_perim_cells]:
                # Widen arc to find an unused candidate.
                cand = perimeter_cells_in_arc(
                    cells, centroid, local_dir, half_arc=1.0, exclude_stem=True
                )
            if not [c for c in cand if c not in used_perim_cells]:
                # Last resort: allow stem cells too.
                cand = perimeter_cells_in_arc(
                    cells, centroid, local_dir, half_arc=1.4
                )
            placement_cell = _claim_perim_cell(cand)
            sp_x, sp_z = cells_to_world_xz(placement_cell[0], placement_cell[1])
            lz_pos_x = sp_x + local_dir[0] * CELL_SIZE * 0.5
            lz_pos_z = sp_z + local_dir[1] * CELL_SIZE * 0.5
            # Spawn faces back inward (180° from outward).
            sp_rot = math.atan2(-local_dir[1], -local_dir[0])

        new_lz = {
            "pos": [round(lz_pos_x, 2), 1.4, round(lz_pos_z, 2)],
            "size": meta["size"],
            "rotation_y": meta["rotation_y"],
            "target_scene": ts,
            "target_spawn": meta["target_spawn"],
        }
        if meta["prompt"]:
            new_lz["prompt"] = meta["prompt"]
        if not meta["auto"]:
            new_lz["auto"] = False
        new_lz_list.append(new_lz)

        # Add a spawn anchor for incoming traffic FROM this neighbour.
        # The id is "from_<this neighbour>". Place at the same cell as
        # the load_zone but pulled inward by ~1 cell so spawns are clear
        # of the trigger box.
        from_id = "from_" + ts
        if from_id not in used_spawn_ids:
            used_spawn_ids.add(from_id)
            inward_x = sp_x  # already a cell centre
            inward_z = sp_z
            extra_spawns.append({
                "id": from_id,
                "pos": [round(inward_x, 2), 0.5, round(inward_z, 2)],
                "rotation_y": sp_rot,
            })

    # Preserve any existing spawns whose ids we didn't already emit
    # (e.g. dev_loop's `loop_*` spawns aren't tied to load_zone targets).
    existing_spawns = data.get("spawns", [])
    for s in existing_spawns:
        sid = s.get("id")
        if sid in used_spawn_ids:
            continue
        if sid is None:
            continue
        # Re-bind position to nearest walking cell of new footprint.
        old_pos = s.get("pos", [0.0, 0.5, 0.0])
        cell = nearest_walking_cell(cells, (old_pos[0], old_pos[2]))
        if cell is None:
            cell = (0, 0)
        nx, nz = cells_to_world_xz(cell[0], cell[1])
        new_spawn = dict(s)
        new_spawn["pos"] = [round(nx, 2), float(old_pos[1]) if len(old_pos) > 1 else 0.5, round(nz, 2)]
        extra_spawns.append(new_spawn)
        used_spawn_ids.add(sid)

    spawns_out.extend(extra_spawns)

    # --- props re-bind ---
    rebound = 0
    new_props = []
    for p in data.get("props", []):
        # Drop previously-added pillar-cluster props (idempotent re-runs).
        if p.get("_pillar_cluster"):
            continue
        kind = p.get("type", "")
        if kind in ("npc", "sign", "chest", "owl_statue"):
            old_pos = p.get("pos", [0.0, 0.0, 0.0])
            cell = nearest_walking_cell(cells, (old_pos[0], old_pos[2]))
            if cell is None:
                new_props.append(p)
                continue
            new_x, new_z = cells_to_world_xz(cell[0], cell[1])
            np_ = dict(p)
            np_["pos"] = [round(new_x, 2),
                          float(old_pos[1]) if len(old_pos) > 1 else 0.0,
                          round(new_z, 2)]
            new_props.append(np_)
            rebound += 1
        else:
            # Pass-through (existing trees, rocks, bushes etc.)
            new_props.append(p)

    # --- pillar clusters between adjacent gaps ---
    # Compute gap angles in LOCAL frame (which matches the JSON's
    # local coordinates — both use +y/+z = north).
    gap_angles = []
    for lz in new_lz_list:
        # Use the outward direction from the centroid_world to the lz.
        cx_w, cz_w = cells_to_world_xz(centroid[0], centroid[1])
        gx, gz = lz["pos"][0], lz["pos"][2]
        ang = math.atan2(gz - cz_w, gx - cx_w)
        gap_angles.append(ang)

    # Detect wall material to choose pillar style: tree-walled levels
    # get tree+rock mixed clusters; stone-walled levels get rock-only
    # clusters (placing trees inside a stone room looks broken).
    floors_for_wm = data.get("grid", {}).get("floors", [])
    wall_material = "stone"
    if floors_for_wm:
        wall_material = floors_for_wm[0].get("wall_material", "stone")
    is_tree_wall = (wall_material == "tree")

    pillar_clusters_added = 0
    if len(gap_angles) >= 2:
        sorted_angles = sorted(gap_angles)
        # Estimate boundary radius from the cell footprint.
        boundary_r_cells = max(
            abs(bbox_i[0]), abs(bbox_i[1]),
            abs(bbox_j[0]), abs(bbox_j[1])
        )
        boundary_r = boundary_r_cells * CELL_SIZE + 1.5
        crng = random.Random("clusters::" + level_id)
        for k in range(len(sorted_angles)):
            a = sorted_angles[k]
            b = sorted_angles[(k + 1) % len(sorted_angles)]
            if k == len(sorted_angles) - 1:
                # wrap-around: shift b by 2π
                b += 2 * math.pi
            mid = (a + b) / 2.0
            # If the two adjacent gaps are very close (< 15°) skip — no
            # room for a cluster.
            if (b - a) < math.radians(15):
                continue
            ccx_w, ccz_w = cells_to_world_xz(centroid[0], centroid[1])
            cluster_x = ccx_w + math.cos(mid) * (boundary_r - 0.5)
            cluster_z = ccz_w + math.sin(mid) * (boundary_r - 0.5)
            if is_tree_wall:
                n_trees = crng.randint(3, 5)
                n_rocks = crng.randint(1, 2)
            else:
                # Stone-walled hubs: rock-only pillars (no out-of-place trees).
                n_trees = 0
                n_rocks = crng.randint(3, 5)
            for ti in range(n_trees):
                jx = crng.uniform(-1.6, 1.6)
                jz = crng.uniform(-1.6, 1.6)
                new_props.append({
                    "type": "tree",
                    "pos": [round(cluster_x + jx, 2), 0.0, round(cluster_z + jz, 2)],
                    "_pillar_cluster": True,
                })
            for ri in range(n_rocks):
                jx = crng.uniform(-1.4, 1.4)
                jz = crng.uniform(-1.4, 1.4)
                new_props.append({
                    "type": "rock",
                    "pos": [round(cluster_x + jx, 2), 0.0, round(cluster_z + jz, 2)],
                    "_pillar_cluster": True,
                })
            pillar_clusters_added += 1

    # --- write back into data ---
    grid = data.get("grid", {})
    if not grid:
        grid = {"cell_size": CELL_SIZE, "floors": [{}]}
        data["grid"] = grid
    grid["cell_size"] = CELL_SIZE
    floors = grid.get("floors", [])
    if not floors:
        floors = [{}]
        grid["floors"] = floors
    floor = floors[0]
    floor["cells"] = [[ci, cj] for (ci, cj) in sorted(cells)]
    # Preserve existing wall_height/colors etc.
    data["spawns"] = spawns_out
    data["load_zones"] = new_lz_list
    data["props"] = new_props

    return {
        "level": level_id,
        "role": role,
        "n_cells": len(cells),
        "bbox": (bbox_i[0], bbox_j[0], bbox_i[1], bbox_j[1]),
        "rebound": rebound,
        "pillar_clusters": pillar_clusters_added,
        "spawn_count": len(spawns_out),
        "lz_count": len(new_lz_list),
    }


# ---------------------------------------------------------------------------
# Pillar-cluster pass for handcrafted levels (light touch)
# ---------------------------------------------------------------------------

def add_pillar_clusters_handcrafted(level_id, data, parent_target=None):
    """Hand-crafted levels: between adjacent load_zones, add a cluster of
    pillar props at the perimeter so the gap-in-wall visual reads as a
    distinct doorway instead of an arbitrary opening in a featureless
    wall.

    Material rule:
      - tree-walled levels: tree-pillar clusters (3-5 trees + 1-2 rocks)
      - stone-walled levels: rock-pillar clusters (3-5 rocks, no trees)

    Additionally, for stone-walled hubs with 4+ auto:true load_zones,
    REDISTRIBUTE load_zone trigger positions evenly around the cell
    bbox perimeter (parent kept at south, others fan CW from north),
    and ADD perimeter knot bumps (4-8 small rock props at random spots
    just outside the cell bbox) so the silhouette doesn't read as a
    perfect rectangle.

    Skips levels that already use a tree_walls polygon (those carve
    gaps via tree_wall.gd's `gaps` system already)."""
    if data.get("tree_walls"):
        # Still strip stale pillar-cluster props for idempotency.
        data["props"] = [p for p in data.get("props", [])
                         if not p.get("_pillar_cluster")]
        return 0
    lzs = data.get("load_zones", [])
    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return 0
    cells_raw = floors[0].get("cells", [])
    if not cells_raw:
        return 0
    wall_material = floors[0].get("wall_material", "stone")
    is_tree_wall = (wall_material == "tree")
    cs = float(grid.get("cell_size", 1.0))
    # Centroid of cells (used for radial geometry).
    cx = sum((int(c[0]) + 0.5) * cs for c in cells_raw) / len(cells_raw)
    cz = sum((int(c[1]) + 0.5) * cs for c in cells_raw) / len(cells_raw)
    # Cell bbox in world coords.
    xs = [int(c[0]) for c in cells_raw]
    js = [int(c[1]) for c in cells_raw]
    bbox_x_min = min(xs) * cs
    bbox_x_max = (max(xs) + 1) * cs
    bbox_z_min = min(js) * cs
    bbox_z_max = (max(js) + 1) * cs
    bbox_half_x = (bbox_x_max - bbox_x_min) / 2.0
    bbox_half_z = (bbox_z_max - bbox_z_min) / 2.0
    bbox_cx = (bbox_x_min + bbox_x_max) / 2.0
    bbox_cz = (bbox_z_min + bbox_z_max) / 2.0

    # ---- Step A: 360° redistribution of LZ positions for big hubs. ----
    # Only for stone-walled (indoor / handcrafted hub) levels, since
    # tree-walled outdoor scenes already use the tree_wall gap system
    # for placement and have artistic positioning we shouldn't override.
    auto_lzs = [lz for lz in lzs if lz.get("auto", True)]
    redistributed = False
    if (not is_tree_wall) and len(auto_lzs) >= 4:
        # Identify parent LZ (the one whose target is this level's parent).
        parent_lz = None
        non_parent = []
        for lz in auto_lzs:
            if parent_target is not None and lz.get("target_scene") == parent_target:
                parent_lz = lz
            else:
                non_parent.append(lz)
        # Place parent at south on the bbox boundary.
        if parent_lz is not None:
            new_x = bbox_cx
            new_z = bbox_z_min - 0.5  # just outside south wall
            old = parent_lz["pos"]
            parent_lz["pos"] = [round(new_x, 2),
                                old[1] if len(old) > 1 else 1.4,
                                round(new_z, 2)]
        M = len(non_parent)
        if M > 0:
            step = 2.0 * math.pi / M
            start = math.pi / 2.0
            if parent_lz is not None and M % 2 == 0:
                start += step / 2.0
            for i, lz in enumerate(non_parent):
                ang = start - step * i
                # Project ray from bbox centre at this angle out to the
                # rectangular bbox boundary. (Compass-correct: angle 0 = +x,
                # π/2 = +z = north.)
                cax = math.cos(ang)
                caz = math.sin(ang)
                # Find scale t such that (t*cax, t*caz) hits the box boundary.
                if abs(cax) < 1e-9:
                    tx = float("inf")
                else:
                    tx = bbox_half_x / abs(cax)
                if abs(caz) < 1e-9:
                    tz = float("inf")
                else:
                    tz = bbox_half_z / abs(caz)
                t = min(tx, tz)
                # Push the trigger half a cell beyond the wall so it sits
                # on the boundary (player has to walk into it).
                t_outer = t + 0.5
                new_x = bbox_cx + cax * t_outer
                new_z = bbox_cz + caz * t_outer
                old = lz["pos"]
                lz["pos"] = [round(new_x, 2),
                             old[1] if len(old) > 1 else 1.4,
                             round(new_z, 2)]
        redistributed = True

    # Re-read positions for downstream calcs (in case we just moved them).
    angles = []
    for lz in lzs:
        if not lz.get("auto", True):
            continue  # skip cellar trapdoors (interior, not boundary)
        pos = lz.get("pos", [0, 0, 0])
        ang = math.atan2(pos[2] - cz, pos[0] - cx)
        angles.append((ang, pos))

    # Drop previously-added pillar-cluster props (idempotent re-runs)
    # — they're tagged with `_pillar_cluster: True`.
    new_props = [p for p in data.get("props", [])
                 if not p.get("_pillar_cluster")]

    added = 0
    if len(angles) >= 2:
        angles.sort(key=lambda a: a[0])
        # Mean radial distance for cluster placement.
        r = sum(math.hypot(p[0] - cx, p[2] - cz) for _, p in angles) / len(angles)
        crng = random.Random("clusters::handcrafted::" + level_id)
        for k in range(len(angles)):
            a_ang, _ = angles[k]
            b_ang, _ = angles[(k + 1) % len(angles)]
            if k == len(angles) - 1:
                b_ang += 2 * math.pi
            if (b_ang - a_ang) < math.radians(15):
                continue
            mid = (a_ang + b_ang) / 2.0
            # For stone-walled hubs after redistribution, project the
            # cluster onto the bbox boundary (rectangular wall) rather
            # than at a circular radius. For tree-walled (round-ish)
            # outdoor scenes, use the average radial distance.
            if not is_tree_wall:
                cax = math.cos(mid); caz = math.sin(mid)
                if abs(cax) < 1e-9:
                    tx = float("inf")
                else:
                    tx = bbox_half_x / abs(cax)
                if abs(caz) < 1e-9:
                    tz = float("inf")
                else:
                    tz = bbox_half_z / abs(caz)
                t = min(tx, tz) + 0.4
                ccx = bbox_cx + cax * t
                ccz = bbox_cz + caz * t
            else:
                ccx = cx + math.cos(mid) * (r + 1.5)
                ccz = cz + math.sin(mid) * (r + 1.5)
            if is_tree_wall:
                n_trees = crng.randint(3, 5)
                n_rocks = crng.randint(1, 2)
            else:
                n_trees = 0
                n_rocks = crng.randint(3, 5)
            for _ in range(n_trees):
                jx = crng.uniform(-1.6, 1.6)
                jz = crng.uniform(-1.6, 1.6)
                new_props.append({
                    "type": "tree",
                    "pos": [round(ccx + jx, 2), 0.0, round(ccz + jz, 2)],
                    "_pillar_cluster": True,
                })
            for _ in range(n_rocks):
                jx = crng.uniform(-1.4, 1.4)
                jz = crng.uniform(-1.4, 1.4)
                new_props.append({
                    "type": "rock",
                    "pos": [round(ccx + jx, 2), 0.0, round(ccz + jz, 2)],
                    "_pillar_cluster": True,
                })
            added += 1

    # ---- Step B: perimeter knot bumps for stone-walled hubs. ----
    # Break the perfect-rectangle silhouette by sprinkling a few rock
    # props at jittered positions just outside the cell bbox.
    if (not is_tree_wall) and len(cells_raw) >= 200:
        krng = random.Random("knot::handcrafted::" + level_id)
        n_bumps = krng.randint(4, 8)
        # Build a set of "claimed angles" so we don't put a bump right
        # where a doorway is.
        gap_angles_set = [a for a, _ in angles]

        def too_close_to_gap(ang_deg):
            for ga in gap_angles_set:
                ga_deg = math.degrees(ga)
                d = abs((ang_deg - ga_deg + 180) % 360 - 180)
                if d < 12:
                    return True
            return False

        placed = 0
        attempts = 0
        while placed < n_bumps and attempts < 60:
            attempts += 1
            ang = krng.uniform(-math.pi, math.pi)
            if too_close_to_gap(math.degrees(ang)):
                continue
            cax = math.cos(ang); caz = math.sin(ang)
            if abs(cax) < 1e-9:
                tx = float("inf")
            else:
                tx = bbox_half_x / abs(cax)
            if abs(caz) < 1e-9:
                tz = float("inf")
            else:
                tz = bbox_half_z / abs(caz)
            t = min(tx, tz) + krng.uniform(0.2, 1.4)
            bx = bbox_cx + cax * t
            bz = bbox_cz + caz * t
            new_props.append({
                "type": "rock",
                "pos": [round(bx, 2), 0.0, round(bz, 2)],
                "_pillar_cluster": True,
            })
            placed += 1

    # Always write back (so we strip stale clusters even if `added`==0).
    data["props"] = new_props
    return added


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main():
    parent_of, children_of, depth_of, root = build_tree()
    world_pos, trunk_dir = compute_layout(root, parent_of, children_of)

    # Sanity print.
    n_levels = len(PATH_MAP)
    print("tree built: %d levels rooted at %s" % (n_levels, root))

    grown_stats = []
    handcrafted_clusters = 0
    handcrafted_touched = 0
    total_rebound = 0

    # Re-read every level from JSON (avoid stale state).
    levels = {}
    for fn in sorted(os.listdir(DUNGEONS)):
        if not fn.endswith(".json"):
            continue
        lid = fn[:-5]
        with open(os.path.join(DUNGEONS, fn)) as f:
            levels[lid] = (fn, json.load(f))

    for lid, (fn, data) in levels.items():
        if lid in ALGO_OWNED and lid in world_pos:
            stats = process_algorithm_level(
                lid, data, parent_of, children_of, world_pos, trunk_dir,
                level_world_centre=world_pos.get(lid, (0.0, 0.0))
            )
            grown_stats.append(stats)
            total_rebound += stats["rebound"]
        elif lid in PATH_MAP:
            # handcrafted level — pillar-cluster pass + perimeter knots
            # + (for stone-walled big hubs) 360° LZ redistribution.
            parent_target = parent_of.get(lid)
            added = add_pillar_clusters_handcrafted(lid, data, parent_target)
            if added > 0:
                handcrafted_clusters += added
                handcrafted_touched += 1

    # Write back.
    for lid, (fn, data) in levels.items():
        with open(os.path.join(DUNGEONS, fn), "w") as f:
            json.dump(data, f, indent=2)

    # ---- report ----
    print()
    print("=" * 60)
    print("REGROWN: %d algorithm-owned levels" % len(grown_stats))
    print("HANDCRAFTED touched (pillar clusters added): %d" % handcrafted_touched)
    print("PROPS rebound (NPC/sign/chest/owl): %d" % total_rebound)
    print("PILLAR CLUSTERS placed (algorithm-owned): %d" %
          sum(s["pillar_clusters"] for s in grown_stats))
    print("PILLAR CLUSTERS placed (handcrafted seam): %d" % handcrafted_clusters)
    print()
    print("per-level breakdown:")
    for s in grown_stats:
        bx0, bz0, bx1, bz1 = s["bbox"]
        print("  %-22s role=%-7s cells=%4d bbox=(%3d..%3d, %3d..%3d) "
              "spawns=%d lzs=%d clusters=%d rebound=%d" % (
                  s["level"], s["role"], s["n_cells"],
                  bx0, bx1, bz0, bz1,
                  s["spawn_count"], s["lz_count"],
                  s["pillar_clusters"], s["rebound"]))


if __name__ == "__main__":
    main()
