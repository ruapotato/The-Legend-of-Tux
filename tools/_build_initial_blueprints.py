#!/usr/bin/env python3
"""One-shot scaffold: extract the NPCs / signs / chests / owl_statue /
load_zones / spawns / environment from the existing dungeons/<id>.json
and produce blueprints/<id>.json files for the three proof-of-concept
levels (wyrdkin_glade, brookhold, hearthold).

The new blueprints get:
  - a single central terrain_patch sized to the original outdoor area,
    with a gentle Perlin-ish hill profile,
  - hand-authored room layouts (the buildings for each village),
  - all NPCs / signs / chests / owl_statue extracted from the old JSON
    (positions, names, dialog trees, colors, hints preserved verbatim),
  - the original load_zones and spawns, untouched.

This script is RUN ONCE — the resulting JSON files are checked in and
edited by hand from then on. It's idempotent: re-running with the same
input is safe. Run from repo root:

    python3 tools/_build_initial_blueprints.py
"""
import json
import math
import os
import random

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")
BLUEPRINTS = os.path.join(ROOT, "blueprints")


def extract_meta(src):
    """Pull the chunks that copy straight across."""
    keys = ["id", "name", "key_group", "music_track", "fs_path",
            "environment", "sky_color", "fog_color", "ambient_color",
            "sun_color", "ambient_energy"]
    out = {}
    for k in keys:
        if k in src:
            out[k] = src[k]
    return out


def filter_props(src):
    """Pull NPCs, signs, chests, owl statues - reusable verbatim.
    Drop trees/bushes/rocks (we'll re-scatter those programmatically
    inside / around the new buildings)."""
    by_kind = {"npc": [], "sign": [], "chest": [], "owl_statue": []}
    for p in src.get("props", []):
        k = p.get("type")
        if k in by_kind:
            by_kind[k].append(p)
    return by_kind


def heightfield_grass(size_x, size_z, resolution, seed=0):
    """Gentle multi-octave noise approximating low rolling hills.
    Output is heights[resolution*resolution], range roughly [-0.5, 0.8].
    Used for the central village yards — keeps the player able to walk
    onto any tile without finding a cliff. No deep valleys."""
    rng = random.Random(seed)
    # Three "fake Perlin" sine-wave octaves with random phase offsets.
    phases = [(rng.uniform(0, math.tau), rng.uniform(0, math.tau)) for _ in range(3)]
    freqs  = [0.06, 0.13, 0.27]
    amps   = [0.5,  0.22, 0.10]
    cell_x = size_x / float(resolution - 1)
    cell_z = size_z / float(resolution - 1)
    out = []
    for i in range(resolution):
        for j in range(resolution):
            x = i * cell_x
            z = j * cell_z
            h = 0.0
            for (px, pz), fr, am in zip(phases, freqs, amps):
                h += am * math.sin(x * fr + px) * math.cos(z * fr + pz)
            # Damp the edges so the patch blends into nominal y=0.
            edge_i = min(i, resolution - 1 - i) / float(resolution - 1)
            edge_j = min(j, resolution - 1 - j) / float(resolution - 1)
            edge = min(edge_i, edge_j) * 4.0
            damp = max(0.0, min(1.0, edge))
            h *= damp
            out.append(round(h, 4))
    return out


def scatter_props_around(centers, count, x_range, z_range, ground_y=0.0,
                         kind="tree", min_d=2.5, seed=1, forbid=None):
    """Place `count` props of the given kind at random positions inside
    (x_range, z_range), avoiding `centers` (list of (x, z, radius) keep-
    out circles). `forbid` is an extra list of (x, z, radius) circles
    (e.g. building footprints) we also avoid."""
    rng = random.Random(seed)
    placed = []
    forbid_all = (forbid or []) + list(centers or [])
    tries = 0
    while len(placed) < count and tries < count * 50:
        tries += 1
        x = rng.uniform(x_range[0], x_range[1])
        z = rng.uniform(z_range[0], z_range[1])
        ok = True
        for (fx, fz, fr) in forbid_all:
            if (x - fx) ** 2 + (z - fz) ** 2 < fr ** 2:
                ok = False
                break
        for (px, pz) in placed:
            if (x - px) ** 2 + (z - pz) ** 2 < min_d ** 2:
                ok = False
                break
        if not ok:
            continue
        placed.append((x, z))
    return [{"type": kind, "pos": [round(x, 2), round(ground_y, 2),
                                    round(z, 2)],
             "rotation_y": round(rng.uniform(0, math.tau), 3)}
            for (x, z) in placed]


