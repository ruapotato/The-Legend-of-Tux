#!/usr/bin/env python3
"""build_zones.py — generate one .tscn per zone from godot/world.json.

Run once to bootstrap; after that, hand-tweaks in the in-game editor
(or Godot editor) are the source of truth and re-running this WILL
overwrite them. So edit world.json + re-run to bootstrap new zones,
edit .tscn in-editor for everything after that.

Skips zone keys starting with `_` and entries lacking a "scene" field
(reserved for the `_future_zones` stub block).

Output structure of each .tscn:
  Root (Node3D, group=level_root)
    Sun (DirectionalLight3D)
    Spawns/<spawn_id> (Node3D + spawn_marker script)
    Tux (instance + tux_player.gd + camera path)
    Camera (free_orbit_camera + SpringArm + Camera3D)
    Glim (instance)
    HUD (instance)
    Placed (container — everything that's editor-placeable)
      TerrainMesh (terrain_point_mesh instance + Point children)
      Trees/Bushes/Rocks/Torches/Pebbles
      Walls (wall_segment with computed transforms)
      Chests, Signs, NPCs, Enemies
      LoadZones
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
GODOT_DIR = PROJECT_ROOT / "godot"
WORLD_JSON = GODOT_DIR / "world.json"


# ---- Formatting helpers --------------------------------------------------

def fmt_float(v: float) -> str:
    """Format a float for .tscn — strip trailing zeros, no scientific."""
    if isinstance(v, int) or v == int(v):
        return f"{int(v)}"
    return f"{v:.6f}".rstrip("0").rstrip(".")


def xform(pos, rot_y_deg: float = 0.0, scale_xyz=(1.0, 1.0, 1.0)) -> str:
    """A Transform3D rotated around Y by rot_y_deg and translated to pos."""
    rot = math.radians(rot_y_deg)
    c, s = math.cos(rot), math.sin(rot)
    sx, sy, sz = scale_xyz
    parts = [
        c * sx, 0, s * sx,
        0, sy, 0,
        -s * sz, 0, c * sz,
        pos[0], pos[1], pos[2],
    ]
    return "Transform3D(" + ", ".join(fmt_float(v) for v in parts) + ")"


def color_lit(rgba) -> str:
    """Color(...) string for .tscn property lines."""
    rgba = list(rgba)
    if len(rgba) == 3:
        rgba.append(1.0)
    return "Color(" + ", ".join(fmt_float(v) for v in rgba) + ")"


def gstr(s: str) -> str:
    """Godot-escape a string for use as a .tscn property value."""
    out = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{out}"'


def camel(zone_id: str) -> str:
    return "".join(part.capitalize() for part in zone_id.split("_"))


# ---- The builder ---------------------------------------------------------

class TscnBuilder:
    def __init__(self) -> None:
        self.ext: dict[tuple[str, str], str] = {}
        self.body: list[str] = []
        self._n = 0

    def ext_of(self, type_: str, path: str) -> str:
        key = (type_, path)
        if key not in self.ext:
            self._n += 1
            self.ext[key] = f"r{self._n}"
        return self.ext[key]

    def add(self, line: str = "") -> None:
        self.body.append(line)

    def render(self) -> str:
        load_steps = max(1, len(self.ext) + 1)
        out: list[str] = [f"[gd_scene load_steps={load_steps} format=3]", ""]
        for (type_, path), tag in self.ext.items():
            out.append(f'[ext_resource type="{type_}" path="{path}" id="{tag}"]')
        out.append("")
        out.extend(self.body)
        return "\n".join(out) + "\n"


# ---- Zone builder --------------------------------------------------------

def build_zone(zone_id: str, zone_def: dict, world: dict) -> str:
    b = TscnBuilder()

    tux_id   = b.ext_of("PackedScene", "res://scenes/tux.tscn")
    tuxp_id  = b.ext_of("Script", "res://scripts/tux_player.gd")
    cam_id   = b.ext_of("Script", "res://scripts/free_orbit_camera.gd")
    glim_id  = b.ext_of("PackedScene", "res://scenes/glim.tscn")
    hud_id   = b.ext_of("PackedScene", "res://scenes/hud.tscn")
    sp_id    = b.ext_of("PackedScene", "res://scenes/spawn_marker.tscn")

    sun_color = color_lit(zone_def.get("sun_color", [1.0, 1.0, 1.0]))

    root = camel(zone_id)
    b.add(f'[node name="{root}" type="Node3D" groups=["level_root"]]')
    b.add()

    # Sun — angled afternoon light. Editable in editor.
    b.add('[node name="Sun" type="DirectionalLight3D" parent="."]')
    b.add(f"transform = Transform3D(0.866, 0, -0.5, 0.25, 0.866, 0.433, "
          f"0.433, -0.5, 0.75, 0, 30, 0)")
    b.add(f"light_color = {sun_color}")
    b.add("shadow_enabled = true")
    b.add()

    # Spawns container
    b.add('[node name="Spawns" type="Node3D" parent="."]')
    b.add()

    spawns = zone_def.get("spawns", [{"id": "default", "pos": [0, 1, 0]}])
    for sp in spawns:
        b.add(f'[node name="{sp["id"]}" type="Node3D" parent="Spawns" '
              f'instance=ExtResource("{sp_id}")]')
        b.add(f"transform = {xform(sp['pos'])}")
        b.add(f'metadata/spawn_id = "{sp["id"]}"')
        b.add()

    # Tux
    b.add(f'[node name="Tux" type="CharacterBody3D" parent="." '
          f'instance=ExtResource("{tux_id}")]')
    b.add(f"transform = {xform([0, 1, 0])}")
    b.add("collision_layer = 2")
    b.add("collision_mask = 5")
    b.add(f'script = ExtResource("{tuxp_id}")')
    b.add('camera_path = NodePath("../Camera")')
    b.add()

    # Camera assembly
    b.add('[node name="Camera" type="Node3D" parent="." '
          'node_paths=PackedStringArray("target_node")]')
    b.add(f"transform = {xform([0, 1, 0])}")
    b.add(f'script = ExtResource("{cam_id}")')
    b.add('target_node = NodePath("../Tux")')
    b.add()
    b.add('[node name="SpringArm" type="SpringArm3D" parent="Camera"]')
    b.add('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.6, 0)')
    b.add("spring_length = 5.0")
    b.add()
    b.add('[node name="Camera" type="Camera3D" parent="Camera/SpringArm"]')
    b.add("current = true")
    b.add()

    # Glim companion
    b.add(f'[node name="Glim" type="Node3D" parent="." '
          f'instance=ExtResource("{glim_id}")]')
    b.add(f"transform = {xform([0.5, 1.7, 0])}")
    b.add()

    # HUD
    b.add(f'[node name="HUD" type="CanvasLayer" parent="." '
          f'instance=ExtResource("{hud_id}")]')
    b.add()

    # Placed container — everything below is editor-tweakable.
    b.add('[node name="Placed" type="Node3D" parent="."]')
    b.add()

    _emit_terrains(b, zone_def)
    _emit_simple_props(b, zone_def, "trees", "Tree", "res://scenes/tree_prop.tscn")
    _emit_simple_props(b, zone_def, "bushes", "Bush", "res://scenes/bush.tscn")
    _emit_simple_props(b, zone_def, "rocks", "Rock", "res://scenes/rock.tscn")
    _emit_simple_props(b, zone_def, "torches", "Torch", "res://scenes/torch.tscn")
    _emit_simple_props(b, zone_def, "pebbles", "Pebble",
                       "res://scenes/pickup_pebble.tscn")
    _emit_cottages(b, zone_def)
    _emit_water_volumes(b, zone_def)
    _emit_walls(b, zone_def)
    _emit_chests(b, zone_def)
    _emit_signs(b, zone_def)
    _emit_npcs(b, zone_def)
    _emit_enemies(b, zone_def)
    _emit_load_zones(b, zone_def, world)

    return b.render()


# ---- Per-category emitters ----------------------------------------------

def _emit_terrains(b: TscnBuilder, zone_def: dict) -> None:
    # Supports both schemas: legacy {"terrain": {...}} singular and the
    # new {"terrains": [{...}, {...}]} multi-mesh form. Multi-mesh lets
    # one zone mix biome colours (grass + dirt path + rock ridge, etc.)
    # since each TerrainPointMesh is a single solid colour.
    terrains: list = []
    if isinstance(zone_def.get("terrains"), list):
        terrains = zone_def["terrains"]
    elif isinstance(zone_def.get("terrain"), dict):
        terrains = [zone_def["terrain"]]
    if not terrains:
        return
    tpm_id = b.ext_of("PackedScene", "res://scenes/terrain_point_mesh.tscn")
    for ti, terrain in enumerate(terrains, start=1):
        mesh_name = f"TerrainMesh{ti}" if len(terrains) > 1 else "TerrainMesh"
        b.add(f'[node name="{mesh_name}" type="StaticBody3D" parent="Placed" '
              f'instance=ExtResource("{tpm_id}")]')
        b.add(f"transform = {xform([0, 0, 0])}")
        b.add("collision_mask = 0")
        if "color" in terrain:
            b.add(f"terrain_color = {color_lit(terrain['color'])}")
        if terrain.get("shaded"):
            b.add("shaded = true")
        b.add()
        for i, p in enumerate(terrain.get("points", []), start=1):
            b.add(f'[node name="Point{i}" type="StaticBody3D" '
                  f'parent="Placed/{mesh_name}"]')
            b.add(f"transform = {xform(p)}")
            b.add("collision_layer = 64")
            b.add("collision_mask = 0")
            b.add("metadata/is_terrain_point = true")
            b.add()


def _emit_cottages(b: TscnBuilder, zone_def: dict) -> None:
    cottages = zone_def.get("cottages", [])
    if not cottages:
        return
    cid = b.ext_of("PackedScene", "res://scenes/cottage.tscn")
    for i, c in enumerate(cottages, start=1):
        if isinstance(c, dict):
            pos = c["pos"]
            rot = c.get("rot_y", 0)
        else:
            pos = c
            rot = 0
        b.add(f'[node name="Cottage{i}" parent="Placed" '
              f'instance=ExtResource("{cid}")]')
        b.add(f"transform = {xform(pos, rot)}")
        b.add()


def _emit_water_volumes(b: TscnBuilder, zone_def: dict) -> None:
    volumes = zone_def.get("water_volumes", [])
    if not volumes:
        return
    wid = b.ext_of("PackedScene", "res://scenes/water_volume.tscn")
    for i, w in enumerate(volumes, start=1):
        pos = w.get("pos", [0, 0, 0])
        size = w.get("size", [4, 0.5, 4])
        # Bake size into a non-uniform scale on the water_volume instance.
        b.add(f'[node name="Water{i}" parent="Placed" '
              f'instance=ExtResource("{wid}")]')
        b.add(f"transform = {xform(pos, w.get('rot_y', 0), tuple(size))}")
        b.add()


def _emit_simple_props(b: TscnBuilder, zone_def: dict, key: str,
                       label: str, scene_path: str) -> None:
    items = zone_def.get(key, [])
    if not items:
        return
    rid = b.ext_of("PackedScene", scene_path)
    for i, pos in enumerate(items, start=1):
        b.add(f'[node name="{label}{i}" parent="Placed" '
              f'instance=ExtResource("{rid}")]')
        b.add(f"transform = {xform(pos)}")
        b.add()


def _emit_walls(b: TscnBuilder, zone_def: dict) -> None:
    walls = zone_def.get("walls", [])
    if not walls:
        return
    wid = b.ext_of("PackedScene", "res://scenes/wall_segment.tscn")
    for i, w in enumerate(walls, start=1):
        a, c = w["a"], w["b"]
        mid = [(a[0] + c[0]) / 2.0, 0.0, (a[1] + c[1]) / 2.0]
        dx, dz = c[0] - a[0], c[1] - a[1]
        length = math.hypot(dx, dz)
        yaw_deg = math.degrees(math.atan2(dx, dz))
        # The wall_segment scene defaults to 10m along local +Z.
        sz = max(length / 10.0, 0.1)
        xf = xform(mid, yaw_deg, scale_xyz=(1.0, 1.0, sz))
        b.add(f'[node name="Wall{i}" parent="Placed" '
              f'instance=ExtResource("{wid}")]')
        b.add(f"transform = {xf}")
        b.add()


def _emit_chests(b: TscnBuilder, zone_def: dict) -> None:
    chests = zone_def.get("chests", [])
    if not chests:
        return
    cid = b.ext_of("PackedScene", "res://scenes/treasure_chest.tscn")
    for i, c in enumerate(chests, start=1):
        b.add(f'[node name="Chest{i}" parent="Placed" '
              f'instance=ExtResource("{cid}")]')
        b.add(f"transform = {xform(c['pos'], c.get('rot_y', 0))}")
        if "grants_item" in c:
            b.add(f'grants_item = "{c["grants_item"]}"')
        if "grants_flag" in c:
            b.add(f'grants_flag = "{c["grants_flag"]}"')
        if "open_message" in c:
            b.add(f"open_message = {gstr(c['open_message'])}")
        if "contents_scene" in c:
            csid = b.ext_of("PackedScene", c["contents_scene"])
            b.add(f'contents_scene = ExtResource("{csid}")')
        b.add()


def _emit_signs(b: TscnBuilder, zone_def: dict) -> None:
    signs = zone_def.get("signs", [])
    if not signs:
        return
    sid = b.ext_of("PackedScene", "res://scenes/sign_post.tscn")
    for i, s in enumerate(signs, start=1):
        b.add(f'[node name="Sign{i}" parent="Placed" '
              f'instance=ExtResource("{sid}")]')
        b.add(f"transform = {xform(s['pos'], s.get('rot_y', 0))}")
        b.add(f"message = {gstr(s['message'])}")
        b.add()


def _emit_npcs(b: TscnBuilder, zone_def: dict) -> None:
    npcs = zone_def.get("npcs", [])
    if not npcs:
        return
    nid = b.ext_of("PackedScene", "res://scenes/npc.tscn")
    for i, n in enumerate(npcs, start=1):
        b.add(f'[node name="NPC{i}" parent="Placed" '
              f'instance=ExtResource("{nid}")]')
        b.add(f"transform = {xform(n['pos'], n.get('rot_y', 0))}")
        b.add(f'npc_name = "{n["name"]}"')
        if "idle_hint" in n:
            b.add(f"idle_hint = {gstr(n['idle_hint'])}")
        if "body_color" in n:
            b.add(f"body_color = {color_lit(n['body_color'])}")
        if "hat_color" in n:
            b.add(f"hat_color = {color_lit(n['hat_color'])}")
        if "dialog_text" in n:
            tree = {"start": {"text": n["dialog_text"]}}
            b.add(f"dialog_tree_json = {gstr(json.dumps(tree))}")
        b.add()


def _emit_enemies(b: TscnBuilder, zone_def: dict) -> None:
    enemies = zone_def.get("enemies", [])
    if not enemies:
        return
    for i, e in enumerate(enemies, start=1):
        path = e["type"]
        if not path.startswith("res://"):
            path = f"res://scenes/{path}"
        eid = b.ext_of("PackedScene", path)
        name = Path(path).stem
        b.add(f'[node name="{name}_{i}" parent="Placed" '
              f'instance=ExtResource("{eid}")]')
        b.add(f"transform = {xform(e['pos'], e.get('rot_y', 0))}")
        b.add()


def _emit_load_zones(b: TscnBuilder, zone_def: dict, world: dict) -> None:
    lzs = zone_def.get("load_zones", [])
    if not lzs:
        return
    lid = b.ext_of("PackedScene", "res://scenes/load_zone.tscn")
    for i, lz in enumerate(lzs, start=1):
        target_scene = world["zones"].get(lz["to_zone"], {}).get("scene", "")
        b.add(f'[node name="LoadZone{i}" parent="Placed" '
              f'instance=ExtResource("{lid}")]')
        b.add(f"transform = {xform(lz['pos'], lz.get('rot_y', 0))}")
        b.add(f'target_scene = "{target_scene}"')
        b.add(f'target_spawn = "{lz.get("to_spawn", "default")}"')
        if "prompt" in lz:
            b.add(f"prompt = {gstr(lz['prompt'])}")
        if "requires_flag" in lz:
            b.add(f'requires_flag = "{lz["requires_flag"]}"')
        if "requires_item" in lz:
            b.add(f'requires_item = "{lz["requires_item"]}"')
        if "gate_message" in lz:
            b.add(f"gate_message = {gstr(lz['gate_message'])}")
        b.add()


# ---- Main ---------------------------------------------------------------

def main() -> int:
    if not WORLD_JSON.exists():
        print(f"missing {WORLD_JSON}", file=sys.stderr)
        return 1
    world = json.loads(WORLD_JSON.read_text())
    count = 0
    for zone_id, zone_def in world.get("zones", {}).items():
        if zone_id.startswith("_"):
            continue
        if "scene" not in zone_def:
            continue
        scene_rel = zone_def["scene"].removeprefix("res://")
        out_path = GODOT_DIR / scene_rel
        out_path.parent.mkdir(parents=True, exist_ok=True)
        tscn = build_zone(zone_id, zone_def, world)
        out_path.write_text(tscn)
        print(f"  wrote {out_path.relative_to(PROJECT_ROOT)}")
        count += 1
    print(f"done — {count} zone(s) generated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
