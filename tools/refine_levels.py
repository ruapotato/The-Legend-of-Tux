#!/usr/bin/env python3
"""One-shot refinement pass on every dungeons/*.json:

  - reduce knight counts where >3 (non-dungeon) or >6 (dungeon),
    keeping knights that guard chests / doorways / monoliths;
  - replace removed knights with blob/bat for variety;
  - place a single tomato in a few outdoor levels (sourceplain already
    has one; burnt_hollow + mirelake gain one each);
  - keep modest spore / wisp_hunter counts (2-4 wisp_hunters in
    burnt_hollow);
  - add hill / valley y_off clusters to outdoor levels (preserving
    existing cell colors);
  - add 12-25 bushes per outdoor level along path edges, plus 2-3 near
    each chest;
  - add 1-2 lore signs per level that has fewer than 3 already;
  - add a chest near major landmarks that lack one.

Run from project root:
    python3 tools/refine_levels.py
"""

import json
import math
import os
import random


ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


# ---- IO helpers --------------------------------------------------------

def load(name):
    with open(os.path.join(DUNGEONS, name + ".json")) as f:
        return json.load(f)


def save(name, data):
    with open(os.path.join(DUNGEONS, name + ".json"), "w") as f:
        json.dump(data, f, indent=2)


# ---- terrain helpers ---------------------------------------------------

def cells_index(floor):
    """Return (cell_set, info_dict) where info_dict[(i,j)] is
    {'y': float|None, 'color': list|None, 'orig': original_entry}."""
    cells = set()
    info = {}
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            ci, cj = int(c["i"]), int(c["j"])
            y = float(c["y"]) if "y" in c else None
            col = c.get("color")
        else:
            ci, cj = int(c[0]), int(c[1])
            y = float(c[2]) if len(c) >= 3 and c[2] is not None else None
            col = c[3] if len(c) >= 4 and c[3] is not None else None
        cells.add((ci, cj))
        info[(ci, cj)] = {"y": y, "color": col, "orig": c}
    return cells, info


def write_back_cells(floor, cells, info):
    """Re-emit floor['cells'] preserving original style as far as possible.
    A cell with neither y nor color collapses to [i, j]; with y only:
    [i, j, y]; with y and color: [i, j, y, color]."""
    out = []
    for (i, j) in sorted(cells):
        rec = info.get((i, j), {"y": None, "color": None})
        y = rec.get("y")
        col = rec.get("color")
        if col is not None and y is None:
            # need a y placeholder if color present (3-elt is y only;
            # 4-elt requires y).
            out.append([i, j, 0.0, col])
        elif col is not None:
            out.append([i, j, y, col])
        elif y is not None:
            out.append([i, j, y])
        else:
            out.append([i, j])
    floor["cells"] = out


def apply_hill(info, cells, cx, cz, radius, peak_y, falloff="cos"):
    """Set y_off for all cells within `radius` of (cx, cz), with `peak_y`
    at the centre falling smoothly to 0 at the rim. Existing y_off is
    overwritten only if smaller (so multiple overlapping hills max-blend)."""
    for (i, j) in cells:
        d = math.hypot((i + 0.5) - cx, (j + 0.5) - cz)
        if d > radius:
            continue
        t = 1.0 - d / radius
        if falloff == "cos":
            v = peak_y * (0.5 - 0.5 * math.cos(math.pi * t))
        else:
            v = peak_y * t
        rec = info.setdefault((i, j), {"y": None, "color": None})
        cur = rec.get("y")
        if peak_y >= 0:
            if cur is None or v > cur:
                rec["y"] = round(v, 3)
        else:
            if cur is None or v < cur:
                rec["y"] = round(v, 3)