# ---------- WYRDKIN GLADE ---------------------------------------------------

def build_wyrdkin_glade(src):
    meta = extract_meta(src)
    by_kind = filter_props(src)

    # Hesper's hut: ~6x4x5, wood walls, single south door. The glade
    # shrine where Glim lives: 5x3.5x5, stone walls, north door.
    # Both are small so the existing NPC pos at y=0 still works.
    rooms = [
        {
            "name": "HespersHut",
            "origin": [2.0, 0.0, 7.0],
            "size": [6.0, 4.0, 5.0],
            "material": "wood_warm",
            "floor_material": "wood_warm",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 2.5, "width": 1.5, "height": 2.4},
                ]},
                "east":  {"openings": [
                    {"type": "window", "x": 1.5, "width": 1.0, "height": 1.0, "sill": 1.2},
                ]},
                "west":  {"openings": []},
            },
        },
        {
            "name": "GladeShrine",
            "origin": [-2.5, 0.0, 2.0],
            "size": [5.0, 3.5, 5.0],
            "material": "stone_pale",
            "floor_material": "stone_pale",
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 1.75, "width": 1.5, "height": 2.4},
                ]},
                "south": {"openings": []},
                "east":  {"openings": []},
                "west":  {"openings": [
                    {"type": "window", "x": 1.5, "width": 1.0, "height": 1.0, "sill": 1.2},
                ]},
            },
        },
    ]

    materials = {
        "wood_warm":  {"albedo": [0.55, 0.4, 0.25], "roughness": 0.85},
        "stone_pale": {"albedo": [0.65, 0.62, 0.55], "roughness": 0.92},
    }

    # Central forest patch — 60x60m. Resolution 16 is enough for a
    # 4m cell pitch; the player walks over it without seeing seams.
    terrain = {
        "name": "ForestYard",
        "origin": [-30.0, 0.0, -30.0],
        "size_x": 60.0,
        "size_z": 60.0,
        "resolution": 16,
        "heights": heightfield_grass(60.0, 60.0, 16, seed=11),
        "surface_grid": [],   # default grass
        "flat_color":  [0.32, 0.55, 0.22],
        "slope_color": [0.45, 0.32, 0.18],
    }
    # A second smaller patch around the southern combat area, painted
    # with a few dirt cells where the tutorial paths are worn.
    south_dirt = {
        "name": "SouthPath",
        "origin": [-15.0, -0.01, -15.0],
        "size_x": 24.0,
        "size_z": 12.0,
        "resolution": 9,
        "heights": [0.0] * 81,
        # 8x8 cells; paint the middle row "dirt" to show a worn trail.
        "surface_grid": (
            [""] * 8 +
            [""] * 8 +
            [""] * 8 +
            ["", "", "dirt", "dirt", "dirt", "dirt", "", ""] +
            ["", "", "dirt", "dirt", "dirt", "dirt", "", ""] +
            [""] * 8 +
            [""] * 8 +
            [""] * 8
        ),
        "flat_color":  [0.35, 0.55, 0.22],
        "slope_color": [0.45, 0.32, 0.18],
    }

    # Extract tux_props verbatim. We preserve original positions.
    tux_props = []
    tux_props.extend(by_kind["npc"])
    tux_props.extend(by_kind["sign"])
    tux_props.extend(by_kind["chest"])
    tux_props.extend(by_kind["owl_statue"])

    # Scatter trees / bushes / rocks around the glade. The keep-outs
    # are the two buildings (so trees don't grow through walls) and
    # the central tutorial area.
    forbid = [
        (5.0,    9.5, 6.0),   # Hesper's hut footprint + breathing room
        (0.0,    4.5, 5.5),   # Glade shrine + breathing room
        (0.0,    2.0, 4.0),   # tutorial spawn area
        (-5.0, -10.0, 3.0),   # tomato enemy area
    ]
    trees = scatter_props_around(
        forbid, 20, x_range=(-28, 28), z_range=(-28, 28),
        kind="tree", seed=42, min_d=4.0)
    bushes = scatter_props_around(
        forbid, 14, x_range=(-26, 26), z_range=(-26, 26),
        kind="bush", seed=43, min_d=2.5)
    rocks = scatter_props_around(
        forbid, 12, x_range=(-26, 26), z_range=(-26, 26),
        kind="rock", seed=44, min_d=3.0)
    tux_props.extend(trees)
    tux_props.extend(bushes)
    tux_props.extend(rocks)

    bp = {
        **meta,
        "wall_thickness": 0.25,
        "spawn_point": [0.0, 0.24, 6.0],
        "materials": materials,
        "rooms": rooms,
        "terrain_patches": [terrain, south_dirt],
        "tux_props": tux_props,
        "spawns": src.get("spawns", []),
        "load_zones": [
            # Strip private "_pre_arm_pos" hint fields.
            {k: lz[k] for k in lz if not k.startswith("_")}
            for lz in src.get("load_zones", [])
        ],
        "enemies": src.get("enemies", []),
    }
    return bp


