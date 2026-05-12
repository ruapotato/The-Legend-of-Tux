#!/usr/bin/env python3
"""Blueprint -> .tscn building converter (Tux edition).

Adapted from gd_mario's build_from_blueprint.py. The pain point with the
existing cells + walls + grow_filesystem level pipeline: buildings get
embedded in hills, doorways are unreliable, and the player gets trapped.

This converter authors buildings as **floorplans** -- rooms are explicit
boxes with named walls (north/south/east/west); doorways are openings
that split each wall into floor-sill-piece, jamb-left, lintel-top,
jamb-right sub-segments. No CSG drift.

Tux extensions over the gd_mario original:
  - "tux_props" array spawns our existing prop scenes (npc, sign,
    chest, owl_statue, tree, bush, rock, bomb_flower, etc.) via
    ExtResource — same pattern as tools/build_dungeon.py.
  - "load_zones" use the Tux schema (target_scene + target_spawn +
    prompt + auto) and emit res://scripts/load_zone.gd Area3Ds.
  - "spawns" array emits Marker3Ds under a Spawns/ namespace, matching
    what dungeon_root.gd reads at scene-load.
  - "environment" block lays down a ProceduralSky + DirectionalLight3D
    so the scene looks like every other level in the world.
  - Root node carries the dungeon_root.gd script + key_group +
    music_track + display_name + fs_path so existing autoloads
    (GameState, MusicBank, etc.) recognise the scene.
  - Tux player + Glim + HUD + Camera + DebugOverlay + PauseMenu are
    auto-injected (same fixed footer build_dungeon.py emits).
  - Materials are INLINE by default — the gd_mario schema lets you
    point at .tres files but our project has no such assets; we
    accept `{"albedo":[r,g,b]}` style dicts and bake a StandardMaterial3D
    sub_resource on demand.

Blueprint schema:

    {
      "id":   "brookhold",       # scene file id; output is godot/scenes/<id>.tscn
      "name": "Brookhold",       # display name (and root node name)
      "fs_path":     "/home/brookhold",
      "key_group":   "brookhold",   # optional override
      "music_track": "brookhold",   # optional override
      "wall_thickness": 0.3,
      "floor_height": 4.0,
      "spawn_point":  [x,y,z],      # optional convenience; mirrored to default spawn
      "materials": {
        "stone": {"albedo": [0.55, 0.55, 0.6]},
        "wood":  {"albedo": [0.55, 0.4, 0.25]}
        # or {"albedo": [..], "emission": [..], "roughness": 0.8}
        # or "res://path/to.tres" for an external Material
      },
      "environment": {
        "sky_top": [...], "sky_horizon": [...], "ground_horizon": [...],
        "ground_bottom": [...], "ambient_color": [...], "ambient_energy": 0.55,
        "fog_density": 0.005, "fog_color": [...],
        "sun_dir": [x,y,z], "sun_color": [...], "sun_energy": 1.0
      },
      "rooms": [...],            # see gd_mario doc above
      "terrain_patches": [...],  # see gd_mario doc above
      "extras": [...],           # stairs, pillars, etc.
      "tux_props": [...],        # our props — npc, sign, chest, tree, etc.
      "spawns": [{"id","pos","rotation_y"}],
      "load_zones": [{"pos","size","target_scene","target_spawn","prompt","auto"}],
      "enemies": [...]           # uses ENEMY_TO_EXT from build_dungeon.py
    }

Run:
    python3 tools/build_from_blueprint.py <id> [<id2> ...]
        # finds blueprints/<id>.json, writes godot/scenes/<id>.tscn
    python3 tools/build_from_blueprint.py blueprints/foo.json godot/scenes/foo.tscn
        # legacy two-arg form for one-off conversions
"""
from __future__ import annotations
import argparse
import json
import math
import os
import sys

ROOT          = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLUEPRINTS    = os.path.join(ROOT, "blueprints")
SCENES_OUT    = os.path.join(ROOT, "godot", "scenes")


# ---------------------------------------------------------------------------
# Tux prop / enemy registry — mirrors tools/build_dungeon.py.
# Keep these tables in sync if you add new scene types over there.