def apply_plateau(info, cells, cx, cz, radius, peak_y):
    """Flat plateau in the inner half, smooth ramp on the outer half."""
    inner = radius * 0.5
    for (i, j) in cells:
        d = math.hypot((i + 0.5) - cx, (j + 0.5) - cz)
        if d > radius:
            continue
        if d <= inner:
            v = peak_y
        else:
            t = 1.0 - (d - inner) / (radius - inner)
            v = peak_y * (0.5 - 0.5 * math.cos(math.pi * t))
        rec = info.setdefault((i, j), {"y": None, "color": None})
        cur = rec.get("y")
        if peak_y >= 0:
            if cur is None or v > cur:
                rec["y"] = round(v, 3)
        else:
            if cur is None or v < cur:
                rec["y"] = round(v, 3)


# ---- enemy curation ----------------------------------------------------

def curate_knights(enemies, guards, max_keep, replace_with=("blob", "bat")):
    """Reduce knights to at most `max_keep`. The kept knights are those
    closest to any (gx, gz) in `guards`. Knights that get cut are turned
    into blob/bat at the same position (alternating). Other enemy types
    pass through unchanged.

    Returns (new_enemies, removed_count, replaced_count, kept_count).
    """
    knights = [e for e in enemies if e["type"] == "knight"]
    others = [e for e in enemies if e["type"] != "knight"]

    def nearest_guard_dist(e):
        x, _, z = e["pos"]
        if not guards:
            return 0.0
        return min(math.hypot(x - gx, z - gz) for (gx, gz) in guards)

    # Sort knights by guard-distance so the ones near guarded points
    # are kept first.
    knights.sort(key=nearest_guard_dist)
    keep = knights[:max_keep]
    drop = knights[max_keep:]

    new_enemies = list(others) + list(keep)
    rep = 0
    for idx, e in enumerate(drop):
        # Replace ~70 % of dropped knights with blob/bat; flat-out remove
        # the rest so total enemy count drifts down a bit.
        if (idx % 10) < 7:
            t = replace_with[idx % len(replace_with)]
            x, y, z = e["pos"]
            if t == "bat":
                new_enemies.append({"type": "bat", "pos": [x, 1.4, z]})
            else:
                new_enemies.append({"type": "blob", "pos": [x, 0.0, z]})
            rep += 1

    return new_enemies, len(drop), rep, len(keep)


# ---- bush placement ----------------------------------------------------

def add_bushes(props, points, rng, generous_fraction=0.2):
    """Append bush props at every (x, z) in `points`. `generous_fraction`
    of them are flagged with pebble_amount=3."""
    pts = list(points)
    rng.shuffle(pts)
    n_gen = max(1, int(len(pts) * generous_fraction))
    added = 0
    for k, (x, z) in enumerate(pts):
        b = {"type": "bush", "pos": [round(x, 1), 0, round(z, 1)]}
        if k < n_gen:
            b["pebble_amount"] = 3
        props.append(b)
        added += 1
    return added


def bush_ring(cx, cz, r, count, jitter, rng):
    """Yield (x, z) bush positions on a ring of radius r centred (cx,cz)."""
    for k in range(count):
        a = (k / count) * 2 * math.pi + rng.random() * 0.3
        x = cx + math.cos(a) * (r + rng.uniform(-jitter, jitter))
        z = cz + math.sin(a) * (r + rng.uniform(-jitter, jitter))
        yield x, z


def bushes_near_chests(props, rng, ring_r=2.5, per_chest=2):
    """Place 2-3 bushes around each existing chest as a decorative cluster."""
    chests = [p for p in props if p["type"] == "chest"]
    pts = []
    for c in chests:
        x, _, z = c["pos"]
        for k in range(per_chest):
            a = rng.uniform(0, 2 * math.pi)
            r = rng.uniform(ring_r * 0.7, ring_r * 1.2)
            pts.append((x + math.cos(a) * r, z + math.sin(a) * r))
    return pts


# =======================================================================
# Per-level refinement functions
# =======================================================================