# ---------- BROOKHOLD ------------------------------------------------------

def build_brookhold(src):
    meta = extract_meta(src)
    by_kind = filter_props(src)

    # Brookhold is a wide farming village. Original NPCs sit roughly at
    # the village centre (-30..14 X, -10..11 Z). We author buildings
    # around them: Hall (matriarch), two barns, fenced paddock, brook-bed.
    rooms = [
        # Matriarch Brook's hall - stone-walled, large central building.
        {
            "name": "BrookholdHall",
            "origin": [-36.0, 0.0, 0.0],
            "size": [12.0, 6.0, 8.0],
            "material": "stone_brook",
            "floor_material": "wood_warm",
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 5.0, "width": 2.0, "height": 3.0},
                ]},
                "south": {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                    {"type": "window", "x": 8.5, "width": 1.5, "height": 1.2, "sill": 1.6},
                ]},
                "east": {"openings": [
                    {"type": "window", "x": 3.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                ]},
                "west": {"openings": []},
            },
        },
        # West barn (Hod's barn).
        {
            "name": "WestBarn",
            "origin": [10.0, 0.0, -12.0],
            "size": [6.0, 4.0, 6.0],
            "material": "wood_warm",
            "floor_material": "dirt_floor",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 2.0, "width": 2.0, "height": 3.0},
                ]},
                "east":  {"openings": [
                    {"type": "window", "x": 2.5, "width": 1.0, "height": 1.0, "sill": 1.5},
                ]},
                "west":  {"openings": []},
            },
        },
        # East barn.
        {
            "name": "EastBarn",
            "origin": [-6.0, 0.0, -16.0],
            "size": [6.0, 4.0, 6.0],
            "material": "wood_warm",
            "floor_material": "dirt_floor",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 2.0, "width": 2.0, "height": 3.0},
                ]},
                "east":  {"openings": []},
                "west":  {"openings": [
                    {"type": "window", "x": 2.5, "width": 1.0, "height": 1.0, "sill": 1.5},
                ]},
            },
        },
        # Fenced paddock - low walls (1.4m tall), south wall fully open.
        {
            "name": "Paddock",
            "origin": [-12.0, 0.0, -8.0],
            "size": [10.0, 1.4, 6.0],
            "material": "wood_fence",
            "floor": False,  # the ground is the terrain
            "ceiling": False,
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    # Whole south wall is open.
                    {"type": "door", "x": 0.5, "width": 9.0, "height": 1.4},
                ]},
                "east":  {"openings": []},
                "west":  {"openings": []},
            },
        },
        # Brookbed - low water area carved into the terrain. Implemented
        # as a 1m-deep room with no ceiling and water-painted floor.
        # The room walls are short stone retainers.
        {
            "name": "Brookbed",
            "origin": [4.0, -0.6, 14.0],
            "size": [14.0, 0.8, 4.0],
            "material": "stone_brook",
            "floor": False,
            "ceiling": False,
            "walls": {
                "north": {"openings": []},
                "south": {"openings": []},
                "east":  {"openings": []},
                "west":  {"openings": []},
            },
        },
    ]
    materials = {
        "stone_brook": {"albedo": [0.62, 0.6, 0.55], "roughness": 0.93},
        "wood_warm":   {"albedo": [0.55, 0.4, 0.25], "roughness": 0.85},
        "wood_fence":  {"albedo": [0.45, 0.35, 0.22], "roughness": 0.95},
        "dirt_floor":  {"albedo": [0.36, 0.27, 0.16], "roughness": 0.95},
    }
    # Central yard terrain: gentle hills, no water in the patch (the
    # Brookbed room provides the visible water via surface_grid below).
    terrain = {
        "name": "BrookholdYard",
        "origin": [-50.0, 0.0, -45.0],
        "size_x": 110.0,
        "size_z": 130.0,
        "resolution": 22,
        "heights": heightfield_grass(110.0, 130.0, 22, seed=21),
        "surface_grid": [],
        "flat_color":  [0.34, 0.52, 0.20],
        "slope_color": [0.45, 0.32, 0.18],
    }
    # Brook (the eponymous brook). A narrow water strip in the yard.
    brook = {
        "name": "Brook",
        "origin": [3.5, -0.4, 13.5],
        "size_x": 16.0,
        "size_z": 6.0,
        "resolution": 9,
        "heights": [0.0] * 81,
        "surface_grid": (
            [""] * 8 +
            [""] * 8 +
            ["", "", "water", "water", "water", "water", "", ""] +
            ["", "", "water", "water", "water", "water", "", ""] +
            ["", "", "water", "water", "water", "water", "", ""] +
            [""] * 8 +
            [""] * 8 +
            [""] * 8
        ),
        "flat_color":  [0.32, 0.5, 0.22],
        "slope_color": [0.45, 0.32, 0.18],
    }

    # NPCs + signs + chests verbatim.
    tux_props = list(by_kind["npc"]) + list(by_kind["sign"]) \
                + list(by_kind["chest"]) + list(by_kind["owl_statue"])

    # Forbid trees in buildings + load_zone clearances + NPC immediate area.
    forbid = [
        (-30.0,  4.0, 9.0),   # Hall
        (13.0, -9.0, 5.0),    # West barn
        (-3.0, -13.0, 5.0),   # East barn
        (-7.0, -5.0, 8.0),    # Paddock
        (11.0, 16.0, 10.0),   # Brookbed
        (-36.0, 1.0, 3.0),    # spawn
        # load_zone footprints
        (-2.5, -56.0, 5.0),
        (0.5, 73.0, 5.0),
        (39.8, 50.9, 5.0),
        (57.0, 18.6, 5.0),
        (56.0, 2.5, 5.0),
    ]
    trees = scatter_props_around(
        forbid, 40, x_range=(-45, 55), z_range=(-40, 60),
        kind="tree", seed=51, min_d=5.0)
    bushes = scatter_props_around(
        forbid, 24, x_range=(-45, 55), z_range=(-40, 60),
        kind="bush", seed=52, min_d=3.0)
    rocks = scatter_props_around(
        forbid, 18, x_range=(-45, 55), z_range=(-40, 60),
        kind="rock", seed=53, min_d=4.0)
    tux_props.extend(trees + bushes + rocks)

    bp = {
        **meta,
        "wall_thickness": 0.3,
        "spawn_point": [-36.0, 0.27, 1.0],
        "materials": materials,
        "rooms": rooms,
        "terrain_patches": [terrain, brook],
        "tux_props": tux_props,
        "spawns": src.get("spawns", []),
        "load_zones": [
            {k: lz[k] for k in lz if not k.startswith("_")}
            for lz in src.get("load_zones", [])
        ],
        "enemies": src.get("enemies", []),
    }
    return bp