EXT_RESOURCES = {
    "tux":              ("PackedScene", "uid://btuxpl01",   "res://scenes/tux.tscn"),
    "hud":              ("PackedScene", "uid://btuxhud01",  "res://scenes/hud.tscn"),
    "glim":             ("PackedScene", "uid://btuxglim01", "res://scenes/glim.tscn"),
    # Enemies (subset; same uids as build_dungeon.py).
    "blob":             ("PackedScene", "uid://btuxblb01",  "res://scenes/enemy_blob.tscn"),
    "knight":           ("PackedScene", "uid://btuxbnk01",  "res://scenes/enemy_bone_knight.tscn"),
    "bat":              ("PackedScene", "uid://btuxbat01",  "res://scenes/enemy_bone_bat.tscn"),
    "tomato":           ("PackedScene", "uid://btuxtmto01", "res://scenes/enemy_tomato.tscn"),
    "spore":            ("PackedScene", "uid://btuxspr01",  "res://scenes/enemy_spore.tscn"),
    "wisp_hunter":      ("PackedScene", "uid://btuxwsph01", "res://scenes/enemy_wisp_hunter.tscn"),
    "skull_spider":     ("PackedScene", "uid://btuxsklsp01","res://scenes/enemy_skull_spider.tscn"),
    # Props (instanced scenes).
    "sign":             ("PackedScene", "uid://btuxsgnp01", "res://scenes/sign_post.tscn"),
    "bush":             ("PackedScene", "uid://btuxbush01", "res://scenes/bush.tscn"),
    "rock":             ("PackedScene", "uid://btuxrock01", "res://scenes/rock.tscn"),
    "tree":             ("PackedScene", "uid://btuxtree01", "res://scenes/tree_prop.tscn"),
    "chest":            ("PackedScene", "uid://btuxchst01", "res://scenes/treasure_chest.tscn"),
    "npc":              ("PackedScene", "uid://btuxnpc01",  "res://scenes/npc.tscn"),
    "door":             ("PackedScene", "uid://btuxdoor01", "res://scenes/door.tscn"),
    "owl_statue":       ("PackedScene", "uid://btuxowl01",  "res://scenes/owl_statue.tscn"),
    "bomb_flower":      ("PackedScene", "uid://btuxbflw01", "res://scenes/bomb_flower.tscn"),
    "destructible_wall":("PackedScene", "uid://btuxdwall01","res://scenes/destructible_wall.tscn"),
    "crystal_switch":   ("PackedScene", "uid://btuxcrys01", "res://scenes/crystal_switch.tscn"),
    "pressure_plate":   ("PackedScene", "uid://btuxplt01",  "res://scenes/pressure_plate.tscn"),
    "triggered_gate":   ("PackedScene", "uid://btuxtgte01", "res://scenes/triggered_gate.tscn"),
    "time_gate":        ("PackedScene", "uid://btuxtgte02", "res://scenes/time_gate.tscn"),
    "boss_arena":       ("PackedScene", "uid://btuxbarn01", "res://scenes/boss_arena.tscn"),
    "hookshot_target":  ("PackedScene", "uid://btuxhshot01","res://scenes/hookshot_target.tscn"),
    "torch":            ("PackedScene", "uid://btuxtrch01", "res://scenes/torch.tscn"),
    "movable_block":    ("PackedScene", "uid://btuxblck01", "res://scenes/movable_block.tscn"),
    "eye_target":       ("PackedScene", "uid://btuxeye01",  "res://scenes/eye_target.tscn"),
    # Pickup contents — what a chest dispenses.
    "key_pickup":       ("PackedScene", "uid://btuxpkky01", "res://scenes/pickup_key.tscn"),
    "pebble_pickup":    ("PackedScene", "uid://btuxpkpb01", "res://scenes/pickup_pebble.tscn"),
    "heart_pickup":     ("PackedScene", "uid://btuxpkht01", "res://scenes/pickup_heart.tscn"),
    "boomerang_pickup": ("PackedScene", "uid://btuxpkbmrg01","res://scenes/pickup_boomerang.tscn"),
    "arrow_pickup":     ("PackedScene", "uid://btuxpkar01", "res://scenes/pickup_arrow.tscn"),
    "seed_pickup":      ("PackedScene", "uid://btuxpksd01", "res://scenes/pickup_seed.tscn"),
    "bow_pickup":       ("PackedScene", "uid://btuxpkbow01","res://scenes/pickup_bow.tscn"),
    "slingshot_pickup": ("PackedScene", "uid://btuxpksl01", "res://scenes/pickup_slingshot.tscn"),
    "bomb_pickup":      ("PackedScene", "uid://btuxpkbm01", "res://scenes/pickup_bomb.tscn"),
    "hookshot_pickup":  ("PackedScene", "uid://btuxpkhs01", "res://scenes/pickup_hookshot.tscn"),
    "fairy_bottle":     ("PackedScene", "uid://btuxfair01", "res://scenes/fairy_bottle_pickup.tscn"),
    "heart_piece":      ("PackedScene", "uid://btuxhpie01", "res://scenes/heart_piece.tscn"),
    "heart_container":  ("PackedScene", "uid://btuxhcnt01", "res://scenes/heart_container.tscn"),
    # Scripts.
    "root_script":         ("Script", None, "res://scripts/dungeon_root.gd"),
    "load_zone_script":    ("Script", None, "res://scripts/load_zone.gd"),
    "terrain_patch_script":("Script", None, "res://scripts/terrain_patch.gd"),
    "camera_script":       ("Script", None, "res://scripts/free_orbit_camera.gd"),
    "debug_script":        ("Script", None, "res://scripts/debug_overlay.gd"),
    "pause_script":        ("Script", None, "res://scripts/pause_menu.gd"),
}

CONTENTS_TO_EXT = {
    "key":       "key_pickup",
    "pebble":    "pebble_pickup",
    "heart":     "heart_pickup",
    "boomerang": "boomerang_pickup",
    "arrow":     "arrow_pickup",
    "seed":      "seed_pickup",
    "bow":       "bow_pickup",
    "slingshot": "slingshot_pickup",
    "bomb":      "bomb_pickup",
    "hookshot":  "hookshot_pickup",
    "fairy":     "fairy_bottle",
    "heart_piece":     "heart_piece",
    "heart_container": "heart_container",
}

ENEMY_TO_EXT = {
    "blob":         "blob",
    "knight":       "knight",
    "bat":          "bat",
    "tomato":       "tomato",
    "spore":        "spore",
    "wisp_hunter":  "wisp_hunter",
    "skull_spider": "skull_spider",
}


# ---------------------------------------------------------------------------
# Scene emitter — accumulates ext_resources, sub_resources, and node
# stanzas, then formats the whole file once.

class Scene:
    def __init__(self) -> None:
        # ext_resources: dict name -> (type, uid_or_None, path). Uses dict
        # so we can look up by stable name (matching build_dungeon.py
        # style) and dedupe automatically.
        self.ext_resources: dict[str, tuple[str, str | None, str]] = {}
        self.sub_resources: list[tuple[str, str, list[tuple[str, str]]]] = []
        self.nodes: list[str] = []   # raw [node ...] stanzas (already formatted)
        self._next_sub = 1
        self._scene_uid: str | None = None
        # Generic-material cache keyed on (rgb, roughness, metallic).
        self._color_mat: dict[tuple, str] = {}

    def ext(self, name: str) -> str:
        """Mark an EXT_RESOURCES entry as used; returns the id alias."""
        if name not in EXT_RESOURCES:
            raise KeyError(f"unknown ext resource: {name}")
        if name not in self.ext_resources:
            self.ext_resources[name] = EXT_RESOURCES[name]
        return name

    def add_ext(self, name: str, type_: str, path: str,
                uid: str | None = None) -> str:
        """Register an inline ext_resource — used for ad-hoc materials
        in `materials` that point at res:// files we don't have in
        EXT_RESOURCES."""
        if name in self.ext_resources:
            return name
        self.ext_resources[name] = (type_, uid, path)
        return name

    def sub(self, type_: str, props: list[tuple[str, str]]) -> str:
        sid = f"s{self._next_sub}"
        self._next_sub += 1
        self.sub_resources.append((sid, type_, props))
        return sid

    def color_mat(self, color: list[float] | tuple,
                  roughness: float = 0.9,
                  metallic: float = 0.0,
                  emission: list[float] | None = None,
                  emission_energy: float = 1.0) -> str:
        c = tuple(color) if len(color) == 4 else tuple(list(color) + [1.0])
        key = (c, roughness, metallic, tuple(emission) if emission else None,
               emission_energy)
        if key in self._color_mat:
            return self._color_mat[key]
        props = [
            ("albedo_color", "Color(%g, %g, %g, %g)" % c),
            ("roughness", "%g" % roughness),
            ("metallic", "%g" % metallic),
        ]
        if emission is not None:
            e = list(emission)
            while len(e) < 3:
                e.append(0.0)
            props.append(("emission_enabled", "true"))
            props.append(("emission", "Color(%g, %g, %g, 1)" % tuple(e[:3])))
            props.append(("emission_energy_multiplier", "%g" % emission_energy))
        rid = self.sub("StandardMaterial3D", props)
        self._color_mat[key] = rid
        return rid

    def node(self, raw: str) -> None:
        self.nodes.append(raw if raw.endswith("\n") else raw + "\n")

    def format(self, scene_uid: str = "") -> str:
        load_steps = 1 + len(self.ext_resources) + len(self.sub_resources)
        out: list[str] = []
        if scene_uid:
            out.append(f'[gd_scene load_steps={load_steps} format=3 uid="{scene_uid}"]\n')
        else:
            out.append(f'[gd_scene load_steps={load_steps} format=3]\n')
        for name, (t, uid, path) in self.ext_resources.items():
            if uid:
                out.append(f'[ext_resource type="{t}" uid="{uid}" path="{path}" id="{name}"]\n')
            else:
                out.append(f'[ext_resource type="{t}" path="{path}" id="{name}"]\n')
        if self.ext_resources:
            out.append("\n")
        for sid, t, props in self.sub_resources:
            out.append(f'[sub_resource type="{t}" id="{sid}"]\n')
            for k, v in props:
                out.append(f'{k} = {v}\n')
            out.append("\n")
        out.extend(self.nodes)
        return "".join(out)