def refine_sourceplain():
    rng = random.Random(101)
    name = "sourceplain"
    d = load(name)
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)

    report = {"name": name}

    # ---- terrain (hills and valleys) ----
    # Central monolith plateau (sign at [11, 7], chest? — landmark feel).
    apply_plateau(info, cells, cx=11.5, cz=6.5, radius=10, peak_y=1.5)
    # A ring of bumps at intermediate distances.
    hills = [
        (-30, -40, 9, 1.6),
        (60, -30, 8, 1.2),
        (-65, 35, 10, 1.4),
        (35, 60, 7, 1.0),
        (90, 30, 8, 1.1),
    ]
    for cx, cz, r, h in hills:
        apply_hill(info, cells, cx, cz, r, h)
    valleys = [
        (-50, 60, 8, -1.1),
        (50, -55, 7, -0.8),
        (-20, 25, 6, -0.6),
    ]
    for cx, cz, r, h in valleys:
        apply_hill(info, cells, cx, cz, r, h)

    write_back_cells(floor, cells, info)
    report["hills"] = len(hills) + 1     # +1 plateau
    report["valleys"] = len(valleys)

    # ---- enemies ----
    # Guard points: monolith, chests, load-zones to harder zones.
    chests = [(p["pos"][0], p["pos"][2]) for p in d["props"] if p["type"] == "chest"]
    monolith = [(11, 7)]
    burnt_gate = [(-94, 0)]      # Burnt Hollow load zone
    stoneroost_gate = [(82, -82)]
    guards = chests + monolith + burnt_gate + stoneroost_gate
    # Keep at most 3 knights (non-dungeon level). Currently 6.
    new_enemies, dropped, replaced, kept = curate_knights(
        d.get("enemies", []), guards, max_keep=3)
    report["knights_before"] = 6
    report["knights_after"] = kept
    d["enemies"] = new_enemies

    # ---- bushes ----
    props = d.get("props", [])
    bush_pts = []
    # Path edges: scatter bushes near the four sign-marked road exits.
    edge_seeds = [
        (1, 90), (1, -90), (120, 1), (-90, 1),
        (80, -75), (80, 75),
    ]
    for cx, cz in edge_seeds:
        for x, z in bush_ring(cx, cz, r=4.5, count=3, jitter=1.0, rng=rng):
            bush_pts.append((x, z))
    # Cluster around landmarks (signs in the middle).
    landmark_seeds = [(41, 39), (-63, 29), (-53, -47)]
    for cx, cz in landmark_seeds:
        for x, z in bush_ring(cx, cz, r=3.5, count=4, jitter=0.8, rng=rng):
            bush_pts.append((x, z))
    bush_pts.extend(bushes_near_chests(props, rng, per_chest=2))
    n_bushes = add_bushes(props, bush_pts, rng)
    report["bushes"] = n_bushes

    # ---- new sign ----
    # already 10 signs — skip extras here.
    report["new_signs"] = 0
    # ---- new chest? ----
    # already 8 chests — skip.
    report["new_chests"] = 0

    save(name, d)
    return report