# ---------- HEARTHOLD ------------------------------------------------------

def build_hearthold(src):
    meta = extract_meta(src)
    by_kind = filter_props(src)

    # Hearthold is the largest village. Spread the buildings around the
    # NPC positions extracted from the JSON.
    rooms = [
        # Village hall - the central authoritative building (Hearthold Elder).
        {
            "name": "VillageHall",
            "origin": [-4.0, 0.0, 0.0],
            "size": [8.0, 6.0, 8.0],
            "material": "stone_hold",
            "floor_material": "wood_warm",
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 3.0, "width": 2.0, "height": 3.0},
                ]},
                "south": {"openings": []},
                "east":  {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                    {"type": "window", "x": 5.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                ]},
                "west":  {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                ]},
            },
        },
        # Smithy (Takka the Smith + Smith Brann sit at x=10..12, z=4).
        {
            "name": "Smithy",
            "origin": [8.0, 0.0, 0.0],
            "size": [6.0, 5.0, 6.0],
            "material": "stone_hold",
            "floor_material": "dirt_floor",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 2.0, "width": 2.0, "height": 3.0},
                ]},
                "east":  {"openings": []},
                "west":  {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                ]},
            },
        },
        # Bakery (Pellman the Baker at -3, 0, 0; Pim at -3, 0, 8).
        {
            "name": "Bakery",
            "origin": [-8.0, 0.0, -4.0],
            "size": [6.0, 4.5, 5.0],
            "material": "wood_warm",
            "floor_material": "wood_warm",
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 2.0, "width": 2.0, "height": 3.0},
                ]},
                "south": {"openings": []},
                "east":  {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.0, "height": 1.0, "sill": 1.5},
                ]},
                "west":  {"openings": []},
            },
        },
        # Elder's house (just south of the Elder NPC at 0,0,4 - elder
        # outside greets visitors; the house is to the side).
        {
            "name": "EldersHouse",
            "origin": [-14.0, 0.0, 4.0],
            "size": [6.0, 5.0, 6.0],
            "material": "stone_hold",
            "floor_material": "wood_warm",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 2.0, "width": 2.0, "height": 3.0},
                ]},
                "east":  {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.5, "height": 1.2, "sill": 1.6},
                ]},
                "west":  {"openings": []},
            },
        },
        # Beekeeper's cottage (Old Naya at -7, 0, 14).
        {
            "name": "BeekeepersCottage",
            "origin": [-10.0, 0.0, 12.0],
            "size": [5.0, 4.0, 4.0],
            "material": "wood_warm",
            "floor_material": "wood_warm",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 1.5, "width": 1.5, "height": 2.4},
                ]},
                "east":  {"openings": []},
                "west":  {"openings": [
                    {"type": "window", "x": 1.0, "width": 1.0, "height": 1.0, "sill": 1.4},
                ]},
            },
        },
        # Tilly's stall (Tilly at 6, 0, -2) - open market stall (no doors,
        # just a roof on pillars). Implement as low room with all walls
        # opened wide.
        {
            "name": "MarketStall",
            "origin": [4.0, 0.0, -4.0],
            "size": [5.0, 3.5, 4.0],
            "material": "wood_warm",
            "floor": False,
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 0.5, "width": 4.0, "height": 3.0},
                ]},
                "south": {"openings": []},
                "east":  {"openings": [
                    {"type": "door", "x": 0.5, "width": 3.0, "height": 3.0},
                ]},
                "west":  {"openings": []},
            },
        },
        # Father Velis's shrine (-7, 0, -6).
        {
            "name": "VelisShrine",
            "origin": [-10.0, 0.0, -10.0],
            "size": [5.0, 4.0, 5.0],
            "material": "stone_hold",
            "floor_material": "stone_hold",
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 1.5, "width": 2.0, "height": 3.0},
                ]},
                "south": {"openings": []},
                "east":  {"openings": [
                    {"type": "window", "x": 2.0, "width": 1.0, "height": 1.5, "sill": 1.0},
                ]},
                "west":  {"openings": []},
            },
        },
        # A storage shed near the kilns.
        {
            "name": "KilnShed",
            "origin": [12.0, 0.0, -6.0],
            "size": [4.0, 3.5, 4.0],
            "material": "stone_hold",
            "floor_material": "dirt_floor",
            "walls": {
                "north": {"openings": []},
                "south": {"openings": [
                    {"type": "door", "x": 1.0, "width": 1.5, "height": 2.4},
                ]},
                "east":  {"openings": []},
                "west":  {"openings": []},
            },
        },
        # An outer well-house at the village edge.
        {
            "name": "WellHouse",
            "origin": [16.0, 0.0, 8.0],
            "size": [4.0, 4.0, 4.0],
            "material": "stone_hold",
            "floor_material": "stone_hold",
            "walls": {
                "north": {"openings": [
                    {"type": "door", "x": 1.0, "width": 1.5, "height": 2.4},
                ]},
                "south": {"openings": []},
                "east":  {"openings": []},
                "west":  {"openings": []},
            },
        },
    ]
    materials = {
        "stone_hold": {"albedo": [0.6, 0.58, 0.55], "roughness": 0.93},
        "wood_warm":  {"albedo": [0.55, 0.4, 0.25], "roughness": 0.85},
        "dirt_floor": {"albedo": [0.36, 0.27, 0.16], "roughness": 0.95},
    }
    # Plaza terrain - very large to cover all the load_zones too.
    terrain = {
        "name": "HeartholdPlaza",
        "origin": [-90.0, 0.0, -25.0],
        "size_x": 180.0,
        "size_z": 140.0,
        "resolution": 24,
        "heights": heightfield_grass(180.0, 140.0, 24, seed=31),
        "surface_grid": [],
        "flat_color":  [0.36, 0.5, 0.22],
        "slope_color": [0.45, 0.32, 0.18],
    }

    tux_props = list(by_kind["npc"]) + list(by_kind["sign"]) \
                + list(by_kind["chest"]) + list(by_kind["owl_statue"])

    forbid = [
        (0.0, 4.0, 8.0),    # Village Hall
        (11.0, 3.0, 6.0),   # Smithy
        (-5.0, -1.5, 6.0),  # Bakery
        (-11.0, 7.0, 6.0),  # Elder's House
        (-7.5, 14.0, 5.0),  # Beekeeper
        (6.5, -2.0, 5.0),   # Market stall
        (-7.5, -7.5, 5.0),  # Velis shrine
        (14.0, -4.0, 4.0),  # Kiln shed
        (18.0, 10.0, 4.0),  # Well house
        (0.0, 18.0, 5.0),   # spawn area
        # load_zones
        (-75.0, -7.6, 6.0),
        (-39.7, 99.9, 6.0),
        (-56.9, 60.8, 6.0),
        (-84.9, 61.8, 6.0),
        (24.7, 88.0, 6.0),
        (73.9, 57.8, 6.0),
    ]
    trees = scatter_props_around(
        forbid, 60, x_range=(-80, 80), z_range=(-20, 95),
        kind="tree", seed=61, min_d=5.5)
    bushes = scatter_props_around(
        forbid, 30, x_range=(-80, 80), z_range=(-20, 95),
        kind="bush", seed=62, min_d=3.0)
    rocks = scatter_props_around(
        forbid, 20, x_range=(-80, 80), z_range=(-20, 95),
        kind="rock", seed=63, min_d=4.0)
    tux_props.extend(trees + bushes + rocks)

    bp = {
        **meta,
        "wall_thickness": 0.3,
        "spawn_point": [0.0, -0.49, 18.0],
        "materials": materials,
        "rooms": rooms,
        "terrain_patches": [terrain],
        "tux_props": tux_props,
        "spawns": src.get("spawns", []),
        "load_zones": [
            {k: lz[k] for k in lz if not k.startswith("_")}
            for lz in src.get("load_zones", [])
        ],
        "enemies": src.get("enemies", []),
    }
    return bp


def main():
    os.makedirs(BLUEPRINTS, exist_ok=True)
    builders = {
        "wyrdkin_glade": build_wyrdkin_glade,
        "brookhold":     build_brookhold,
        "hearthold":     build_hearthold,
    }
    for level_id, builder in builders.items():
        src_path = os.path.join(DUNGEONS, f"{level_id}.json")
        with open(src_path) as f:
            src = json.load(f)
        bp = builder(src)
        out_path = os.path.join(BLUEPRINTS, f"{level_id}.json")
        with open(out_path, "w") as f:
            json.dump(bp, f, indent=2, ensure_ascii=False)
        print(f"wrote {os.path.relpath(out_path)}  rooms={len(bp['rooms'])}  "
              f"terrain={len(bp['terrain_patches'])}  "
              f"tux_props={len(bp['tux_props'])}  "
              f"load_zones={len(bp['load_zones'])}")


if __name__ == "__main__":
    main()