# ---------------------------------------------------------------------------
# Formatting helpers (mirror build_dungeon.py for compatibility).

def vec(x: float, y: float, z: float) -> str:
    return f"Vector3({x}, {y}, {z})"


def cstr(c) -> str:
    if c is None:
        return "Color(1, 1, 1, 1)"
    if len(c) == 3:
        c = list(c) + [1.0]
    return "Color(%g, %g, %g, %g)" % tuple(c)


def xform_translate(x: float, y: float, z: float, rot_y: float = 0.0) -> str:
    if abs(rot_y) < 1e-6:
        return "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)" % (x, y, z)
    cy = math.cos(rot_y)
    sy = math.sin(rot_y)
    return "Transform3D(%g, 0, %g, 0, 1, 0, %g, 0, %g, %g, %g, %g)" % (
        cy, -sy, sy, cy, x, y, z)


def escape(s: str | None) -> str:
    if s is None:
        return ""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# ---------------------------------------------------------------------------
# Rectangle subtraction utility (gd_mario verbatim).

def _subtract_rect(rect, hole):
    rx0, rz0, rx1, rz1 = rect
    hx0, hz0, hx1, hz1 = hole
    cx0 = max(rx0, hx0); cx1 = min(rx1, hx1)
    cz0 = max(rz0, hz0); cz1 = min(rz1, hz1)
    if cx0 >= cx1 or cz0 >= cz1:
        return [rect]
    out = []
    if rz0 < cz0:
        out.append((rx0, rz0, rx1, cz0))
    if cz1 < rz1:
        out.append((rx0, cz1, rx1, rz1))
    if rx0 < cx0:
        out.append((rx0, cz0, cx0, cz1))
    if cx1 < rx1:
        out.append((cx1, cz0, rx1, cz1))
    return out


def _emit_slab_with_holes(scene: Scene, parent: str, prefix: str,
                          sx: float, sz: float,
                          y_center: float, y_thickness: float,
                          holes, mat_id: str | None) -> None:
    rects = [(0.0, 0.0, sx, sz)]
    for hole in holes:
        hx = float(hole["x"]); hz = float(hole["z"])
        hw = float(hole["width"]); hd = float(hole["depth"])
        hr = (hx, hz, hx + hw, hz + hd)
        nxt = []
        for r in rects:
            nxt.extend(_subtract_rect(r, hr))
        rects = nxt
    for idx, (x0, z0, x1, z1) in enumerate(rects):
        w = x1 - x0
        d = z1 - z0
        if w <= 0.001 or d <= 0.001:
            continue
        cx = (x0 + x1) * 0.5
        cz = (z0 + z1) * 0.5
        emit_box(scene, parent, f"{prefix}_{idx}",
                 (cx, y_center, cz),
                 (w, y_thickness, d), mat_id)


def emit_box(scene: Scene, parent: str, name: str,
             pos, size, mat_id: str | None,
             is_sub_material: bool = True) -> None:
    """Emit a solid box. mat_id is a SubResource id for an inline material
    by default (is_sub_material=True); pass is_sub_material=False to
    reference an ExtResource (for the rare external .tres case)."""
    mesh_id = scene.sub("BoxMesh", [("size", vec(*size))])
    shape_id = scene.sub("BoxShape3D", [("size", vec(*size))])

    parent_str = "." if parent == "" else parent
    # StaticBody3D stanza.
    scene.node(
        f'[node name="{name}" type="StaticBody3D" parent="{parent_str}"]\n'
        f'transform = {xform_translate(*pos)}\n'
        f'collision_layer = 1\n'
        f'collision_mask = 1\n'
    )
    # Mesh stanza.
    mi_body = f'mesh = SubResource("{mesh_id}")\n'
    if mat_id is not None:
        if is_sub_material:
            mi_body += f'surface_material_override/0 = SubResource("{mat_id}")\n'
        else:
            mi_body += f'surface_material_override/0 = ExtResource("{mat_id}")\n'
    nest = f"{parent_str}/{name}" if parent_str != "." else name
    scene.node(
        f'[node name="Mesh" type="MeshInstance3D" parent="{nest}"]\n'
        f'{mi_body}'
    )
    # Collision stanza.
    scene.node(
        f'[node name="Col" type="CollisionShape3D" parent="{nest}"]\n'
        f'shape = SubResource("{shape_id}")\n'
    )


def emit_wall_with_openings(scene: Scene, parent: str, prefix: str,
                            wall_origin, wall_size, axis: str,
                            openings, mat_id: str | None) -> None:
    length, height, thickness = wall_size
    openings = sorted(openings, key=lambda o: o["x"])
    segments = []
    cursor_x = 0.0
    for op in openings:
        ox = float(op["x"])
        ow = float(op["width"])
        oh = float(op["height"])
        sill = float(op.get("sill", 0.0))
        if ox > cursor_x:
            segments.append((cursor_x, ox, 0.0, height))
        if sill > 0.0:
            segments.append((ox, ox + ow, 0.0, sill))
        lintel_bottom = sill + oh
        if lintel_bottom < height:
            segments.append((ox, ox + ow, lintel_bottom, height))
        cursor_x = ox + ow
    if cursor_x < length:
        segments.append((cursor_x, length, 0.0, height))
    if not openings:
        segments = [(0.0, length, 0.0, height)]
    wx, wy, wz = wall_origin
    for idx, (x0, x1, y0, y1) in enumerate(segments):
        seg_len = x1 - x0
        seg_h = y1 - y0
        if seg_len <= 0.001 or seg_h <= 0.001:
            continue
        center_x_local = (x0 + x1) * 0.5
        center_y_local = (y0 + y1) * 0.5
        if axis == "x":
            pos = (wx + center_x_local, wy + center_y_local, wz)
            size = (seg_len, seg_h, thickness)
        else:
            pos = (wx, wy + center_y_local, wz + center_x_local)
            size = (thickness, seg_h, seg_len)
        emit_box(scene, parent, f"{prefix}_seg{idx}", pos, size, mat_id)