def refine_burnt_hollow():
    rng = random.Random(102)
    name = "burnt_hollow"
    d = load(name)
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)
    report = {"name": name}

    # Hills + a small caldera at the centre of the burn.
    apply_hill(info, cells, cx=70, cz=20, radius=10, peak_y=1.4)
    apply_hill(info, cells, cx=20, cz=70, radius=8,  peak_y=1.0)
    apply_hill(info, cells, cx=85, cz=85, radius=7,  peak_y=0.8)
    apply_hill(info, cells, cx=50, cz=50, radius=9,  peak_y=-1.2)   # caldera
    apply_hill(info, cells, cx=15, cz=30, radius=6,  peak_y=-0.6)
    write_back_cells(floor, cells, info)
    report["hills"] = 3
    report["valleys"] = 2

    # Knights: 14 → 6 (dungeon-tier max for this fortified zone). Guard
    # points are chests, the central shrine sign, and the dead-end.
    chests = [(p["pos"][0], p["pos"][2]) for p in d["props"] if p["type"] == "chest"]
    landmarks = [(41, 57), (23, 49), (71, 31), (93, 49)]
    new_enemies, dropped, replaced, kept = curate_knights(
        d["enemies"], chests + landmarks, max_keep=6)
    report["knights_before"] = 14
    report["knights_after"] = kept
    d["enemies"] = new_enemies

    # Add 1 tomato as a mini-boss feel near the slag-shrine sign.
    if not any(e["type"] == "tomato" for e in d["enemies"]):
        d["enemies"].append({"type": "tomato", "pos": [41.0, 0.0, 51.0]})
    # Add wisp_hunters: spec wants 2-4 (currently 1).
    extra_wh = [
        {"type": "wisp_hunter", "pos": [55.0, 1.4, 45.0]},
        {"type": "wisp_hunter", "pos": [78.0, 1.4, 70.0]},
        {"type": "wisp_hunter", "pos": [25.0, 1.4, 60.0]},
    ]
    for w in extra_wh:
        d["enemies"].append(w)

    # Add a few spores in the dead corners.
    d["enemies"].extend([
        {"type": "spore", "pos": [12.0, 1.6, 30.0]},
        {"type": "spore", "pos": [88.0, 1.6, 80.0]},
    ])

    # Bushes: outdoor scorched zone — sparse, mostly near chests / shrine.
    props = d.get("props", [])
    bush_pts = []
    seeds = [(41, 57), (71, 31), (93, 49), (23, 49)]
    for cx, cz in seeds:
        for x, z in bush_ring(cx, cz, r=3.0, count=3, jitter=0.6, rng=rng):
            bush_pts.append((x, z))
    bush_pts.extend(bushes_near_chests(props, rng, per_chest=2))
    report["bushes"] = add_bushes(props, bush_pts, rng)

    # Sign count is already 5 — no add.
    report["new_signs"] = 0
    report["new_chests"] = 0

    save(name, d)
    return report


def refine_stoneroost():
    rng = random.Random(103)
    name = "stoneroost"
    d = load(name)
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)
    report = {"name": name}

    # Stoneroost is a windy ridge — emphasise vertical drama with one
    # high spine and a couple of side bumps.
    apply_plateau(info, cells, cx=0, cz=-30, radius=8, peak_y=1.8)
    apply_hill(info, cells, cx=20, cz=10, radius=7, peak_y=1.2)
    apply_hill(info, cells, cx=-25, cz=0, radius=6, peak_y=1.0)
    apply_hill(info, cells, cx=0, cz=40, radius=8, peak_y=-0.5)   # gulch
    write_back_cells(floor, cells, info)
    report["hills"] = 3
    report["valleys"] = 1

    # Knights: 11 → 5. Guard each chest and the switchback bench sign.
    chests = [(p["pos"][0], p["pos"][2]) for p in d["props"] if p["type"] == "chest"]
    landmarks = [(22, 16), (0, 40), (-22, -8)]
    new_enemies, dropped, replaced, kept = curate_knights(
        d["enemies"], chests + landmarks, max_keep=5)
    report["knights_before"] = 11
    report["knights_after"] = kept
    d["enemies"] = new_enemies

    # Stoneroost is rocky, not lush — only a handful of bushes near
    # the switchback bench / chest spots.
    props = d.get("props", [])
    bush_pts = list(bushes_near_chests(props, rng, per_chest=2))
    for cx, cz in [(22, 16), (0, 40)]:
        for x, z in bush_ring(cx, cz, r=2.5, count=3, jitter=0.4, rng=rng):
            bush_pts.append((x, z))
    report["bushes"] = add_bushes(props, bush_pts, rng)

    # Lore: 3 signs already — at the floor of the spec (≥3) so no add.
    report["new_signs"] = 0
    report["new_chests"] = 0

    save(name, d)
    return report


