#!/usr/bin/env python3
"""grow_filesystem.py — the L-system rooting algorithm (FILESYSTEM.md §v6).

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
  - re-binds existing handcrafted props (NPCs, signs, chests,
    owl_statues) of those levels to the nearest valid walking cell

For handcrafted hub levels (stone-walled, >=2 auto LZs OR >=800 cells),
it now also UNIONS in a circular blob of cells centred on the existing
hub's centroid (v6) so the silhouette reads as round-with-protrusions,
not as a perfect square. Original cells are always preserved.

v6 also strips ALL legacy `_pillar_cluster` props — pillar clusters were
a v2 silhouette-breaker that no longer makes sense now that each arm is
a distinct corridor with tree-wall gaps between arms. The remaining
perimeter knot bumps (off-bbox rocks) stay since they don't sit in paths.

Arms in v6 are blobular: width baseline 8..16, multi-scale Perlin
variation ±4 along their length, occasional oval "bulb" stamps every
10-15 cells. Each arm reads as a string of bulbs, not a uniform tube.

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
    base_r_mid = 10  # was 6 — wider body
    if big_city:
        base_r_mid = 18  # was 11 — wider wide-bulge city body
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
        bulb_r = 16  # was 8 — 2x larger leaf bulb
        for di in range(-bulb_r - 1, bulb_r + 2):
            for dj in range(-bulb_r - 1, bulb_r + 2):
                jitter = perlin1d(seed + ":bulb",
                                  (di * 0.7) + (dj * 0.31)) * 2.5
                if di * di + dj * dj <= (bulb_r + jitter) ** 2:
                    cells.add((last_sx + di, last_sy + dj))
    elif role == "single":
        # Spine merges into the child's stem — no extra bulb. Round
        # the tip a bit so it's not a flat plate.
        for di in range(-6, 7):
            for dj in range(-4, 5):
                if di * di + dj * dj <= 32:
                    cells.add((last_sx + di, last_sy + dj))
    else:
        # multi-child junction: fat bulb + prongs to each child.
        bulb_r = 16 if not big_city else 22  # was 8/12 — 2x larger hub bulbs
        for di in range(-bulb_r - 1, bulb_r + 2):
            for dj in range(-bulb_r - 1, bulb_r + 2):
                jitter = perlin1d(seed + ":hub",
                                  (di * 0.5) + (dj * 0.27)) * 2.5
                if di * di + dj * dj <= (bulb_r + jitter) ** 2:
                    cells.add((last_sx + di, last_sy + dj))
        # Prongs reaching toward each child.
        prong_len = 12  # was 6
        for cd in prong_dirs_local:
            cdx, cdy = cd
            for step in range(1, prong_len + 1):
                cx = last_sx + int(round(cdx * step))
                cy = last_sy + int(round(cdy * step))
                # 5-cell-wide prong (perpendicular to direction).
                pdx, pdy = -cdy, cdx  # perpendicular in 2D
                for j in range(-2, 3):
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
    # the spine start. Carve a 6-cell-wide entrance (was 4).
    for j in range(-2, spine_cells[0][1] + 2):
        for i in range(-4, 5):
            cells.add((i, j))

    # 6. Sanity: minimum 24x24 effective cell-rect (was 12). Bigger
    # baselines for multi-child hubs (32) and big-city (60).
    cells = _ensure_min_size(cells, level_id, role, big_city, last_sx, last_sy)

    return cells, spine_cells


def _ensure_min_size(cells, level_id, role, big_city, cx, cy):
    """Pad the bulb area with concentric circles until the bbox meets
    the required minimum dimensions."""
    min_dim = 24  # was 12 — 2x baseline
    if role == "multi":
        min_dim = 32  # was 18
    if big_city:
        min_dim = 60  # was 40
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
        spine_length = 48  # was 24 — 3x scale-up for fatter leaves
    elif n_kids == 1:
        role = "single"
        spine_length = 56  # was 28
    else:
        role = "multi"
        spine_length = 48  # was 24

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
        # Drop previously-added pillar-cluster AND perimeter-knot props
        # (idempotent re-runs). Knot props will be re-emitted via the
        # handcrafted pass below if applicable.
        if p.get("_pillar_cluster"):
            continue
        if p.get("_perimeter_knot"):
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
    # REMOVED in v6: pillar clusters used to be placed at the angular
    # midpoint between adjacent LZ gaps to break the silhouette. Now
    # that each LZ has its own arm corridor (with tree-wall walls
    # between arms) those pillars sit inside or alongside the corridor,
    # looking like rocks blocking the path. v6 emits zero pillar
    # clusters and strips any stale ones (handled in main()).
    pillar_clusters_added = 0

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
    """Hand-crafted hubs (v6):
      - For stone-walled hubs with 4+ auto:true load_zones, REDISTRIBUTE
        load_zone trigger positions evenly around the cell bbox
        perimeter (parent kept at south, others fan CW from north).
      - ADD a few perimeter knot bumps (4-8 small rock props at random
        spots just outside the cell bbox) so the silhouette doesn't
        read as a perfect rectangle. These sit OUTSIDE the bbox so they
        don't clutter walking paths.

    v6 NO LONGER emits angular-gap pillar clusters — those rocks ended
    up sitting in arm corridors after the arm-growth pass. Knot bumps
    only.

    Skips levels that already use a tree_walls polygon."""
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
            # Invalidate the cached pre-arm pos: this pos is the new
            # canonical anchor, replacing whatever was cached previously.
            parent_lz.pop("_pre_arm_pos", None)
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
                lz.pop("_pre_arm_pos", None)
        redistributed = True

    # Re-read positions for downstream calcs (in case we just moved them).
    angles = []
    for lz in lzs:
        if not lz.get("auto", True):
            continue  # skip cellar trapdoors (interior, not boundary)
        # Use the cached pre-arm pos (canonical bbox-edge anchor) if
        # present so subsequent runs see stable angles, regardless of
        # where the arm pass last pushed the LZ.
        pos_for_ang = lz.get("_pre_arm_pos") or lz.get("pos", [0, 0, 0])
        ang = math.atan2(pos_for_ang[2] - cz, pos_for_ang[0] - cx)
        angles.append((ang, lz.get("pos", [0, 0, 0])))

    # Drop ALL previously-added pillar-cluster AND perimeter-knot props
    # (idempotent re-runs). v6: gap pillars permanently disabled; knot
    # props are re-emitted below in Step B.
    new_props = [p for p in data.get("props", [])
                 if not p.get("_pillar_cluster")
                 and not p.get("_perimeter_knot")]

    added = 0  # v6: pillar clusters disabled — always zero.

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
                # _perimeter_knot (v6): separate tag from _pillar_cluster so
                # these off-bbox silhouette-breaker rocks survive the v6
                # pillar-cluster strip pass. They sit OUTSIDE the bbox so
                # they never end up in arm corridors.
                "_perimeter_knot": True,
            })
            placed += 1

    # Always write back (so we strip stale clusters even if `added`==0).
    data["props"] = new_props
    return added


# ---------------------------------------------------------------------------
# Cell-arm growing pass (FILESYSTEM.md §v4 — "hub + branches" silhouette)
# ---------------------------------------------------------------------------
#
# Rationale:
#   Even after rooting v1+v2, multi-child hubs read as flat squares with
#   doorway-marks on the perimeter. The bounding box of Crown is a perfect
#   32x32 box and all 17 load_zones sit on its edge. There's no visible
#   "branching" — the silhouette doesn't read as a hub-with-arms.
#
# Solution:
#   For every level with >= 2 outgoing auto:true load_zones, grow a
#   cell-arm per load_zone reaching outward from the existing footprint
#   to the LZ's direction. Each arm is a 3-cell-wide corridor 8-14 cells
#   long with a slight Perlin-noise curve, terminating exactly where the
#   load_zone trigger now sits. The matching from_<X> spawn moves with
#   the LZ to the arm tip, so the player walks back into the corridor on
#   re-entry.
#
# Idempotency:
#   We track every arm cell we add in floor["_arm_cells"] (a flat list
#   of [i,j]). On re-run, we strip those cells from floor["cells"] and
#   re-grow from scratch using the same deterministic seed, so re-running
#   yields the same result.
#
# What is preserved:
#   - All non-arm cells (the hub footprint stays put).
#   - All NPCs, signs, chests, owl_statues, props (they're inside the
#     hub which doesn't move).
#   - Each LZ's target_scene/target_spawn/size/prompt/auto/rotation_y
#     fields stay intact — only `pos` is updated to the arm tip.
#   - _pillar_cluster props (rooting v2) — pillars sit in the angular
#     gap between adjacent arms, which is still correct.
# ---------------------------------------------------------------------------


def _strip_arm_cells(data):
    """Remove previously-added arm cells from the floor's cell list.
    Returns count stripped. Idempotent: safe to call repeatedly."""
    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return 0
    floor = floors[0]
    arm_set = set()
    for c in floor.get("_arm_cells", []) or []:
        try:
            arm_set.add((int(c[0]), int(c[1])))
        except (TypeError, ValueError, IndexError):
            continue
    if not arm_set:
        return 0
    new_cells = []
    stripped = 0
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            ci, cj = int(c.get("i", 0)), int(c.get("j", 0))
        else:
            ci, cj = int(c[0]), int(c[1])
        if (ci, cj) in arm_set:
            stripped += 1
            continue
        new_cells.append(c)
    floor["cells"] = new_cells
    floor["_arm_cells"] = []
    return stripped


def _existing_cell_set(floor):
    """Return set of (i,j) of cells currently in the floor."""
    s = set()
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            s.add((int(c.get("i", 0)), int(c.get("j", 0))))
        else:
            s.add((int(c[0]), int(c[1])))
    return s


def _strip_organic_bulge_cells(data):
    """Remove previously-added organic-bulge cells from the floor.
    Returns count stripped. Idempotent."""
    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return 0
    floor = floors[0]
    bulge_set = set()
    for c in floor.get("_organic_bulge_cells", []) or []:
        try:
            bulge_set.add((int(c[0]), int(c[1])))
        except (TypeError, ValueError, IndexError):
            continue
    if not bulge_set:
        return 0
    new_cells = []
    stripped = 0
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            ci, cj = int(c.get("i", 0)), int(c.get("j", 0))
        else:
            ci, cj = int(c[0]), int(c[1])
        if (ci, cj) in bulge_set:
            stripped += 1
            continue
        new_cells.append(c)
    floor["cells"] = new_cells
    floor["_organic_bulge_cells"] = []
    return stripped


def _strip_blob_cells(data):
    """Remove previously-added circular-blob cells from the floor.
    Returns count stripped. Idempotent."""
    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return 0
    floor = floors[0]
    blob_set = set()
    for c in floor.get("_blob_cells", []) or []:
        try:
            blob_set.add((int(c[0]), int(c[1])))
        except (TypeError, ValueError, IndexError):
            continue
    if not blob_set:
        return 0
    new_cells = []
    stripped = 0
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            ci, cj = int(c.get("i", 0)), int(c.get("j", 0))
        else:
            ci, cj = int(c[0]), int(c[1])
        if (ci, cj) in blob_set:
            stripped += 1
            continue
        new_cells.append(c)
    floor["cells"] = new_cells
    floor["_blob_cells"] = []
    return stripped


def make_circular_blob_for_level(level_id, data):
    """Union the existing rectangular hub footprint with a circular-blob
    footprint centred on the centroid of the original cells, with a
    Perlin-perturbed edge.

    Effective radius `r = sqrt(cell_count / pi) * 1.2` (slight expansion
    so the blob extends past the square's corners).

    Original cells are ALWAYS preserved (union). So content placement
    (NPCs / signs / chests / spawns / load_zones) on a now-outside-the-
    blob cell still sits on a valid walking cell.

    Skips:
      - tree_walls levels (their boundary is polygon-defined; we don't
        edit cells there)
      - levels with fewer than 200 cells (too small to be considered a hub)

    Tags new cells with floor['_blob_cells'] for idempotent re-runs.
    Returns count of cells added.
    """
    if data.get("tree_walls"):
        _strip_blob_cells(data)
        return 0

    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return 0
    floor = floors[0]

    # Clean up any previous blob cells first.
    _strip_blob_cells(data)

    cells_set = _existing_cell_set(floor)
    if len(cells_set) < 200:
        return 0

    # Determine the "core" footprint to measure the centroid and cell
    # count from: original handcrafted cells, NOT v4 arm cells or v5
    # bulge cells (those would skew the centroid outward and inflate
    # the radius). The strip helpers run before us in main(), but as a
    # belt-and-braces measure compute the core directly here too.
    arm_set = set()
    for c in floor.get("_arm_cells", []) or []:
        try:
            arm_set.add((int(c[0]), int(c[1])))
        except (TypeError, ValueError, IndexError):
            continue
    bulge_set = set()
    for c in floor.get("_organic_bulge_cells", []) or []:
        try:
            bulge_set.add((int(c[0]), int(c[1])))
        except (TypeError, ValueError, IndexError):
            continue
    core = cells_set - arm_set - bulge_set
    if len(core) < 200:
        # Most stone-walled hubs strip to >=256 core cells; bail if not.
        return 0

    # Centroid in cell units.
    cx = sum(c[0] for c in core) / len(core)
    cz = sum(c[1] for c in core) / len(core)
    n = len(core)
    r = math.sqrt(n / math.pi) * 1.2

    seed = "fs::blob::" + level_id

    # Stamp circular blob with Perlin-perturbed radius.
    # Bounding square: 2.4 * r (per spec).
    half_bb = int(math.ceil(r * 1.2)) + 2  # 2.4 / 2 = 1.2
    ci_int = int(round(cx))
    cj_int = int(round(cz))
    new_blob = set()
    for di in range(-half_bb, half_bb + 1):
        for dj in range(-half_bb, half_bb + 1):
            ii = ci_int + di
            jj = cj_int + dj
            d = math.hypot(ii - cx, jj - cz)
            # Perlin perturbation on the radius — sample 2D-ish via a
            # diagonal index so the edge has organic wavelength.
            phase = (ii * 0.21) + (jj * 0.17)
            jitter = perlin1d(seed + ":r", phase) * (r * 0.18)
            noisy_r = r + jitter
            if d < noisy_r:
                if (ii, jj) not in cells_set:
                    new_blob.add((ii, jj))

    if not new_blob:
        return 0

    # Append to floor.cells.
    existing_entries = list(floor.get("cells", []))
    blob_list = []
    for (i, j) in sorted(new_blob):
        existing_entries.append([i, j])
        blob_list.append([i, j])
    floor["cells"] = existing_entries
    floor["_blob_cells"] = blob_list
    return len(blob_list)


def grow_organic_bulge_for_level(level_id, data):
    """Add Perlin-noisy organic bulges to the perimeter of the existing
    cell footprint. Used for handcrafted hubs (and algorithm multi-hubs)
    so the silhouette no longer reads as a flat rectangle/circle.

    Walks the perimeter cells; with probability ~0.5 each, extends outward
    by 1-3 cells in a slightly off-perpendicular angle (perturbed by
    Perlin noise). The bulge's outward direction is the average outward
    normal at that cell, rotated by a small per-cell Perlin angle.

    Tags new cells via floor['_organic_bulge_cells'] for idempotency.
    Skips levels with tree_walls (those use polygon walls instead).

    Returns count of cells added.
    """
    if data.get("tree_walls"):
        # Still strip stale bulge cells for idempotency.
        _strip_organic_bulge_cells(data)
        return 0

    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return 0
    floor = floors[0]

    # Strip previous bulge for clean regen.
    _strip_organic_bulge_cells(data)

    cells_set_all = _existing_cell_set(floor)
    if len(cells_set_all) < 50:
        # Don't bulge tiny levels; they'd be overwhelmed.
        return 0

    # Use the LARGEST 4-connected component as the perimeter source so we
    # don't grow bulges around stranded sub-islands (some pre-existing
    # handcrafted levels — mirelake, burnt_hollow — have legitimately
    # disconnected core cells that we shouldn't decorate).
    # Find components.
    visited = set()
    components = []
    for c in cells_set_all:
        if c in visited:
            continue
        seen = {c}
        stack = [c]
        while stack:
            ci, cj = stack.pop()
            for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
                nb = (ci + ddi, cj + ddj)
                if nb in cells_set_all and nb not in seen:
                    seen.add(nb)
                    stack.append(nb)
        visited |= seen
        components.append(seen)
    components.sort(key=len, reverse=True)
    cells_set = components[0] if components else cells_set_all

    seed = "fs::bulge::" + level_id
    rng = random.Random(seed)

    # Find perimeter cells: cells with at least one 4-neighbor outside.
    perim = []
    for (ci, cj) in cells_set:
        out_normals = []
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            if (ci + ddi, cj + ddj) not in cells_set:
                out_normals.append((ddi, ddj))
        if out_normals:
            # Average outward normal.
            nx = sum(n[0] for n in out_normals)
            ny = sum(n[1] for n in out_normals)
            mag = math.hypot(nx, ny)
            if mag < 1e-6:
                continue
            perim.append(((ci, cj), (nx / mag, ny / mag)))

    if not perim:
        return 0

    # Walk perimeter; with prob 0.5, extend outward by 1-3 cells in a
    # Perlin-noisy bulge. We stamp filled rectangles at each step (not
    # just perpendicular sticks) so bulges are guaranteed 4-connected to
    # the source perimeter cell.
    new_cells = set()
    for (cell, (nx, ny)) in perim:
        ci, cj = cell
        if rng.random() > 0.5:
            continue
        # Extension length 1-3, weighted toward 2.
        ext = rng.choices([1, 2, 3, 4], weights=[2, 3, 2, 1])[0]
        # Perlin-perturb the outward angle slightly so bulges aren't
        # perfectly perpendicular.
        t_phase = (ci * 0.137) + (cj * 0.219)
        ang_perturb = perlin1d(seed + ":ang", t_phase) * 0.6  # ~±35°
        base_ang = math.atan2(ny, nx)
        ang = base_ang + ang_perturb
        bx, by = math.cos(ang), math.sin(ang)
        # For every extension step, stamp a 3x3 (or larger) BLOCK
        # centred on the outward cell. The block's anchor cell at step=1
        # is guaranteed to be a 4-neighbor of the source perimeter cell
        # (because we stamp a block of ≥3 cells in each axis). Subsequent
        # steps stamp blocks that overlap the previous step's block.
        prev_block_centre = (ci, cj)
        for step in range(1, ext + 1):
            # Outward centre.
            ti = ci + bx * step
            tj = cj + by * step
            ai = int(round(ti))
            aj = int(round(tj))
            # Half-width of the block along each axis (so block is 3x3
            # for step=1, 5x5 for step=2, 3x3 thereafter).
            half_w = 2 if step == 2 else 1
            for ddi in range(-half_w, half_w + 1):
                for ddj in range(-half_w, half_w + 1):
                    pi = ai + ddi
                    pj = aj + ddj
                    if (pi, pj) not in cells_set:
                        new_cells.add((pi, pj))
            # Bridge: ensure block centre and prev block centre are
            # 4-connected via a swept line.
            pci, pcj = prev_block_centre
            steps_b = max(abs(ai - pci), abs(aj - pcj))
            if steps_b > 0:
                for sb in range(1, steps_b + 1):
                    bi_ = pci + (ai - pci) * sb // steps_b
                    bj_ = pcj + (aj - pcj) * sb // steps_b
                    for ddi in (-1, 0, 1):
                        for ddj in (-1, 0, 1):
                            pi = bi_ + ddi
                            pj = bj_ + ddj
                            if (pi, pj) not in cells_set:
                                new_cells.add((pi, pj))
            prev_block_centre = (ai, aj)

    # Connectivity filter: only keep new cells that are 4-connected to
    # either the existing footprint or transitively to another new cell
    # that is. This guarantees the bulge can be reached from the hub.
    union = cells_set | new_cells
    seed_anchors = [c for c in new_cells
                    if any((c[0] + ddi, c[1] + ddj) in cells_set
                           for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)])]
    reachable = set(seed_anchors)
    stack = list(seed_anchors)
    while stack:
        ci, cj = stack.pop()
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            nb = (ci + ddi, cj + ddj)
            if nb in new_cells and nb not in reachable:
                reachable.add(nb)
                stack.append(nb)
    new_cells = reachable

    if not new_cells:
        floor["_organic_bulge_cells"] = []
        return 0

    # Append new cells to floor.cells.
    existing_entries = list(floor.get("cells", []))
    bulge_list = []
    for (i, j) in sorted(new_cells):
        existing_entries.append([i, j])
        bulge_list.append([i, j])
    floor["cells"] = existing_entries
    floor["_organic_bulge_cells"] = bulge_list
    return len(bulge_list)


def _radius_along_direction(cells_set, cx, cz, dx, dz, max_search=200):
    """Walk outward from (cx, cz) along (dx, dz) and return the distance
    (in cells) to the LAST cell that is still inside the cell set.
    Used to find where an arm should start (just past the hub edge)."""
    last_inside = 0
    for step in range(max_search):
        ti = int(round(cx + dx * step))
        tj = int(round(cz + dz * step))
        if (ti, tj) in cells_set:
            last_inside = step
    return last_inside


def _nearest_perimeter_cell_in_dir(cells_set, cx, cz, dx, dz, max_search=400):
    """Return the perimeter cell of `cells_set` closest to the ray from
    (cx, cz) in direction (dx, dz). Walks the ray and returns the LAST
    cell still inside. If no cell is inside on the ray, picks the
    perimeter cell minimising the angular distance to the ray.

    Returned as (i, j). Always returns SOMETHING if cells_set is non-empty.
    """
    if not cells_set:
        return None
    # Walk along ray.
    last_inside = None
    for step in range(max_search):
        ti = int(round(cx + dx * step))
        tj = int(round(cz + dz * step))
        if (ti, tj) in cells_set:
            last_inside = (ti, tj)
        elif last_inside is not None:
            # We've left the footprint; last_inside is the perimeter cell.
            return last_inside
    if last_inside is not None:
        return last_inside
    # Ray missed entirely; pick perimeter cell with smallest angular delta.
    target_ang = math.atan2(dz, dx)
    best = None; best_d = None
    for (ci, cj) in cells_set:
        # Quick perimeter check.
        is_perim = False
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            if (ci + ddi, cj + ddj) not in cells_set:
                is_perim = True
                break
        if not is_perim:
            continue
        rdx = ci - cx
        rdz = cj - cz
        if rdx == 0 and rdz == 0:
            continue
        a = math.atan2(rdz, rdx)
        diff = abs((a - target_ang + math.pi) % (2 * math.pi) - math.pi)
        # Combine angular and distance for tiebreak.
        score = diff
        if best_d is None or score < best_d:
            best_d = score
            best = (ci, cj)
    return best


def _bfs_reachable_set(cells_set, start):
    """4-connected BFS reachable cells from `start` within `cells_set`.
    Returns the reachable set (a subset of cells_set). If `start` is not
    in cells_set, returns empty set."""
    if start not in cells_set:
        return set()
    seen = {start}
    stack = [start]
    while stack:
        ci, cj = stack.pop()
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            nb = (ci + ddi, cj + ddj)
            if nb in cells_set and nb not in seen:
                seen.add(nb)
                stack.append(nb)
    return seen


def grow_arms_for_level(level_id, data, level_seed_extra=""):
    """Add cell-arms reaching from the existing hub out to each
    auto:true load_zone. Mutates `data` in place. Returns dict of stats:
        {arm_count, arm_cells_added, before_n_cells, after_n_cells,
         before_bbox, after_bbox, sample_arm_distance}.
    Skips levels with < 2 auto:true LZs."""
    lzs = data.get("load_zones", [])
    auto_lzs = [lz for lz in lzs if lz.get("auto", True)]
    if len(auto_lzs) < 2:
        # Strip stale arm cells just in case (idempotency).
        _strip_arm_cells(data)
        return {
            "level": level_id,
            "arm_count": 0,
            "arm_cells_added": 0,
            "before_n_cells": 0,
            "after_n_cells": 0,
            "before_bbox": None,
            "after_bbox": None,
            "sample_arm_distance": 0.0,
            "skipped": True,
        }

    # Strip previously-added arm cells (idempotency).
    _strip_arm_cells(data)

    grid = data.get("grid", {})
    floors = grid.get("floors", [])
    if not floors:
        return {
            "level": level_id,
            "arm_count": 0,
            "arm_cells_added": 0,
            "before_n_cells": 0,
            "after_n_cells": 0,
            "before_bbox": None,
            "after_bbox": None,
            "sample_arm_distance": 0.0,
            "skipped": True,
        }
    floor = floors[0]
    cs = float(grid.get("cell_size", CELL_SIZE))

    # tree_walls levels: their boundary is an explicit polygon, growing
    # arms via cells doesn't extend the boundary. Skip them.
    if data.get("tree_walls"):
        return {
            "level": level_id,
            "arm_count": 0,
            "arm_cells_added": 0,
            "before_n_cells": 0,
            "after_n_cells": 0,
            "before_bbox": None,
            "after_bbox": None,
            "sample_arm_distance": 0.0,
            "skipped": True,
        }

    cells_set = _existing_cell_set(floor)
    if not cells_set:
        return {
            "level": level_id,
            "arm_count": 0,
            "arm_cells_added": 0,
            "before_n_cells": 0,
            "after_n_cells": 0,
            "before_bbox": None,
            "after_bbox": None,
            "sample_arm_distance": 0.0,
            "skipped": True,
        }

    is_ = [c[0] for c in cells_set]
    js_ = [c[1] for c in cells_set]
    before_bbox = (min(is_), min(js_), max(is_), max(js_))
    before_n_cells = len(cells_set)
    # Centroid of existing cells (in cell units).
    cx = sum(c[0] for c in cells_set) / len(cells_set)
    cz = sum(c[1] for c in cells_set) / len(cells_set)

    # Compute outward direction and starting angle for each LZ.
    #
    # Idempotency: if the LZ has a cached `_pre_arm_pos` (we recorded it
    # the first time we grew an arm for this LZ), use that fixed
    # position to compute the outward angle. Otherwise capture the
    # current pos AS the canonical pre-arm pos and use it. This prevents
    # the LZ position from drifting on each subsequent run when the
    # handcrafted-pass doesn't redistribute (i.e. hubs with < 4 auto LZs).
    #
    # If two LZs end up at very similar angles, we nudge them apart by
    # >= 8 degrees so the arms don't fuse.
    lz_dirs = []  # list of (lz, angle_rad, current_distance_world_units)
    for lz in auto_lzs:
        pre_pos = lz.get("_pre_arm_pos")
        if pre_pos is None:
            pre_pos = list(lz.get("pos", [0, 0, 0]))
            lz["_pre_arm_pos"] = [float(pre_pos[0]),
                                  float(pre_pos[1]) if len(pre_pos) > 1 else 1.4,
                                  float(pre_pos[2]) if len(pre_pos) > 2 else 0.0]
        ref_x = float(pre_pos[0])
        ref_z = float(pre_pos[2]) if len(pre_pos) > 2 else 0.0
        dx_world = ref_x - (cx + 0.5) * cs
        dz_world = ref_z - (cz + 0.5) * cs
        ang = math.atan2(dz_world, dx_world)
        dist = math.hypot(dx_world, dz_world)
        lz_dirs.append([lz, ang, dist])

    # Resolve angle clashes: sort by angle, then walk and ensure each
    # adjacent pair differs by >= MIN_SEP. If not, push the later one CCW.
    MIN_SEP = math.radians(8)
    lz_dirs.sort(key=lambda x: x[1])
    for i in range(1, len(lz_dirs)):
        prev_ang = lz_dirs[i - 1][1]
        if lz_dirs[i][1] - prev_ang < MIN_SEP:
            lz_dirs[i][1] = prev_ang + MIN_SEP
    # Also handle wrap-around: last vs first + 2pi.
    if len(lz_dirs) >= 2:
        wrap_diff = (lz_dirs[0][1] + 2 * math.pi) - lz_dirs[-1][1]
        if wrap_diff < MIN_SEP:
            # Distribute the deficit by nudging the last one CW.
            lz_dirs[-1][1] -= (MIN_SEP - wrap_diff)

    seed = "arms::" + level_id + level_seed_extra
    rng = random.Random(seed)

    arm_cells_added = []  # list of (i, j) — also recorded into floor
    new_cell_entries = []  # plain [i, j] entries to append to floor.cells
    sample_arm_distance = 0.0

    # Hub centroid (snapped) used for BFS reachability checks below.
    hub_centroid_cell = (int(round(cx)), int(round(cz)))
    if hub_centroid_cell not in cells_set:
        # Snap to nearest cell.
        hub_centroid_cell = nearest_walking_cell(cells_set, cells_to_world_xz(*hub_centroid_cell)) or next(iter(cells_set))

    for lz_idx, (lz, ang, _old_dist) in enumerate(lz_dirs):
        dx = math.cos(ang)
        dz = math.sin(ang)

        # Per-LZ deterministic RNG.
        arm_seed = seed + ":lz:" + str(lz_idx) + ":" + str(lz.get("target_scene", ""))
        arm_rng = random.Random(arm_seed)

        # v6 width per arm: random uniform 8..16 (was 6..12).
        # Multi-scale Perlin variation along the length (see step loop)
        # gives ±4 swings — wider chambers / pinch points rather than a
        # smooth tube. Min width clamped to 8 throughout.
        base_arm_width = arm_rng.randint(8, 16)

        # Length per arm: random uniform 36..60 (no change in v6).
        arm_length = arm_rng.randint(36, 60)

        # v6 random bulb stamps: every ~10-15 cells along the arm, with
        # probability 0.4, place a disc 1.6× the local width radius at
        # the centre, so each arm reads as a string of bulbs rather than
        # a smooth corridor. Pre-compute the bulb anchor steps so the
        # main loop can stamp them on the fly.
        bulb_steps = set()
        s = arm_rng.randint(10, 15)
        while s < arm_length - 2:
            if arm_rng.random() < 0.4:
                bulb_steps.add(s)
            s += arm_rng.randint(10, 15)

        # Anchor: nearest perimeter cell of the existing hub in the
        # outward direction (NOT existing_reach + 1, which left a gap).
        anchor = _nearest_perimeter_cell_in_dir(cells_set, cx, cz, dx, dz)
        if anchor is None:
            # No hub cells at all; fall back to centroid.
            anchor = hub_centroid_cell

        # Per-LZ slight perlin curve. Use a phase derived from the LZ
        # index so each arm curves differently.
        curve_phase = arm_rng.uniform(0.0, 100.0)
        cur_dx, cur_dz = dx, dz
        # Start the arm AT the anchor (overlap, not gap). The arm cells
        # will dedupe with the hub at the anchor; subsequent steps walk
        # outward.
        start_i = float(anchor[0])
        start_j = float(anchor[1])
        last_centre = (start_i, start_j)

        # We span step=0..arm_length so the FIRST 2-3 cells are inside/at
        # the hub perimeter (overlap), and the rest extend outward.
        # That's the structural fix for the visible gap rows.
        joint_overlap = 3  # how many cells overlap with the hub
        prev_centre_int = None  # previous step's centre (i, j) — for bridging
        for step in range(0, arm_length + 1):
            # Slight curve: rotate the direction by a tiny amount each
            # step driven by perlin noise. Suppress curve in the joint
            # overlap region to keep the joint straight & solid.
            if step >= joint_overlap:
                curve_amt = perlin1d(arm_seed, curve_phase + step * 0.35) * 0.06
                ca = math.cos(curve_amt); sa = math.sin(curve_amt)
                new_dx = ca * cur_dx - sa * cur_dz
                new_dz = sa * cur_dx + ca * cur_dz
                cur_dx, cur_dz = new_dx, new_dz

            # v6: width varies along the arm via TWO multi-scale Perlin
            # streams summed (low-freq rolling bulges every ~12 cells +
            # mid-freq pinches every ~4 cells), divided by 1.5 so the
            # combined ±4 swing sits on top of base_arm_width.
            t_width = step / max(1, arm_length)
            # Low freq: ~12-cell wavelength → t in [0, ~5] for length 60.
            # Mid freq: ~4-cell wavelength  → t in [0, ~15] for length 60.
            low_freq = perlin1d(arm_seed + ":w_lo",
                                step / 12.0 + curve_phase * 0.1)
            mid_freq = perlin1d(arm_seed + ":w_mid",
                                step / 4.0 + curve_phase * 0.3)
            # Each perlin1d is in [-1, 1]. Sum in [-2, 2]. Divide by 1.5
            # and multiply by 3 → swing in [-4, 4].
            width_perlin = ((low_freq + mid_freq) / 1.5) * 3.0
            cur_width = max(8, base_arm_width + int(round(width_perlin)))
            half_w = cur_width // 2

            tip_i = start_i + cur_dx * step
            tip_j = start_j + cur_dz * step

            # Perpendicular vector for arm width.
            perp_dx = -cur_dz
            perp_dz = cur_dx

            # Width range: split half_w (rounding bias for even widths).
            wlow = -half_w
            whigh = cur_width - 1 - half_w  # so total = cur_width cells
            for w in range(wlow, whigh + 1):
                ai = int(round(tip_i + perp_dx * w))
                aj = int(round(tip_j + perp_dz * w))
                key = (ai, aj)
                if key in cells_set:
                    continue
                cells_set.add(key)
                arm_cells_added.append(key)
                new_cell_entries.append([ai, aj])

            # Joint widening: in the joint_overlap region, also stamp a
            # 1-cell-larger half-width on each side so the join with the
            # hub is solid (no diagonal gaps).
            if step < joint_overlap:
                for w in (wlow - 1, whigh + 1):
                    ai = int(round(tip_i + perp_dx * w))
                    aj = int(round(tip_j + perp_dz * w))
                    key = (ai, aj)
                    if key in cells_set:
                        continue
                    cells_set.add(key)
                    arm_cells_added.append(key)
                    new_cell_entries.append([ai, aj])

            # v6 bulb stamp: at pre-chosen step indices, stamp an oval
            # disc of radius 1.6 * (cur_width / 2) centred on the arm
            # axis. This creates the "string of bulbs" silhouette.
            if step in bulb_steps:
                bulb_r = max(4, int(round(cur_width * 0.8)))  # 1.6 * half_w
                # Stamp a disc with a tiny Perlin perturbation so each
                # bulb has a slightly irregular shape.
                for ddi in range(-bulb_r - 1, bulb_r + 2):
                    for ddj in range(-bulb_r - 1, bulb_r + 2):
                        d = math.hypot(ddi, ddj)
                        jph = (ddi * 0.31) + (ddj * 0.19) + step * 0.07
                        jitter = perlin1d(arm_seed + ":bulb", jph) * 1.5
                        if d < bulb_r + jitter:
                            ai = int(round(tip_i)) + ddi
                            aj = int(round(tip_j)) + ddj
                            key = (ai, aj)
                            if key in cells_set:
                                continue
                            cells_set.add(key)
                            arm_cells_added.append(key)
                            new_cell_entries.append([ai, aj])

            # Bridge to previous step: if the curve made the centre move
            # by more than 1 cell on either axis, stamp the orthogonal
            # bridge cells so 4-connectivity is preserved.
            cur_centre_int = (int(round(tip_i)), int(round(tip_j)))
            if prev_centre_int is not None:
                pi, pj = prev_centre_int
                ci_, cj_ = cur_centre_int
                # Walk a Bresenham-ish line of width=1 between prev and cur
                # for the centre cells (and also fill perp neighbours so
                # the corridor stays its full width across the bridge).
                steps_b = max(abs(ci_ - pi), abs(cj_ - pj))
                if steps_b > 1:
                    for sb in range(1, steps_b):
                        bi = pi + (ci_ - pi) * sb // steps_b
                        bj = pj + (cj_ - pj) * sb // steps_b
                        for w in range(wlow, whigh + 1):
                            ai = int(round(bi + perp_dx * w))
                            aj = int(round(bj + perp_dz * w))
                            key = (ai, aj)
                            if key in cells_set:
                                continue
                            cells_set.add(key)
                            arm_cells_added.append(key)
                            new_cell_entries.append([ai, aj])
            prev_centre_int = cur_centre_int

            last_centre = (tip_i, tip_j)

        # BFS reachability check: ensure the arm tip is reachable from
        # the hub centroid. If not, walk back from the tip and widen
        # joint cells (add fill cells) until reachable.
        tip_int = (int(round(last_centre[0])), int(round(last_centre[1])))
        if tip_int not in cells_set:
            # Snap tip onto the closest arm cell.
            best = None; best_d = None
            for (ai, aj) in arm_cells_added:
                d2 = (ai - last_centre[0]) ** 2 + (aj - last_centre[1]) ** 2
                if best_d is None or d2 < best_d:
                    best_d = d2; best = (ai, aj)
            if best is not None:
                tip_int = best

        if tip_int in cells_set:
            reachable = _bfs_reachable_set(cells_set, hub_centroid_cell)
            if tip_int not in reachable:
                # Force reachability: stamp a fat 5-cell-wide ribbon along
                # the line from the anchor to the tip. This always
                # connects since it's continuous-grid.
                for s in range(0, max(1, int(math.hypot(
                        tip_int[0] - anchor[0],
                        tip_int[1] - anchor[1])) + 1)):
                    ti = anchor[0] + (tip_int[0] - anchor[0]) * s / max(
                        1, int(math.hypot(tip_int[0] - anchor[0],
                                          tip_int[1] - anchor[1])))
                    tj = anchor[1] + (tip_int[1] - anchor[1]) * s / max(
                        1, int(math.hypot(tip_int[0] - anchor[0],
                                          tip_int[1] - anchor[1])))
                    for ddi in (-2, -1, 0, 1, 2):
                        for ddj in (-2, -1, 0, 1, 2):
                            ai = int(round(ti)) + ddi
                            aj = int(round(tj)) + ddj
                            key = (ai, aj)
                            if key in cells_set:
                                continue
                            cells_set.add(key)
                            arm_cells_added.append(key)
                            new_cell_entries.append([ai, aj])

        # The arm tip is the centre cell at the end of the corridor.
        tip_i_int = int(round(last_centre[0]))
        tip_j_int = int(round(last_centre[1]))
        # World coords for the arm tip cell centre.
        tip_x_world = (tip_i_int + 0.5) * cs
        tip_z_world = (tip_j_int + 0.5) * cs

        # Push the LZ trigger half a cell beyond the tip in the outward
        # direction so it's at the very end of the arm corridor.
        outward_x = tip_x_world + cur_dx * cs * 0.5
        outward_z = tip_z_world + cur_dz * cs * 0.5

        old_pos = lz.get("pos", [0, 1.4, 0])
        old_y = float(old_pos[1]) if len(old_pos) > 1 else 1.4
        # Track sample arm distance for the report (use first arm only).
        if lz_idx == 0:
            old_dist = math.hypot(
                float(old_pos[0]) - (cx + 0.5) * cs,
                float(old_pos[2]) - (cz + 0.5) * cs,
            )
            new_dist = math.hypot(
                outward_x - (cx + 0.5) * cs,
                outward_z - (cz + 0.5) * cs,
            )
            sample_arm_distance = new_dist - old_dist
        lz["pos"] = [round(outward_x, 2), old_y, round(outward_z, 2)]

        # Rotate the LZ so it faces inward (rotation_y is the trigger's
        # facing — the spawn faces opposite). Set rotation_y so the
        # trigger box's local +z aligns with the arm direction.
        # (Most LZ triggers use rotation_y to align their flat face with
        # the wall; we'll set it to atan2(dx, dz) which rotates from -z
        # to (dx, dz). Keep existing if zero/unset to be conservative.)
        if "rotation_y" in lz:
            lz["rotation_y"] = round(math.atan2(cur_dx, cur_dz), 4)

        # Update the matching from_<target> spawn so a player coming
        # back into this scene appears at the arm tip facing inward.
        target_scene = lz.get("target_scene", "")
        if target_scene:
            spawn_id = "from_" + target_scene
            spawns = data.get("spawns", [])
            for sp in spawns:
                if sp.get("id") == spawn_id:
                    old_sp_pos = sp.get("pos", [0, 0.5, 0])
                    sp_y = float(old_sp_pos[1]) if len(old_sp_pos) > 1 else 0.5
                    sp["pos"] = [round(tip_x_world, 2), sp_y,
                                 round(tip_z_world, 2)]
                    # Spawn faces back toward the hub (inward).
                    sp["rotation_y"] = round(math.atan2(-cur_dx, -cur_dz), 4)
                    break

    # Final connectivity filter: drop any newly-added arm cells that are
    # not 4-connected (transitively) to the existing hub footprint. This
    # eliminates speckle strays from rotated-perpendicular rounding
    # artifacts at far ends of curved arms.
    pre_existing = set()
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            pre_existing.add((int(c.get("i", 0)), int(c.get("j", 0))))
        else:
            pre_existing.add((int(c[0]), int(c[1])))
    new_set = set(arm_cells_added)
    union = pre_existing | new_set
    # Seed: any arm cell adjacent to a pre-existing cell.
    seeds = [c for c in new_set
             if any((c[0] + ddi, c[1] + ddj) in pre_existing
                    for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)])]
    reachable_arm = set(seeds)
    stack = list(seeds)
    while stack:
        ci, cj = stack.pop()
        for ddi, ddj in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            nb = (ci + ddi, cj + ddj)
            if nb in new_set and nb not in reachable_arm:
                reachable_arm.add(nb)
                stack.append(nb)
    # Drop unreachable arm cells.
    dropped_strays = len(new_set) - len(reachable_arm)
    arm_cells_added = [c for c in arm_cells_added if c in reachable_arm]
    new_cell_entries = [e for e in new_cell_entries if (e[0], e[1]) in reachable_arm]

    # Write the new cells back into floor.
    floor["cells"] = list(floor.get("cells", [])) + new_cell_entries
    floor["_arm_cells"] = [[i, j] for (i, j) in arm_cells_added]

    final_cells = _existing_cell_set(floor)
    is2 = [c[0] for c in final_cells]
    js2 = [c[1] for c in final_cells]
    after_bbox = (min(is2), min(js2), max(is2), max(js2)) if final_cells else None

    return {
        "level": level_id,
        "arm_count": len(lz_dirs),
        "arm_cells_added": len(arm_cells_added),
        "before_n_cells": before_n_cells,
        "after_n_cells": len(final_cells),
        "before_bbox": before_bbox,
        "after_bbox": after_bbox,
        "sample_arm_distance": sample_arm_distance,
        "skipped": False,
    }


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

    # Idempotency pre-step: strip every level's previously-added arm
    # cells, organic-bulge cells, AND circular-blob cells (v6) so
    # subsequent passes operate on the original hub footprint, not last
    # run's arm/bulge/blob-extended one.
    # Without this, the handcrafted bbox-based LZ redistribution drifts
    # further out each run as the arm-tip becomes the new bbox edge.
    total_stripped_pre = 0
    total_stripped_bulge_pre = 0
    total_stripped_blob_pre = 0
    for lid, (fn, data) in levels.items():
        total_stripped_pre += _strip_arm_cells(data)
        total_stripped_bulge_pre += _strip_organic_bulge_cells(data)
        total_stripped_blob_pre += _strip_blob_cells(data)
    if total_stripped_pre:
        print("stripped %d stale arm cells (idempotent re-run cleanup)"
              % total_stripped_pre)
    if total_stripped_bulge_pre:
        print("stripped %d stale organic-bulge cells (idempotent re-run cleanup)"
              % total_stripped_bulge_pre)
    if total_stripped_blob_pre:
        print("stripped %d stale circular-blob cells (idempotent re-run cleanup)"
              % total_stripped_blob_pre)

    # v6: strip ALL legacy `_pillar_cluster` props across every dungeon.
    # These were placed at angular midpoints between LZs in v2/v3 and
    # now sit inside or alongside arm corridors. v6 emits zero of them;
    # perimeter knot bumps (off-bbox, tagged `_perimeter_knot`) survive.
    total_stripped_pillars = 0
    for lid, (fn, data) in levels.items():
        before = len(data.get("props", []))
        data["props"] = [p for p in data.get("props", [])
                         if not p.get("_pillar_cluster")]
        total_stripped_pillars += before - len(data["props"])
    if total_stripped_pillars:
        print("stripped %d legacy _pillar_cluster props (v6 cleanup)"
              % total_stripped_pillars)

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

    # ---- Circular blob pass (v6) ----
    # For every handcrafted hub (stone-walled, >=200 cells, with >=2
    # auto LZs OR >=800 cells), union a circular-blob footprint onto the
    # existing rectangular cells so the silhouette reads as round (not
    # square). Original cells are always preserved. Algorithm-owned
    # levels are skipped because their cells are already organic
    # (spine + bulb + prongs) from process_algorithm_level.
    blob_stats = []
    for lid, (fn, data) in levels.items():
        if lid in ALGO_OWNED:
            continue
        if lid not in PATH_MAP:
            continue
        # Qualify as a hub: stone-walled (not tree_walls), and either
        # >= 2 auto:true LZs OR >= 800 cells.
        if data.get("tree_walls"):
            continue
        floors = data.get("grid", {}).get("floors", [])
        if not floors:
            continue
        wall_material = floors[0].get("wall_material", "stone")
        if wall_material == "tree":
            # Outdoor tree-walled levels (sourceplain, brookhold, etc.)
            # already have organic naturally-painted footprints.
            continue
        n_cells_now = len(floors[0].get("cells", []))
        auto_lz_count = sum(1 for lz in data.get("load_zones", [])
                            if lz.get("auto", True))
        if auto_lz_count < 2 and n_cells_now < 800:
            continue
        added = make_circular_blob_for_level(lid, data)
        if added > 0:
            blob_stats.append((lid, n_cells_now, n_cells_now + added))

    # ---- Organic perimeter bulge pass ----
    # Add Perlin-noisy bulges to the perimeter of every level's footprint
    # so the silhouette is no longer a flat rectangle/circle. Run this
    # BEFORE the arm pass so arms anchor onto the bulged perimeter
    # (avoiding gaps at the join). Idempotent.
    bulge_stats = []
    for lid, (fn, data) in levels.items():
        if lid not in PATH_MAP and lid not in ALGO_OWNED:
            continue
        added = grow_organic_bulge_for_level(lid, data)
        if added > 0:
            bulge_stats.append((lid, added))

    # ---- Cell-arm growth pass (after all earlier mutations) ----
    # For every dir with >= 2 outgoing auto:true load_zones, extend
    # cell-arms reaching outward to each LZ so the silhouette reads as
    # a hub-with-branches. Idempotent.
    arm_stats = []
    for lid, (fn, data) in levels.items():
        if lid not in PATH_MAP and lid not in ALGO_OWNED:
            continue
        st = grow_arms_for_level(lid, data)
        if not st.get("skipped"):
            arm_stats.append(st)

    # Hole-fill pass: any non-cell position that has >= 3 of 4 cardinal
    # neighbors as cells gets filled in. Without this, the Perlin width
    # variation + arm bulge stamps leave tiny gaps inside the arms; the
    # build script then emits a GridTree on every cell-to-hole edge,
    # producing ~1800 tree-pillars per hub scattered through arms ("black
    # dots in pathways"). Iterate until no new fills (handles single-cell
    # holes whose neighbors only become cells after a prior fill round).
    total_holes_filled = 0
    for lid, (fn, data) in levels.items():
        floor = data.get("grid", {}).get("floors", [{}])[0]
        if not floor: continue
        cells_list = floor.get("cells", [])
        if not cells_list: continue
        # Preserve y-offsets — cells with 3+ entries keep them.
        cell_y = {}
        for c in cells_list:
            cell_y[(int(c[0]), int(c[1]))] = float(c[2]) if len(c) >= 3 else 0.0
        cell_set = set(cell_y.keys())
        filled_this_level = 0
        for _ in range(8):  # bounded rounds — usually converges in 2-3
            xs = [k[0] for k in cell_set]; zs = [k[1] for k in cell_set]
            if not xs: break
            new_fills = set()
            for z in range(min(zs) - 1, max(zs) + 2):
                for x in range(min(xs) - 1, max(xs) + 2):
                    if (x, z) in cell_set: continue
                    n = sum(1 for dx, dz in [(-1, 0), (1, 0), (0, -1), (0, 1)]
                            if (x + dx, z + dz) in cell_set)
                    if n >= 3:
                        new_fills.add((x, z))
            if not new_fills: break
            for (x, z) in new_fills:
                cell_set.add((x, z))
                cell_y[(x, z)] = 0.0
            filled_this_level += len(new_fills)
        if filled_this_level:
            new_cells_list = []
            for (i, j) in sorted(cell_set):
                y = cell_y[(i, j)]
                if abs(y) > 1e-4:
                    new_cells_list.append([i, j, y])
                else:
                    new_cells_list.append([i, j])
            floor["cells"] = new_cells_list
            total_holes_filled += filled_this_level
    print("HOLE-FILL: %d cells filled across all levels" % total_holes_filled)

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

    print()
    print("=" * 60)
    print("CIRCULAR BLOB (v6): %d handcrafted hubs gained circular cell unions"
          % len(blob_stats))
    if blob_stats:
        for lid, before, after in sorted(blob_stats,
                                          key=lambda x: -(x[2] - x[1]))[:20]:
            print("  %-22s cells %4d -> %4d  (+%4d blob cells)"
                  % (lid, before, after, after - before))

    print()
    print("=" * 60)
    print("ORGANIC BULGE: %d levels gained perimeter bulges" % len(bulge_stats))
    if bulge_stats:
        total_bulge = sum(n for _, n in bulge_stats)
        print("TOTAL bulge cells added: %d" % total_bulge)
        for lid, n in sorted(bulge_stats, key=lambda x: -x[1])[:12]:
            print("  %-22s +%4d bulge cells" % (lid, n))

    print()
    print("=" * 60)
    print("CELL-ARM GROWTH: %d levels grew arms" % len(arm_stats))
    total_arm_cells = sum(s["arm_cells_added"] for s in arm_stats)
    total_arms = sum(s["arm_count"] for s in arm_stats)
    print("TOTAL arms grown: %d  (cells added: %d)" % (total_arms, total_arm_cells))
    print()
    print("per-level arm breakdown:")
    for s in sorted(arm_stats, key=lambda x: -x["arm_cells_added"]):
        bb0 = s["before_bbox"]; bb1 = s["after_bbox"]
        if bb0 is None or bb1 is None:
            continue
        print("  %-22s arms=%2d cells %4d->%4d bbox (%3d..%3d, %3d..%3d) -> "
              "(%3d..%3d, %3d..%3d) sample_arm_dist=+%4.1f" % (
                  s["level"], s["arm_count"],
                  s["before_n_cells"], s["after_n_cells"],
                  bb0[0], bb0[2], bb0[1], bb0[3],
                  bb1[0], bb1[2], bb1[1], bb1[3],
                  s["sample_arm_distance"]))


if __name__ == "__main__":
    main()