# ---------------------------------------------------------------------------
# Blueprint helpers.

def _find_room(blueprint, name):
    for r in blueprint.get("rooms", []):
        if r["name"] == name:
            return r
    return None


def _opposite(side):
    return {"north": "south", "south": "north",
            "east": "west", "west": "east"}.get(side, side)


def _inject_opening(room, side, opening):
    walls = room.setdefault("walls", {})
    side_spec = walls.setdefault(side, {})
    side_spec.setdefault("openings", []).append(opening)


def _auto_mirror_shared_openings(blueprint, tol=0.1):
    """Mirror openings across shared walls so doors render on both
    sides. Gd_mario verbatim."""
    rooms = blueprint.get("rooms", [])

    def wall_world_plane(room, side):
        ox, _oy, oz = room["origin"]
        sx, _sy, sz = room["size"]
        return {"south": oz, "north": oz + sz,
                "west":  ox, "east":  ox + sx}[side]

    def wall_world_axis_range(room, side):
        ox, _oy, oz = room["origin"]
        sx, _sy, sz = room["size"]
        if side in ("north", "south"):
            return (ox, ox + sx)
        return (oz, oz + sz)

    for a in rooms:
        a_origin = a["origin"]
        walls = a.get("walls", {})
        for side, spec in list(walls.items()):
            openings = spec.get("openings", [])
            if not openings:
                continue
            ox_a, _oy_a, oz_a = a_origin
            for op in list(openings):
                if op.get("_auto_mirrored"):
                    continue
                plane_a = wall_world_plane(a, side)
                lx = float(op.get("x", 0.0))
                lw = float(op.get("width", 0.0))
                if side in ("north", "south"):
                    world_start = ox_a + lx
                else:
                    world_start = oz_a + lx
                world_end = world_start + lw
                opp = _opposite(side)
                for b in rooms:
                    if b is a:
                        continue
                    if abs(wall_world_plane(b, opp) - plane_a) > tol:
                        continue
                    b_start, b_end = wall_world_axis_range(b, opp)
                    cs = max(world_start, b_start)
                    ce = min(world_end, b_end)
                    if ce - cs < 0.5:
                        continue
                    local_x = cs - b_start
                    local_w = ce - cs
                    b_walls = b.setdefault("walls", {})
                    b_spec = b_walls.setdefault(opp, {})
                    b_openings = b_spec.setdefault("openings", [])
                    already = False
                    for bo in b_openings:
                        bx = float(bo.get("x", 0.0))
                        bw = float(bo.get("width", 0.0))
                        if not (local_x + local_w < bx or local_x > bx + bw):
                            already = True
                            break
                    if already:
                        continue
                    mirror = dict(op)
                    mirror["x"] = local_x
                    mirror["width"] = local_w
                    mirror["_auto_mirrored"] = True
                    b_openings.append(mirror)
                    break


# ---------------------------------------------------------------------------
# Material resolver. Returns (mat_id, is_sub_resource) for emit_box's
# material argument.

def resolve_material(scene: Scene, spec) -> tuple[str | None, bool]:
    """spec may be:
      - None / empty string -> (None, False)
      - "res://..." string -> register as ExtResource; returns (id, False)
      - dict {"albedo":[r,g,b,a?], ...} -> bake a StandardMaterial3D sub_resource
      - tuple/list of 3-4 floats -> shorthand for {"albedo": [...]}
    """
    if spec is None or spec == "":
        return (None, False)
    if isinstance(spec, str):
        if spec.startswith("res://"):
            # Slugify into an ext-resource alias.
            alias = "mat_" + os.path.basename(spec).replace(".", "_")
            scene.add_ext(alias, "Material", spec)
            return (alias, False)
        # Otherwise treat as already-resolved alias.
        return (spec, False)
    if isinstance(spec, (list, tuple)):
        rid = scene.color_mat(spec)
        return (rid, True)
    if isinstance(spec, dict):
        albedo = spec.get("albedo", [0.8, 0.8, 0.8])
        roughness = float(spec.get("roughness", 0.9))
        metallic = float(spec.get("metallic", 0.0))
        emission = spec.get("emission")
        emission_e = float(spec.get("emission_energy", 1.0))
        rid = scene.color_mat(albedo, roughness=roughness, metallic=metallic,
                              emission=emission, emission_energy=emission_e)
        return (rid, True)
    return (None, False)


def resolve_material_map(scene: Scene, materials: dict) -> dict[str, tuple[str | None, bool]]:
    out = {}
    for name, spec in (materials or {}).items():
        out[name] = resolve_material(scene, spec)
    return out


# ---------------------------------------------------------------------------
# Environment / player-camera-HUD footer emission. Matches the patterns
# build_dungeon.py uses so blueprint-built scenes load with the same
# autoload wiring.