def refine_mirelake():
    rng = random.Random(104)
    name = "mirelake"
    d = load(name)
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)
    report = {"name": name}

    # Mirelake is — well — a lake. So mostly depressions; a few low
    # islands rising out of the water/peat.
    apply_hill(info, cells, cx=0,  cz=0,  radius=12, peak_y=-1.0)   # central deep
    apply_hill(info, cells, cx=-35, cz=-10, radius=6, peak_y=-0.7)
    apply_hill(info, cells, cx=35, cz=10,  radius=7, peak_y=-0.6)
    apply_plateau(info, cells, cx=0, cz=46, radius=6, peak_y=0.6)  # shrine isle
    apply_hill(info, cells, cx=-40, cz=30, radius=5, peak_y=0.5)
    apply_hill(info, cells, cx=40, cz=-30, radius=5, peak_y=0.4)
    write_back_cells(floor, cells, info)
    report["hills"] = 3       # the 3 small isles
    report["valleys"] = 3

    # Knights: 3 → leave as is (they guard the shrine isle). At cap.
    report["knights_before"] = 3
    report["knights_after"] = 3

    # Add a tomato near the central submerged cairns.
    if not any(e["type"] == "tomato" for e in d["enemies"]):
        d["enemies"].append({"type": "tomato", "pos": [0.0, 0.0, 14.0]})
    # Add 2 spores in the boggy corners.
    d["enemies"].extend([
        {"type": "spore", "pos": [-30.0, 1.6, 30.0]},
        {"type": "spore", "pos": [30.0, 1.6, -30.0]},
    ])

    # Bushes — reedy clusters around the islands and chests.
    props = d.get("props", [])
    bush_pts = []
    for cx, cz in [(0, 46), (-40, 30), (40, -30), (-35, -10), (35, 10), (-3, -42), (3, -42)]:
        for x, z in bush_ring(cx, cz, r=3.0, count=3, jitter=0.5, rng=rng):
            bush_pts.append((x, z))
    bush_pts.extend(bushes_near_chests(props, rng, per_chest=2))
    report["bushes"] = add_bushes(props, bush_pts, rng)

    # Lore: 4 signs already — fine.
    report["new_signs"] = 0
    report["new_chests"] = 0

    save(name, d)
    return report


def refine_brookhold():
    rng = random.Random(105)
    name = "brookhold"
    d = load(name)
    # Brookhold is a yard / paddock complex. Light terrain — mostly
    # gentle bumps in the south paddock; the indoor cottages stay flat.
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)
    report = {"name": name}

    apply_hill(info, cells, cx=-15, cz=15, radius=6, peak_y=0.6)
    apply_hill(info, cells, cx=20, cz=-15, radius=5, peak_y=0.4)
    apply_hill(info, cells, cx=0, cz=-25, radius=5, peak_y=-0.4)
    write_back_cells(floor, cells, info)
    report["hills"] = 2
    report["valleys"] = 1

    # Knights: only 1 — leave it.
    knights = [e for e in d["enemies"] if e["type"] == "knight"]
    report["knights_before"] = len(knights)
    report["knights_after"] = len(knights)

    # Bushes around the holding — gardens around cottages, hedges along
    # paths.
    props = d.get("props", [])
    bush_pts = []
    seeds = [(-32, 4), (-2, -2), (-1, -13), (13, -8), (-9, 9), (12, 17),
             (-15, 15), (20, -15)]
    for cx, cz in seeds:
        for x, z in bush_ring(cx, cz, r=2.5, count=2, jitter=0.4, rng=rng):
            bush_pts.append((x, z))
    bush_pts.extend(bushes_near_chests(props, rng, per_chest=2))
    report["bushes"] = add_bushes(props, bush_pts, rng)

    # 6 signs already — fine.
    report["new_signs"] = 0
    report["new_chests"] = 0

    save(name, d)
    return report


def refine_wyrdkin_glade():
    rng = random.Random(106)
    name = "wyrdkin_glade"
    d = load(name)
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)
    report = {"name": name}

    # Wyrdkin Glade — small magical clearing. Gentle mound at centre.
    apply_hill(info, cells, cx=0, cz=0, radius=5, peak_y=0.6)
    apply_hill(info, cells, cx=-10, cz=-15, radius=4, peak_y=-0.4)
    write_back_cells(floor, cells, info)
    report["hills"] = 1
    report["valleys"] = 1

    # No knights to begin with.
    report["knights_before"] = 0
    report["knights_after"] = 0

    # Add a couple of low-threat enemies — the glade should still feel
    # peaceful, so just one spore.
    if "enemies" not in d:
        d["enemies"] = []
    d["enemies"].append({"type": "spore", "pos": [-5.0, 1.6, -10.0]})

    # Bushes: pretty thick around the edges (forest clearing flavour).
    props = d.get("props", [])
    bush_pts = []
    for cx, cz in [(0, 0), (-8, -12), (8, -12), (0, 12), (10, 5), (-10, 5)]:
        for x, z in bush_ring(cx, cz, r=2.5, count=3, jitter=0.4, rng=rng):
            bush_pts.append((x, z))
    report["bushes"] = add_bushes(props, bush_pts, rng)

    # Only 2 signs — add one more lore sign.
    props.append({
        "type": "sign",
        "pos": [-6, 0, 8],
        "rotation_y": 0,
        "message": ("A wyrdkin-stone, cool to the touch.\n\n"
                    "\"Lirien's roots reach here. The Source whispers in "
                    "the leaves — listen, and you may hear your own name "
                    "spoken back.\""),
    })
    report["new_signs"] = 1

    # No chest yet — add one near the central mound.
    props.append({
        "type": "chest",
        "pos": [3, 0, 3],
        "rotation_y": 0,
        "contents": "heart",
        "open_message": "A heart-flower, pressed in oilcloth. The Source thanks you.",
    })
    report["new_chests"] = 1

    save(name, d)
    return report


def refine_wyrdwood():
    rng = random.Random(107)
    name = "wyrdwood"
    d = load(name)
    floor = d["grid"]["floors"][0]
    cells, info = cells_index(floor)
    report = {"name": name}

    apply_hill(info, cells, cx=0, cz=-5, radius=5, peak_y=0.7)
    apply_hill(info, cells, cx=8, cz=-20, radius=4, peak_y=0.5)
    apply_hill(info, cells, cx=-5, cz=5, radius=4, peak_y=-0.4)
    write_back_cells(floor, cells, info)
    report["hills"] = 2
    report["valleys"] = 1

    # No knights.
    report["knights_before"] = 0
    report["knights_after"] = 0

    # Bushes along the winding trail.
    props = d.get("props", [])
    bush_pts = []
    for cx, cz in [(0, 11), (10, -23), (0, 0), (-3, -10), (4, -15), (8, -5)]:
        for x, z in bush_ring(cx, cz, r=2.0, count=2, jitter=0.3, rng=rng):
            bush_pts.append((x, z))
    report["bushes"] = add_bushes(props, bush_pts, rng)

    # Only 2 signs — add one.
    props.append({
        "type": "sign",
        "pos": [-3, 0, -8],
        "rotation_y": 0,
        "message": ("A frayed ribbon, knotted to a low branch.\n\n"
                    "Someone marked this place. You feel the Source "
                    "listening more closely here."),
    })
    report["new_signs"] = 1
    # Add a chest along the trail.
    props.append({
        "type": "chest",
        "pos": [-6, 0, -3],
        "rotation_y": 0,
        "contents": "pebble",
        "amount": 5,
        "open_message": "A handful of river-pebbles, perfect for the sling.",
    })
    report["new_chests"] = 1

    save(name, d)
    return report