def emit_environment(scene: Scene, env: dict | None) -> None:
    if not env:
        return
    has_sky = any(k in env for k in (
        "sky_top", "sky_horizon", "ground_horizon", "ground_bottom"))
    sky_sub = None
    if has_sky:
        sky_mat = scene.sub("ProceduralSkyMaterial", [
            ("sky_top_color",        cstr(env.get("sky_top",        [0.45, 0.62, 0.86, 1]))),
            ("sky_horizon_color",    cstr(env.get("sky_horizon",    [0.86, 0.85, 0.78, 1]))),
            ("ground_horizon_color", cstr(env.get("ground_horizon", [0.55, 0.46, 0.32, 1]))),
            ("ground_bottom_color",  cstr(env.get("ground_bottom",  [0.20, 0.16, 0.10, 1]))),
        ])
        sky_sub = scene.sub("Sky", [("sky_material", 'SubResource("%s")' % sky_mat)])
    env_props = [("background_mode", "2")]
    if sky_sub:
        env_props.append(("sky", 'SubResource("%s")' % sky_sub))
    if "ambient_color" in env:
        env_props.append(("ambient_light_source", "3"))
        env_props.append(("ambient_light_color", cstr(env["ambient_color"])))
        env_props.append(("ambient_light_energy", "%g" % env.get("ambient_energy", 0.45)))
    if "fog_density" in env:
        env_props.append(("fog_enabled", "true"))
        env_props.append(("fog_density", "%g" % env["fog_density"]))
        if "fog_color" in env:
            env_props.append(("fog_light_color", cstr(env["fog_color"])))
    env_id = scene.sub("Environment", env_props)
    scene.node(
        '[node name="Environment" type="WorldEnvironment" parent="."]\n'
        f'environment = SubResource("{env_id}")\n'
    )
    if "sun_dir" in env:
        sd = env["sun_dir"]
        f = [-v for v in sd]
        mag = max(1e-6, math.sqrt(sum(c * c for c in f)))
        f = [c / mag for c in f]
        up = [0, 1, 0] if abs(f[1]) < 0.99 else [1, 0, 0]
        r = [up[1] * f[2] - up[2] * f[1],
             up[2] * f[0] - up[0] * f[2],
             up[0] * f[1] - up[1] * f[0]]
        rmag = max(1e-6, math.sqrt(sum(c * c for c in r)))
        r = [c / rmag for c in r]
        u = [f[1] * r[2] - f[2] * r[1],
             f[2] * r[0] - f[0] * r[2],
             f[0] * r[1] - f[1] * r[0]]
        z = f
        tx = "Transform3D(%g, %g, %g, %g, %g, %g, %g, %g, %g, 0, 14, 0)" % (
            r[0], r[1], r[2], u[0], u[1], u[2], z[0], z[1], z[2])
        scene.node(
            '[node name="Sun" type="DirectionalLight3D" parent="."]\n'
            f'transform = {tx}\n'
            f'light_color = {cstr(env.get("sun_color", [0.95, 0.85, 0.65, 1]))}\n'
            f'light_energy = {env.get("sun_energy", 0.9)}\n'
            'shadow_enabled = true\n'
        )


def emit_player_camera_hud(scene: Scene) -> None:
    scene.ext("tux")
    scene.ext("hud")
    scene.ext("glim")
    scene.ext("camera_script")
    scene.ext("debug_script")
    scene.ext("pause_script")
    scene.node(
        '[node name="Tux" parent="." instance=ExtResource("tux")]\n'
        'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)\n'
        'camera_path = NodePath("../Camera")\n'
    )
    scene.node(
        '[node name="Glim" parent="." instance=ExtResource("glim")]\n'
        'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -0.6, 1.4, 0)\n'
    )
    scene.node(
        '[node name="Camera" type="Node3D" parent="."]\n'
        'script = ExtResource("camera_script")\n'
    )
    scene.node(
        '[node name="SpringArm" type="SpringArm3D" parent="Camera"]\n'
        'spring_length = 4.5\n'
        'margin = 0.05\n'
    )
    scene.node(
        '[node name="Camera" type="Camera3D" parent="Camera/SpringArm"]\n'
        'fov = 70.0\n'
    )
    scene.node('[node name="HUD" parent="." instance=ExtResource("hud")]\n')
    scene.node(
        '[node name="DebugOverlay" type="CanvasLayer" parent="."]\n'
        'script = ExtResource("debug_script")\n'
        'visible_initial = false\n'
    )
    scene.node(
        '[node name="PauseMenu" type="CanvasLayer" parent="."]\n'
        'script = ExtResource("pause_script")\n'
    )


# ---------------------------------------------------------------------------
# Tux-prop emission. Each "tux_props" entry maps onto one of our existing
# prefab scenes via EXT_RESOURCES. Schema mirrors what build_dungeon.py
# accepts under "props" so authoring is consistent across pipelines.

def emit_tux_props(scene: Scene, props: list) -> None:
    for i, p in enumerate(props or []):
        kind = p.get("type", "")
        if not kind:
            continue
        x, y, z = p["pos"]
        rot = float(p.get("rotation_y", 0.0))
        xf = xform_translate(x, y, z, rot)
        if kind == "sign":
            scene.ext("sign")
            scene.node(
                f'[node name="Sign{i}" parent="." instance=ExtResource("sign")]\n'
                f'transform = {xf}\n'
                f'message = "{escape(p.get("message", ""))}"\n'
            )
        elif kind == "chest":
            scene.ext("chest")
            contents_key = p.get("contents", "")
            if contents_key == "item":
                ext_name = CONTENTS_TO_EXT.get(p.get("item_name", ""), "boomerang_pickup")
            else:
                ext_name = CONTENTS_TO_EXT.get(contents_key, "")
            attrs = [f'transform = {xf}']
            if ext_name:
                scene.ext(ext_name)
                attrs.append(f'contents_scene = ExtResource("{ext_name}")')
            if p.get("open_message"):
                attrs.append(f'open_message = "{escape(p["open_message"])}"')
            if "amount" in p:
                attrs.append(f'contents_amount = {int(p["amount"])}')
            if p.get("item_name"):
                attrs.append(f'contents_item_name = "{escape(str(p["item_name"]))}"')
            if "key_group" in p:
                attrs.append(f'contents_key_group = "{escape(str(p["key_group"]))}"')
            if "requires" in p:
                attrs.append(f'requires_flag = "{escape(str(p["requires"]))}"')
            scene.node(
                f'[node name="Chest{i}" parent="." instance=ExtResource("chest")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "bush":
            scene.ext("bush")
            attrs = [f'transform = {xf}']
            if "drop_chance" in p:
                attrs.append(f'drop_chance = {float(p["drop_chance"]):g}')
            if "pebble_amount" in p:
                attrs.append(f'pebble_amount = {int(p["pebble_amount"])}')
            scene.node(
                f'[node name="Bush{i}" parent="." instance=ExtResource("bush")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "rock":
            scene.ext("rock")
            attrs = [f'transform = {xf}']
            if "pebble_chance" in p:
                attrs.append(f'pebble_chance = {float(p["pebble_chance"]):g}')
            scene.node(
                f'[node name="Rock{i}" parent="." instance=ExtResource("rock")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "tree":
            scene.ext("tree")
            attrs = [f'transform = {xf}']
            if "pebble_chance" in p:
                attrs.append(f'pebble_chance = {float(p["pebble_chance"]):g}')
            if "trunk_height" in p:
                attrs.append(f'trunk_height = {float(p["trunk_height"]):g}')
            if "canopy_radius" in p:
                attrs.append(f'canopy_radius = {float(p["canopy_radius"]):g}')
            scene.node(
                f'[node name="Tree{i}" parent="." instance=ExtResource("tree")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "npc":
            scene.ext("npc")
            attrs = [f'transform = {xf}']
            name = p.get("name", "")
            if name:
                attrs.append(f'npc_name = "{escape(str(name))}"')
            if "body_color" in p:
                attrs.append(f'body_color = {cstr(p["body_color"])}')
            if "hat_color" in p:
                attrs.append(f'hat_color = {cstr(p["hat_color"])}')
            if "idle_hint" in p:
                attrs.append(f'idle_hint = "{escape(str(p["idle_hint"]))}"')
            tree_spec = p.get("dialog_tree")
            if tree_spec:
                tree_json = json.dumps(tree_spec, ensure_ascii=False)
                attrs.append(f'dialog_tree_json = "{escape(tree_json)}"')
            node_name = f"Npc{i}"
            if name:
                safe = "".join(ch if ch.isalnum() else "_" for ch in str(name))
                node_name = f"Npc{i}_{safe}"
            scene.node(
                f'[node name="{node_name}" parent="." instance=ExtResource("npc")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "owl_statue":
            scene.ext("owl_statue")
            attrs = [f'transform = {xf}']
            for fld in ("warp_id", "warp_name", "warp_target_scene", "warp_target_spawn"):
                if fld in p:
                    attrs.append(f'{fld} = "{escape(str(p[fld]))}"')
            wid_safe = "".join(ch if ch.isalnum() else "_"
                               for ch in str(p.get("warp_id", str(i))))
            scene.node(
                f'[node name="OwlStatue_{wid_safe}" parent="." instance=ExtResource("owl_statue")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "bomb_flower":
            scene.ext("bomb_flower")
            scene.node(
                f'[node name="BombFlower{i}" parent="." instance=ExtResource("bomb_flower")]\n'
                f'transform = {xf}\n'
            )
        elif kind == "destructible_wall":
            scene.ext("destructible_wall")
            scene.node(
                f'[node name="DestructibleWall{i}" parent="." instance=ExtResource("destructible_wall")]\n'
                f'transform = {xf}\n'
            )
        elif kind == "crystal_switch":
            scene.ext("crystal_switch")
            attrs = [f'transform = {xf}']
            if "target_id" in p:
                attrs.append(f'target_id = "{escape(str(p["target_id"]))}"')
            if "stays_on" in p:
                attrs.append(f'stays_on = {"true" if p["stays_on"] else "false"}')
            scene.node(
                f'[node name="CrystalSwitch{i}" parent="." instance=ExtResource("crystal_switch")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "pressure_plate":
            scene.ext("pressure_plate")
            attrs = [f'transform = {xf}']
            if "target_id" in p:
                attrs.append(f'target_id = "{escape(str(p["target_id"]))}"')
            if "holds" in p:
                attrs.append(f'holds = {"true" if p["holds"] else "false"}')
            scene.node(
                f'[node name="PressurePlate{i}" parent="." instance=ExtResource("pressure_plate")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "door":
            scene.ext("door")
            scene.node(
                f'[node name="Door{i}" parent="." instance=ExtResource("door")]\n'
                f'transform = {xf}\n'
            )
        elif kind == "triggered_gate":
            scene.ext("triggered_gate")
            attrs = [f'transform = {xf}']
            if "listen_id" in p:
                attrs.append(f'listen_id = "{escape(str(p["listen_id"]))}"')
            scene.node(
                f'[node name="TriggeredGate{i}" parent="." instance=ExtResource("triggered_gate")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "time_gate":
            scene.ext("time_gate")
            attrs = [f'transform = {xf}']
            if "time_phase" in p:
                attrs.append(f'time_phase = "{escape(str(p["time_phase"]))}"')
            scene.node(
                f'[node name="TimeGate{i}" parent="." instance=ExtResource("time_gate")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "hookshot_target":
            scene.ext("hookshot_target")
            scene.node(
                f'[node name="HookshotTarget{i}" parent="." instance=ExtResource("hookshot_target")]\n'
                f'transform = {xf}\n'
            )
        elif kind == "torch":
            scene.ext("torch")
            attrs = [f'transform = {xf}']
            if "lit_on_spawn" in p:
                attrs.append(f'lit_on_spawn = {"true" if p["lit_on_spawn"] else "false"}')
            scene.node(
                f'[node name="Torch{i}" parent="." instance=ExtResource("torch")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "eye_target":
            scene.ext("eye_target")
            attrs = [f'transform = {xf}']
            if "target_id" in p:
                attrs.append(f'target_id = "{escape(str(p["target_id"]))}"')
            scene.node(
                f'[node name="EyeTarget{i}" parent="." instance=ExtResource("eye_target")]\n'
                + "\n".join(attrs) + "\n"
            )
        elif kind == "boss_arena":
            scene.ext("boss_arena")
            attrs = [f'transform = {xf}']
            boss_id = p.get("boss_scene_id", "")
            boss_ext = ENEMY_TO_EXT.get(boss_id)
            if boss_ext:
                scene.ext(boss_ext)
                attrs.append(f'boss_scene = ExtResource("{boss_ext}")')
            if "boss_name" in p:
                attrs.append(f'boss_name = "{escape(str(p["boss_name"]))}"')
            if "arena_radius" in p:
                attrs.append(f'arena_radius = {float(p["arena_radius"]):g}')
            scene.node(
                f'[node name="BossArena{i}" parent="." instance=ExtResource("boss_arena")]\n'
                + "\n".join(attrs) + "\n"
            )
        # Unknown kinds are silently skipped — the blueprint may declare
        # types we haven't wired yet without breaking the build.


# ---------------------------------------------------------------------------
# Spawns / load_zones / enemies.

def emit_spawns(scene: Scene, spawns: list,
                blueprint: dict) -> None:
    scene.node('[node name="Spawns" type="Node3D" parent="."]\n')
    seen_ids = set()
    spawns = list(spawns or [])
    # Convenience: `spawn_point` becomes the "default" spawn if no
    # spawns list explicitly defines one.
    sp = blueprint.get("spawn_point")
    if sp is not None and not any(s.get("id") == "default" for s in spawns):
        spawns.insert(0, {"id": "default", "pos": list(sp), "rotation_y": 0.0})
    for sp_entry in spawns:
        sid = sp_entry.get("id", "default")
        if sid in seen_ids:
            continue
        seen_ids.add(sid)
        x, y, z = sp_entry["pos"]
        rot = float(sp_entry.get("rotation_y", 0.0))
        scene.node(
            f'[node name="{sid}" type="Marker3D" parent="Spawns"]\n'
            f'transform = {xform_translate(x, y, z, rot)}\n'
        )


def emit_load_zones(scene: Scene, zones: list) -> None:
    for i, lz in enumerate(zones or []):
        scene.ext("load_zone_script")
        x, y, z = lz["pos"]
        sx, sy, sz = lz.get("size", [3.0, 3.0, 1.0])
        rot = float(lz.get("rotation_y", 0.0))
        target_scene = lz["target_scene"]
        if not target_scene.startswith("res://"):
            target_scene = "res://scenes/%s.tscn" % target_scene
        target_spawn = lz.get("target_spawn", "default")
        auto = "true" if lz.get("auto", True) else "false"
        prompt = escape(lz.get("prompt", ""))
        shape = scene.sub("BoxShape3D", [("size", vec(sx, sy, sz))])
        attrs = [
            f'transform = {xform_translate(x, y, z, rot)}',
            'collision_layer = 64',
            'collision_mask = 2',
            'monitoring = true',
            'script = ExtResource("load_zone_script")',
            f'target_scene = "{target_scene}"',
            f'target_spawn = "{target_spawn}"',
            f'auto_trigger = {auto}',
        ]
        if prompt:
            attrs.append(f'prompt = "{prompt}"')
        scene.node(
            f'[node name="LoadZone{i}" type="Area3D" parent="."]\n'
            + "\n".join(attrs) + "\n"
        )
        scene.node(
            f'[node name="Shape" type="CollisionShape3D" parent="LoadZone{i}"]\n'
            f'shape = SubResource("{shape}")\n'
        )
        scene.node(
            f'[node name="Hint" type="Label3D" parent="LoadZone{i}"]\n'
            f'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, {sy + 0.8:g}, 0)\n'
            f'text = "{prompt or "Travel"}"\n'
            'font_size = 32\n'
            'outline_size = 8\n'
            'billboard = 1\n'
            'no_depth_test = true\n'
        )


def emit_enemies(scene: Scene, enemies: list) -> None:
    for i, en in enumerate(enemies or []):
        ext_name = ENEMY_TO_EXT.get(en.get("type", ""))
        if not ext_name:
            continue
        scene.ext(ext_name)
        x, y, z = en["pos"]
        scene.node(
            f'[node name="{en["type"].capitalize()}{i}" parent="." instance=ExtResource("{ext_name}")]\n'
            f'transform = {xform_translate(x, y, z)}\n'
        )


# ---------------------------------------------------------------------------
# Rooms / terrain / extras (gd_mario pieces, trimmed to what we use).

def emit_room(scene: Scene, room: dict, mat_map: dict, wall_t: float,
              parent: str) -> None:
    rname = room["name"]
    ox, oy, oz = room["origin"]
    sx, sy, sz = room["size"]
    room_mat_id, room_mat_is_sub = mat_map.get(room.get("material", ""), (None, True))
    floor_spec = room.get("floor_material", room.get("material", ""))
    floor_mat_id, floor_mat_is_sub = mat_map.get(floor_spec, (None, True))

    # Sanitize room name for node use.
    safe_rname = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in rname)

    scene.node(
        f'[node name="{safe_rname}" type="Node3D" parent="{parent}"]\n'
        f'transform = {xform_translate(ox, oy, oz)}\n'
    )
    room_parent = safe_rname if parent == "." else f"{parent}/{safe_rname}"

    # Floor + ceiling.
    if room.get("floor", True):
        _emit_slab_with_holes(scene, room_parent, "Floor",
                              sx, sz, -0.1, 0.2,
                              room.get("floor_holes", []),
                              floor_mat_id if floor_mat_is_sub else None)
    if room.get("ceiling", True):
        _emit_slab_with_holes(scene, room_parent, "Ceiling",
                              sx, sz, sy + 0.1, 0.2,
                              room.get("ceiling_holes", []),
                              room_mat_id if room_mat_is_sub else None)

    walls = room.get("walls", {})
    mat_for_walls = room_mat_id if room_mat_is_sub else None
    if "north" in walls:
        emit_wall_with_openings(scene, room_parent, "WallN",
                                (0.0, 0.0, sz), (sx, sy, wall_t),
                                "x", walls["north"].get("openings", []),
                                mat_for_walls)
    if "south" in walls:
        emit_wall_with_openings(scene, room_parent, "WallS",
                                (0.0, 0.0, 0.0), (sx, sy, wall_t),
                                "x", walls["south"].get("openings", []),
                                mat_for_walls)
    if "east" in walls:
        emit_wall_with_openings(scene, room_parent, "WallE",
                                (sx, 0.0, 0.0), (sz, sy, wall_t),
                                "z", walls["east"].get("openings", []),
                                mat_for_walls)
    if "west" in walls:
        emit_wall_with_openings(scene, room_parent, "WallW",
                                (0.0, 0.0, 0.0), (sz, sy, wall_t),
                                "z", walls["west"].get("openings", []),
                                mat_for_walls)


def emit_terrain_patches(scene: Scene, patches: list, mat_map: dict) -> None:
    for patch in patches or []:
        ox, oy, oz = patch["origin"]
        pname = patch.get("name") or f"Terrain_{ox}_{oy}_{oz}"
        # Sanitize.
        safe = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in pname)
        size_x = float(patch.get("size_x", 10.0))
        size_z = float(patch.get("size_z", 10.0))
        res = int(patch.get("resolution", 8))
        heights = patch.get("heights") or [0.0] * (res * res)
        if len(heights) != res * res:
            heights = (list(heights) + [0.0] * (res * res))[: res * res]
        heights_literal = "PackedFloat32Array(" + ", ".join(
            f"{float(h):.4f}" for h in heights) + ")"
        flat_c = patch.get("flat_color") or [0.35, 0.55, 0.22]
        slope_c = patch.get("slope_color") or [0.45, 0.32, 0.18]
        slope_thr = float(patch.get("slope_threshold", 0.72))
        slope_soft = float(patch.get("slope_softness", 0.15))
        scene.ext("terrain_patch_script")
        # Sink the patch 2cm to avoid Z-fight with room floor slabs.
        TERRAIN_Z_OFFSET = 0.02
        body_lines = [
            f'transform = {xform_translate(ox, oy - TERRAIN_Z_OFFSET, oz)}',
            'script = ExtResource("terrain_patch_script")',
            f'metadata/terrain_heights = {heights_literal}',
            f'metadata/terrain_size_x = {size_x}',
            f'metadata/terrain_size_z = {size_z}',
            f'metadata/terrain_resolution = {res}',
            f'metadata/terrain_material = ""',
            f'metadata/terrain_flat_color = [{flat_c[0]}, {flat_c[1]}, {flat_c[2]}]',
            f'metadata/terrain_slope_color = [{slope_c[0]}, {slope_c[1]}, {slope_c[2]}]',
            f'metadata/terrain_slope_threshold = {slope_thr}',
            f'metadata/terrain_slope_softness = {slope_soft}',
        ]
        surface_grid = patch.get("surface_grid") or []
        if len(surface_grid) != (res - 1) * (res - 1):
            surface_grid = [""] * ((res - 1) * (res - 1))
        grid_literal = "[" + ", ".join(f'"{str(s)}"' for s in surface_grid) + "]"
        body_lines.append(f'metadata/terrain_surface_grid = {grid_literal}')
        water_y = patch.get("water_level_y")
        if water_y is not None:
            body_lines.append(f'metadata/terrain_water_level_y = {float(water_y)}')
        scene.node(
            f'[node name="{safe}" type="Node3D" parent="."]\n'
            + "\n".join(body_lines) + "\n"
        )


def emit_extras(scene: Scene, extras: list, mat_map: dict) -> None:
    """Minimal extras: pillars, platforms. Stairs/spiral/elevator left
    to a future pass — none of our 3 POC blueprints need them."""
    for extra in extras or []:
        kind = extra.get("type")
        px, py, pz = extra["pos"]
        mat_id, mat_is_sub = mat_map.get(extra.get("material", ""), (None, True))
        name = extra.get("name") or f"Extra_{kind}_{px}_{py}_{pz}"
        safe = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in name)
        if kind == "pillar":
            r = float(extra.get("radius", 0.4))
            h = float(extra.get("height", 4.0))
            emit_box(scene, ".", safe,
                     (px, py + h / 2.0, pz),
                     (r * 2.0, h, r * 2.0),
                     mat_id if mat_is_sub else None)
        elif kind == "platform":
            s = extra["size"]
            emit_box(scene, ".", safe,
                     (px + s[0] / 2.0, py + s[1] / 2.0, pz + s[2] / 2.0),
                     tuple(s),
                     mat_id if mat_is_sub else None)


# ---------------------------------------------------------------------------
# Top-level builder.

def build_scene(blueprint: dict) -> Scene:
    scene = Scene()
    scene_id = blueprint["id"]
    name = blueprint.get("name", scene_id)

    # 1. Pre-passes that mutate the blueprint in place (gd_mario).
    _auto_mirror_shared_openings(blueprint)

    # 2. Materials.
    mat_map = resolve_material_map(scene, blueprint.get("materials", {}))

    # 3. Root node (must come first, before sub-trees).
    scene.ext("root_script")
    key_group   = blueprint.get("key_group",   scene_id)
    music_track = blueprint.get("music_track", scene_id)
    fs_path     = blueprint.get("fs_path",     "")
    root_attrs = [
        'script = ExtResource("root_script")',
        f'key_group = "{escape(str(key_group))}"',
        f'music_track = "{escape(str(music_track))}"',
        f'display_name = "{escape(str(name))}"',
        f'fs_path = "{escape(str(fs_path))}"',
    ]
    for k in ("sky_color", "fog_color", "ambient_color", "sun_color"):
        v = blueprint.get(k)
        if v is None:
            continue
        if len(v) == 3:
            v = list(v) + [1.0]
        root_attrs.append(f'{k} = Color({v[0]:g}, {v[1]:g}, {v[2]:g}, {v[3]:g})')
    scene.node(
        f'[node name="{name}" type="Node3D"]\n'
        + "\n".join(root_attrs) + "\n"
    )

    # 4. Environment + sun.
    emit_environment(scene, blueprint.get("environment"))

    # 5. Building / world content.
    wall_t = float(blueprint.get("wall_thickness", 0.3))
    for room in blueprint.get("rooms", []):
        emit_room(scene, room, mat_map, wall_t, ".")
    emit_terrain_patches(scene, blueprint.get("terrain_patches", []), mat_map)
    emit_extras(scene, blueprint.get("extras", []), mat_map)

    # 6. Tux props + enemies + spawns + load_zones.
    emit_tux_props(scene, blueprint.get("tux_props", []))
    emit_enemies(scene, blueprint.get("enemies", []))
    emit_spawns(scene, blueprint.get("spawns", []), blueprint)
    emit_load_zones(scene, blueprint.get("load_zones", []))

    # 7. Player + camera + HUD footer.
    emit_player_camera_hud(scene)
    return scene


# ---------------------------------------------------------------------------
# CLI.

def convert_id(scene_id: str) -> None:
    blueprint_path = os.path.join(BLUEPRINTS, scene_id + ".json")
    with open(blueprint_path) as f:
        blueprint = json.load(f)
    # The id from the file always wins (lets blueprint name itself).
    blueprint.setdefault("id", scene_id)
    scene = build_scene(blueprint)
    out_path = os.path.join(SCENES_OUT, blueprint["id"] + ".tscn")
    # Mint a deterministic uid based on the id (matching build_dungeon.py
    # style: btux<sluggified-id>01). Required so other scenes that
    # ext_resource us via uid resolve consistently.
    uid = "uid://btux" + blueprint["id"].replace("_", "")[:10] + "bp"
    with open(out_path, "w") as f:
        f.write(scene.format(scene_uid=uid))
    print(f"wrote {os.path.relpath(out_path)} — {len(scene.nodes)} nodes, "
          f"{len(scene.sub_resources)} subresources, "
          f"{len(scene.ext_resources)} ext resources")


def convert_path(blueprint_path: str, out_path: str) -> None:
    with open(blueprint_path) as f:
        blueprint = json.load(f)
    blueprint.setdefault("id", os.path.basename(blueprint_path).rsplit(".", 1)[0])
    scene = build_scene(blueprint)
    uid = "uid://btux" + blueprint["id"].replace("_", "")[:10] + "bp"
    with open(out_path, "w") as f:
        f.write(scene.format(scene_uid=uid))
    print(f"wrote {out_path} — {len(scene.nodes)} nodes, "
          f"{len(scene.sub_resources)} subresources, "
          f"{len(scene.ext_resources)} ext resources")


def main() -> int:
    args = sys.argv[1:]
    if not args:
        # Build every blueprint in the directory.
        if not os.path.isdir(BLUEPRINTS):
            print("no blueprints/ directory; nothing to do")
            return 0
        targets = sorted(
            f.rsplit(".", 1)[0]
            for f in os.listdir(BLUEPRINTS) if f.endswith(".json")
        )
        for t in targets:
            convert_id(t)
        return 0
    # Two-arg legacy form (blueprint.json + out.tscn).
    if len(args) == 2 and args[0].endswith(".json") and args[1].endswith(".tscn"):
        convert_path(args[0], args[1])
        return 0
    # Otherwise treat args as ids.
    for a in args:
        if a.endswith(".json"):
            a = os.path.basename(a).rsplit(".", 1)[0]
        convert_id(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