def refine_dungeon_first():
    rng = random.Random(108)
    name = "dungeon_first"
    d = load(name)
    report = {"name": name}

    # Indoor — no terrain changes. (Could do tile y_off but it'd
    # interfere with collision in a confined corridor.)
    report["hills"] = 0
    report["valleys"] = 0

    # Knights: 1 — leave.
    report["knights_before"] = 1
    report["knights_after"] = 1
    # Add a couple more enemies for variety: bat in the entry corridor.
    d["enemies"].extend([
        {"type": "blob", "pos": [3, 0, -22]},
        {"type": "bat", "pos": [-4, 1.4, -24]},
    ])

    # Indoor — no bushes.
    report["bushes"] = 0
    # 3 signs already, 2 chests already.
    report["new_signs"] = 0
    report["new_chests"] = 0

    save(name, d)
    return report


def refine_hearthold():
    rng = random.Random(109)
    name = "hearthold"
    d = load(name)
    report = {"name": name}

    # Hearthold is a town — keep it walkable/flat. No terrain changes.
    report["hills"] = 0
    report["valleys"] = 0
    report["knights_before"] = 0
    report["knights_after"] = 0
    report["bushes"] = 0

    # Currently 3 signs, 0 chests — add an extra lore sign and a
    # welcoming chest near the gate.
    props = d.setdefault("props", [])
    props.append({
        "type": "sign",
        "pos": [3, 0, 12],
        "rotation_y": 0,
        "message": ("A wax-fresh proclamation:\n\n"
                    "\"By the keepers of Hearthold: any traveler who has "
                    "drawn breath in the Sourceplain shall be welcomed at "
                    "the hearths within. Coin is not asked of the brave.\""),
    })
    report["new_signs"] = 1
    props.append({
        "type": "chest",
        "pos": [-5, 0, 12],
        "rotation_y": 0,
        "contents": "heart",
        "open_message": "A bundle of warm bread and a heart-flower. The keepers' welcome.",
    })
    report["new_chests"] = 1

    save(name, d)
    return report


def refine_sigilkeep():
    rng = random.Random(110)
    name = "sigilkeep"
    d = load(name)
    report = {"name": name}

    report["hills"] = 0
    report["valleys"] = 0
    report["knights_before"] = 0
    report["knights_after"] = 0
    report["bushes"] = 0

    # Currently 2 signs, 0 chests. Add 1 lore sign.
    props = d.setdefault("props", [])
    props.append({
        "type": "sign",
        "pos": [-6, 0, 0],
        "rotation_y": 0,
        "message": ("A wardstone in the wall, fingers-of-the-Source carved "
                    "deep:\n\n"
                    "\"What is sealed here is not the Hoarder, but the "
                    "shape of his hunger. The Sigilkeep waits for one "
                    "who has learned not to want.\""),
    })
    report["new_signs"] = 1
    report["new_chests"] = 0

    save(name, d)
    return report


# =======================================================================

def main():
    funcs = [
        refine_sourceplain,
        refine_burnt_hollow,
        refine_stoneroost,
        refine_mirelake,
        refine_brookhold,
        refine_wyrdkin_glade,
        refine_wyrdwood,
        refine_dungeon_first,
        refine_hearthold,
        refine_sigilkeep,
    ]
    print("\n%-16s %8s %6s %6s %6s %6s %6s" %
          ("level", "knights", "hills", "valls", "bushes", "signs+", "chests+"))
    print("-" * 70)
    for fn in funcs:
        r = fn()
        kb = r.get("knights_before", 0)
        ka = r.get("knights_after", 0)
        delta = ka - kb
        print("%-16s %3d->%-3d %6d %6d %6d %6d %6d" %
              (r["name"], kb, ka, r.get("hills", 0), r.get("valleys", 0),
               r.get("bushes", 0), r.get("new_signs", 0), r.get("new_chests", 0)))


if __name__ == "__main__":
    main()
