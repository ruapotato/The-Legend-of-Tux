#!/usr/bin/env python3
"""Convert dungeons/*.json → godot/scenes/*.tscn

Run from repo root:
    python3 tools/build_dungeon.py             # convert all dungeons/*.json
    python3 tools/build_dungeon.py wyrdwood    # convert just wyrdwood.json

Schema (rough; see dungeons/*.json for live examples):
    {
      "name":        str,
      "id":          str,           # output filename (and target_scene path)
      "environment": {
        "sky_top":         [r,g,b,a]?,    # ProceduralSkyMaterial colors
        "sky_horizon":     [r,g,b,a]?,
        "ground_horizon":  [r,g,b,a]?,
        "ground_bottom":   [r,g,b,a]?,
        "ambient_color":   [r,g,b,a]?,
        "ambient_energy":  float?,        # 0..1
        "fog_density":     float?,
        "fog_color":       [r,g,b,a]?,
        "sun_dir":         [x,y,z]?,      # optional directional light
        "sun_color":       [r,g,b,a]?,
        "sun_energy":      float?,
      },
      "floor":  {                         # optional (set null for "no floor")
        "rect":  [x_min, z_min, x_max, z_max],
        "y":     float,
        "color": [r,g,b,a],
      },
      "rooms": [                          # for indoor levels with walls
        {"id", "rect": [x_min, z_min, x_max, z_max],
         "wall_height", "wall_color"}
      ],
      "doorways": [                       # cuts in shared/single-room walls
        {"rooms": ["entry","boss"]?,      # optional; just a wall cutout otherwise
         "x", "z", "width",
         "door": {"type": "open|unlocked|locked",
                  "locked_message"?, "unlock_message"?} | null
        }
      ],
      "tree_walls": [                     # for outdoor zones
        {"boundary": [[x,z],[x,z],...],
         "spacing"?, "trunk_height"?, "canopy_radius"?, "seed"?,
         "trunk_color"?, "canopy_color"?, "wall_height"?}
      ],
      "spawns": [{"id", "pos":[x,y,z], "rotation_y"?}],
      "lights": [{"pos":[x,y,z], "color":[r,g,b,a], "energy":float, "range":float}],
      "enemies": [{"type":"blob|knight|bat", "pos":[x,y,z]}],
      "props": [
        {"type":"sign", "pos":[x,y,z], "rotation_y"?, "message":str},
        {"type":"chest", "pos":[x,y,z], "rotation_y"?, "contents":"key|boomerang|...", "open_message"?}
      ],
      "load_zones": [
        {"pos":[x,y,z], "size":[w,h,d], "rotation_y"?,
         "target_scene": "wyrdwood",     # bare id, not res://
         "target_spawn": "from_glade",
         "auto"?: bool,                   # default true; false → needs E + prompt
         "prompt"?: str}
      ]
    }

Output is a single .tscn referencing the prefab scenes in godot/scenes/
and the runtime scripts in godot/scripts/.
"""

import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS_DIR  = os.path.join(ROOT, "dungeons")
SCENES_OUT    = os.path.join(ROOT, "godot", "scenes")

# Map schema-name → (type, uid-or-None, res:// path). The converter
# only emits ext_resources for the names it actually uses.
EXT_RESOURCES = {
    "tux":              ("PackedScene", "uid://btuxpl01",   "res://scenes/tux.tscn"),
    "hud":              ("PackedScene", "uid://btuxhud01",  "res://scenes/hud.tscn"),
    "blob":             ("PackedScene", "uid://btuxblb01",  "res://scenes/enemy_blob.tscn"),
    "knight":           ("PackedScene", "uid://btuxbnk01",  "res://scenes/enemy_bone_knight.tscn"),
    "bat":              ("PackedScene", "uid://btuxbat01",  "res://scenes/enemy_bone_bat.tscn"),
    "sign":             ("PackedScene", "uid://btuxsgnp01", "res://scenes/sign_post.tscn"),
    "door":             ("PackedScene", "uid://btuxdoor01", "res://scenes/door.tscn"),
    "chest":            ("PackedScene", "uid://btuxchst01", "res://scenes/treasure_chest.tscn"),
    "key_pickup":       ("PackedScene", "uid://btuxpkky01", "res://scenes/pickup_key.tscn"),
    "boomerang_pickup": ("PackedScene", "uid://btuxbmrg01", "res://scenes/boomerang.tscn"),
    "glim":             ("PackedScene", "uid://btuxglim01", "res://scenes/glim.tscn"),
    "camera_script":    ("Script",      None,               "res://scripts/free_orbit_camera.gd"),
    "debug_script":     ("Script",      None,               "res://scripts/debug_overlay.gd"),
    "pause_script":     ("Script",      None,               "res://scripts/pause_menu.gd"),
    "root_script":      ("Script",      None,               "res://scripts/dungeon_root.gd"),
    "load_zone_script": ("Script",      None,               "res://scripts/load_zone.gd"),
    "tree_wall_script": ("Script",      None,               "res://scripts/tree_wall.gd"),
}

CONTENTS_TO_EXT = {
    "key":       "key_pickup",
    "boomerang": "boomerang_pickup",
}

ENEMY_TO_EXT = {
    "blob":   "blob",
    "knight": "knight",
    "bat":    "bat",
}

WALL_THICKNESS = 0.5


# ---- formatters ---------------------------------------------------------

def cstr(c):
    if c is None:
        return None
    if len(c) == 3:
        c = list(c) + [1.0]
    return "Color(%g, %g, %g, %g)" % tuple(c)


def vstr(v):
    return "Vector3(%g, %g, %g)" % tuple(v)


def t3(x, y, z, rot_y=0.0):
    if abs(rot_y) < 1e-6:
        return "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)" % (x, y, z)
    cy = math.cos(rot_y)
    sy = math.sin(rot_y)
    return "Transform3D(%g, 0, %g, 0, 1, 0, %g, 0, %g, %g, %g, %g)" % (
        cy, -sy, sy, cy, x, y, z)


def t3_scale(sx, sy, sz, x=0, y=0, z=0):
    return "Transform3D(%g, 0, 0, 0, %g, 0, 0, 0, %g, %g, %g, %g)" % (sx, sy, sz, x, y, z)


def escape(s):
    if s is None:
        return ""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# ---- builder ------------------------------------------------------------

class Builder:
    def __init__(self, data):
        self.data = data
        self.id = data["id"]
        self.subs = []     # list of (id, type, props_lines)
        self.nodes = []    # list of node-stanza strings
        self.ext_used = set()
        self._sub_n = 0
        self._color_mat = {}

    # ---- ext / sub helpers -----

    def ext(self, name):
        self.ext_used.add(name)
        return name

    def add_sub(self, t, props):
        self._sub_n += 1
        rid = "s%d" % self._sub_n
        self.subs.append((rid, t, props))
        return rid

    def color_mat(self, color, roughness=0.9, metallic=0.0):
        key = (tuple(color), roughness, metallic)
        if key in self._color_mat:
            return self._color_mat[key]
        rid = self.add_sub("StandardMaterial3D", [
            ("albedo_color", cstr(color)),
            ("roughness",    "%g" % roughness),
            ("metallic",     "%g" % metallic),
        ])
        self._color_mat[key] = rid
        return rid

    # ---- header -----

    def emit(self):
        body = []
        # Compute load_steps = ext_resources + sub_resources + 1 (root)
        load_steps = len(self.ext_used) + len(self.subs) + 1
        body.append('[gd_scene load_steps=%d format=3 uid="uid://btux%s01"]\n'
                    % (load_steps, self.id.replace("_", "")[:8]))
        # ext_resources
        for name in self.ext_used:
            t, uid, path = EXT_RESOURCES[name]
            if uid:
                body.append('[ext_resource type="%s" uid="%s" path="%s" id="%s"]'
                            % (t, uid, path, name))
            else:
                body.append('[ext_resource type="%s" path="%s" id="%s"]'
                            % (t, path, name))
        if self.ext_used:
            body.append("")
        # sub_resources
        for rid, t, props in self.subs:
            body.append('[sub_resource type="%s" id="%s"]' % (t, rid))
            for k, v in props:
                body.append("%s = %s" % (k, v))
            body.append("")
        # nodes
        body.extend(self.nodes)
        return "\n".join(body)

    # ---- node helpers -----

    def add_node(self, stanza):
        self.nodes.append(stanza)


# ---- geometry helpers --------------------------------------------------

def emit_floor(b, floor):
    if floor is None:
        return
    rect = floor["rect"]
    y = floor.get("y", 0.0)
    color = floor.get("color", [0.30, 0.42, 0.26, 1])
    x_min, z_min, x_max, z_max = rect
    sx = float(x_max - x_min)
    sz = float(z_max - z_min)
    cx = (x_min + x_max) / 2.0
    cz = (z_min + z_max) / 2.0
    mat = b.color_mat(color, roughness=0.95)
    shape = b.add_sub("BoxShape3D", [("size", vstr([sx, 0.4, sz]))])
    mesh  = b.add_sub("PlaneMesh",  [("size", "Vector2(%g, %g)" % (sx, sz))])
    b.add_node(
        '[node name="Floor" type="StaticBody3D" parent="."]\n'
        'transform = %s\n'
        'collision_layer = 1\n'
        'collision_mask = 0\n\n'
        '[node name="Shape" type="CollisionShape3D" parent="Floor"]\n'
        'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.2, 0)\n'
        'shape = SubResource("%s")\n\n'
        '[node name="Mesh" type="MeshInstance3D" parent="Floor"]\n'
        'mesh = SubResource("%s")\n'
        'surface_material_override/0 = SubResource("%s")\n'
        % (t3(cx, y, cz), shape, mesh, mat)
    )


def doorway_segments(side_kind, sx1, sz1, sx2, sz2, doorways, door_width):
    """Given a side and the doorway points lying on it, return a list of
    sub-segments (start, end) along the side that survive after cutting
    out doorway gaps. side_kind is 'h' (constant z) or 'v' (constant x).
    Each doorway widens ±door_width/2 around its center."""
    if side_kind == "h":
        a, b = min(sx1, sx2), max(sx1, sx2)
        cuts = []
        for d in doorways:
            w = float(d.get("width", door_width))
            cuts.append((d["x"] - w/2, d["x"] + w/2))
    else:
        a, b = min(sz1, sz2), max(sz1, sz2)
        cuts = []
        for d in doorways:
            w = float(d.get("width", door_width))
            cuts.append((d["z"] - w/2, d["z"] + w/2))
    cuts.sort()
    segments = []
    cursor = a
    for c0, c1 in cuts:
        if c1 < a or c0 > b:
            continue
        c0 = max(c0, a); c1 = min(c1, b)
        if cursor < c0:
            segments.append((cursor, c0))
        cursor = max(cursor, c1)
    if cursor < b:
        segments.append((cursor, b))
    return segments


def emit_walls(b, rooms, doorways):
    if not rooms:
        return
    wall_idx = [0]
    def add_wall(cx, cy, cz, sx, sy, sz, color, rot_y=0.0):
        wall_idx[0] += 1
        mat = b.color_mat(color, roughness=0.92)
        shape = b.add_sub("BoxShape3D", [("size", vstr([sx, sy, sz]))])
        mesh  = b.add_sub("BoxMesh",    [("size", vstr([sx, sy, sz]))])
        b.add_node(
            '[node name="Wall%d" type="StaticBody3D" parent="."]\n'
            'transform = %s\n'
            'collision_layer = 1\n'
            'collision_mask = 0\n\n'
            '[node name="Shape" type="CollisionShape3D" parent="Wall%d"]\n'
            'shape = SubResource("%s")\n\n'
            '[node name="Mesh" type="MeshInstance3D" parent="Wall%d"]\n'
            'mesh = SubResource("%s")\n'
            'surface_material_override/0 = SubResource("%s")\n'
            % (wall_idx[0], t3(cx, cy, cz, rot_y), wall_idx[0], shape,
               wall_idx[0], mesh, mat)
        )

    # For each room side, find applicable doorways and emit wall segments.
    # Walls of rooms that share an edge will be emitted twice — accept
    # the duplication; the boxes are coincident so it's invisible.
    for room in rooms:
        x_min, z_min, x_max, z_max = room["rect"]
        h = float(room.get("wall_height", 4.0))
        color = room.get("wall_color", [0.42, 0.38, 0.32, 1])

        sides = [
            # kind, fixed-axis-value, sx1, sz1, sx2, sz2
            ("h", z_min, x_min, z_min, x_max, z_min),  # south side: constant z
            ("h", z_max, x_min, z_max, x_max, z_max),  # north side
            ("v", x_max, x_max, z_min, x_max, z_max),  # east side
            ("v", x_min, x_min, z_min, x_min, z_max),  # west side
        ]
        for kind, fixed, sx1, sz1, sx2, sz2 in sides:
            # Doorways on this side: position must lie on the segment
            # (within tolerance) and the doorway must list this room
            # (or list no rooms — meaning "wall cutout, not a room link").
            on_side = []
            for dw in (doorways or []):
                if "rooms" in dw:
                    if room["id"] not in dw["rooms"]:
                        continue
                if kind == "h":
                    if abs(dw.get("z", 1e9) - fixed) < 0.05 \
                            and min(sx1, sx2) - 1 <= dw["x"] <= max(sx1, sx2) + 1:
                        on_side.append(dw)
                else:
                    if abs(dw.get("x", 1e9) - fixed) < 0.05 \
                            and min(sz1, sz2) - 1 <= dw["z"] <= max(sz1, sz2) + 1:
                        on_side.append(dw)
            segments = doorway_segments(kind, sx1, sz1, sx2, sz2, on_side,
                                         door_width=2.0)
            for a, c in segments:
                length = c - a
                if length < 0.05:
                    continue
                if kind == "h":
                    cx = (a + c) / 2
                    cz = fixed + (WALL_THICKNESS/2 if fixed < (z_min+z_max)/2 else -WALL_THICKNESS/2)
                    add_wall(cx, h/2, fixed, length, h, WALL_THICKNESS, color)
                else:
                    cz = (a + c) / 2
                    add_wall(fixed, h/2, cz, WALL_THICKNESS, h, length, color)


def emit_doors(b, doorways):
    for i, dw in enumerate(doorways or []):
        door = dw.get("door")
        if not door:
            continue
        kind = door.get("type", "open")
        if kind == "open":
            continue
        b.ext("door")
        x = dw["x"]; z = dw["z"]
        rot = 0.0 if "x" in dw and "z" in dw and "rotation_y" not in dw else dw.get("rotation_y", 0.0)
        # Door faces such that "open" lifts upward — no rotation needed
        # for either axis since the door mesh is centered at origin.
        requires_key = "true" if kind == "locked" else "false"
        locked_msg = escape(door.get("locked_message", "Locked. A small key would open this door."))
        unlock_msg = escape(door.get("unlock_message", "The lock turns. The door slides open."))
        b.add_node(
            '[node name="Door%d" parent="." instance=ExtResource("door")]\n'
            'transform = %s\n'
            'requires_key = %s\n'
            'locked_message = "%s"\n'
            'unlock_message = "%s"\n'
            % (i, t3(x, 0, z, rot), requires_key, locked_msg, unlock_msg)
        )


def emit_tree_walls(b, walls):
    for i, tw in enumerate(walls or []):
        b.ext("tree_wall_script")
        boundary = tw["boundary"]
        boundary_str = "PackedVector2Array(" + ", ".join(
            "%g, %g" % (p[0], p[1]) for p in boundary
        ) + ")"
        props = [
            'script = ExtResource("tree_wall_script")',
            'boundary_points = %s' % boundary_str,
        ]
        if "closed" in tw:
            props.append("closed = %s" % ("true" if tw["closed"] else "false"))
        for k in ("spacing", "trunk_height", "canopy_radius", "seed", "wall_height"):
            if k in tw:
                props.append("%s = %g" % (k, tw[k]))
        for k in ("trunk_color", "canopy_color"):
            if k in tw:
                props.append("%s = %s" % (k, cstr(tw[k])))
        b.add_node(
            '[node name="TreeWall%d" type="Node3D" parent="."]\n'
            % i + "\n".join(props) + "\n"
        )


def emit_lights(b, lights):
    for i, lt in enumerate(lights or []):
        x, y, z = lt["pos"]
        color = cstr(lt.get("color", [1.0, 0.85, 0.70, 1]))
        energy = float(lt.get("energy", 1.0))
        rng = float(lt.get("range", 10.0))
        b.add_node(
            '[node name="Light%d" type="OmniLight3D" parent="."]\n'
            'transform = %s\n'
            'light_color = %s\n'
            'light_energy = %g\n'
            'omni_range = %g\n'
            % (i, t3(x, y, z), color, energy, rng)
        )


def emit_environment(b, env):
    if not env:
        return
    has_sky = any(k in env for k in ("sky_top", "sky_horizon", "ground_horizon", "ground_bottom"))
    if has_sky:
        sky_mat = b.add_sub("ProceduralSkyMaterial", [
            ("sky_top_color",        cstr(env.get("sky_top",        [0.45, 0.62, 0.86, 1]))),
            ("sky_horizon_color",    cstr(env.get("sky_horizon",    [0.86, 0.85, 0.78, 1]))),
            ("ground_horizon_color", cstr(env.get("ground_horizon", [0.55, 0.46, 0.32, 1]))),
            ("ground_bottom_color",  cstr(env.get("ground_bottom",  [0.20, 0.16, 0.10, 1]))),
        ])
        sky = b.add_sub("Sky", [("sky_material", 'SubResource("%s")' % sky_mat)])
    env_props = [
        ("background_mode", "2"),
    ]
    if has_sky:
        env_props.append(("sky", 'SubResource("%s")' % sky))
    if "ambient_color" in env:
        env_props.append(("ambient_light_source", "3"))
        env_props.append(("ambient_light_color", cstr(env["ambient_color"])))
        env_props.append(("ambient_light_energy", "%g" % env.get("ambient_energy", 0.45)))
    if "fog_density" in env:
        env_props.append(("fog_enabled", "true"))
        env_props.append(("fog_density", "%g" % env["fog_density"]))
        if "fog_color" in env:
            env_props.append(("fog_light_color", cstr(env["fog_color"])))
    env_id = b.add_sub("Environment", env_props)
    b.add_node(
        '[node name="Environment" type="WorldEnvironment" parent="."]\n'
        'environment = SubResource("%s")\n' % env_id
    )
    # Sun
    if "sun_dir" in env:
        sd = env["sun_dir"]
        # rough "look_at(-sun_dir)" basis for a direction light
        f = [-v for v in sd]
        mag = max(1e-6, math.sqrt(sum(c*c for c in f)))
        f = [c/mag for c in f]
        # Construct a basis with z = -sun_dir, y = world up (or fallback)
        up = [0, 1, 0] if abs(f[1]) < 0.99 else [1, 0, 0]
        # right = up × f
        r = [up[1]*f[2] - up[2]*f[1], up[2]*f[0] - up[0]*f[2], up[0]*f[1] - up[1]*f[0]]
        rmag = max(1e-6, math.sqrt(sum(c*c for c in r)))
        r = [c/rmag for c in r]
        # u = f × r
        u = [f[1]*r[2] - f[2]*r[1], f[2]*r[0] - f[0]*r[2], f[0]*r[1] - f[1]*r[0]]
        # Transform3D columns (right, up, forward) — Godot uses -Z forward
        # so the basis Z column is -f? actually Godot DirectionalLight3D
        # shines along its -Z axis, so the Z column should equal +f (so
        # -Z = -f = sun_dir, the direction light points toward).
        z = f
        tx = "Transform3D(%g, %g, %g, %g, %g, %g, %g, %g, %g, 0, 14, 0)" % (
            r[0], r[1], r[2], u[0], u[1], u[2], z[0], z[1], z[2])
        b.add_node(
            '[node name="Sun" type="DirectionalLight3D" parent="."]\n'
            'transform = %s\n'
            'light_color = %s\n'
            'light_energy = %g\n'
            'shadow_enabled = true\n'
            % (tx, cstr(env.get("sun_color", [0.95, 0.85, 0.65, 1])), env.get("sun_energy", 0.9))
        )


def emit_spawns(b, spawns):
    b.add_node('[node name="Spawns" type="Node3D" parent="."]\n')
    for sp in (spawns or []):
        x, y, z = sp["pos"]
        rot = float(sp.get("rotation_y", 0.0))
        b.add_node(
            '[node name="%s" type="Marker3D" parent="Spawns"]\n'
            'transform = %s\n'
            % (sp["id"], t3(x, y, z, rot))
        )


def emit_enemies(b, enemies):
    for i, en in enumerate(enemies or []):
        ext_name = ENEMY_TO_EXT.get(en["type"])
        if not ext_name:
            continue
        b.ext(ext_name)
        x, y, z = en["pos"]
        b.add_node(
            '[node name="%s%d" parent="." instance=ExtResource("%s")]\n'
            'transform = %s\n'
            % (en["type"].capitalize(), i, ext_name, t3(x, y, z))
        )


def emit_props(b, props):
    for i, p in enumerate(props or []):
        kind = p["type"]
        x, y, z = p["pos"]
        rot = float(p.get("rotation_y", 0.0))
        if kind == "sign":
            b.ext("sign")
            msg = escape(p.get("message", ""))
            b.add_node(
                '[node name="Sign%d" parent="." instance=ExtResource("sign")]\n'
                'transform = %s\n'
                'message = "%s"\n'
                % (i, t3(x, y, z, rot), msg)
            )
        elif kind == "chest":
            b.ext("chest")
            contents_key = p.get("contents", "")
            ext_name = CONTENTS_TO_EXT.get(contents_key, "")
            msg = escape(p.get("open_message", ""))
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if ext_name:
                b.ext(ext_name)
                attrs.append('contents_scene = ExtResource("%s")' % ext_name)
            if msg:
                attrs.append('open_message = "%s"' % msg)
            b.add_node(
                '[node name="Chest%d" parent="." instance=ExtResource("chest")]\n'
                % i + "\n".join(attrs) + "\n"
            )


def emit_load_zones(b, zones):
    for i, lz in enumerate(zones or []):
        b.ext("load_zone_script")
        x, y, z = lz["pos"]
        sx, sy, sz = lz.get("size", [3.0, 3.0, 1.0])
        rot = float(lz.get("rotation_y", 0.0))
        target_scene = lz["target_scene"]
        if not target_scene.startswith("res://"):
            target_scene = "res://scenes/%s.tscn" % target_scene
        target_spawn = lz.get("target_spawn", "default")
        auto = "true" if lz.get("auto", True) else "false"
        prompt = escape(lz.get("prompt", ""))
        shape = b.add_sub("BoxShape3D", [("size", vstr([sx, sy, sz]))])
        # Dark "veil" plane behind the trigger so the player can't see
        # bright sky through the tree-wall gap. Sized to the trigger's
        # width × height; sits inside the trigger so it's flush with
        # the portal entrance.
        # Veil orientation auto-detected from trigger size: the wall
        # is perpendicular to whichever horizontal dimension is
        # smaller (that's the "thin" axis = wall normal). The veil's
        # flat face must match.
        if sx < sz:
            veil_size_arr = [0.1, sy + 1.5, sz + 0.5]
        else:
            veil_size_arr = [sx + 0.5, sy + 1.5, 0.1]
        veil_mesh = b.add_sub("BoxMesh", [("size", vstr(veil_size_arr))])
        veil_mat = b.add_sub("StandardMaterial3D", [
            ("albedo_color",  "Color(0.02, 0.02, 0.04, 1)"),
            ("shading_mode",  "0"),
            ("emission_enabled", "true"),
            ("emission",      "Color(0, 0, 0, 1)"),
        ])
        attrs = [
            'transform = %s' % t3(x, y, z, rot),
            'collision_layer = 64',
            'collision_mask = 2',
            'monitoring = true',
            'script = ExtResource("load_zone_script")',
            'target_scene = "%s"' % target_scene,
            'target_spawn = "%s"' % target_spawn,
            'auto_trigger = %s' % auto,
        ]
        if prompt:
            attrs.append('prompt = "%s"' % prompt)
        b.add_node(
            '[node name="LoadZone%d" type="Area3D" parent="."]\n'
            % i + "\n".join(attrs) + '\n\n'
            '[node name="Shape" type="CollisionShape3D" parent="LoadZone%d"]\n'
            'shape = SubResource("%s")\n\n'
            '[node name="Veil" type="MeshInstance3D" parent="LoadZone%d"]\n'
            'mesh = SubResource("%s")\n'
            'surface_material_override/0 = SubResource("%s")\n\n'
            '[node name="Hint" type="Label3D" parent="LoadZone%d"]\n'
            'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 0)\n'
            'text = "%s"\n'
            'font_size = 32\n'
            'outline_size = 8\n'
            'billboard = 1\n'
            'no_depth_test = true\n'
            % (i, shape, i, veil_mesh, veil_mat, i, sy + 0.8, prompt or "Travel")
        )


def emit_player_camera_hud(b):
    b.ext("tux"); b.ext("hud"); b.ext("glim")
    b.ext("camera_script"); b.ext("debug_script"); b.ext("pause_script")
    b.add_node(
        '[node name="Tux" parent="." instance=ExtResource("tux")]\n'
        'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.5, 0)\n'
        'camera_path = NodePath("../Camera")\n'
    )
    b.add_node(
        '[node name="Glim" parent="." instance=ExtResource("glim")]\n'
        'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, -0.6, 1.4, 0)\n'
    )
    b.add_node(
        '[node name="Camera" type="Node3D" parent="."]\n'
        'script = ExtResource("camera_script")\n\n'
        '[node name="SpringArm" type="SpringArm3D" parent="Camera"]\n'
        'spring_length = 4.5\n'
        'margin = 0.05\n\n'
        '[node name="Camera" type="Camera3D" parent="Camera/SpringArm"]\n'
        'fov = 70.0\n'
    )
    b.add_node('[node name="HUD" parent="." instance=ExtResource("hud")]\n')
    b.add_node(
        '[node name="DebugOverlay" type="CanvasLayer" parent="."]\n'
        'script = ExtResource("debug_script")\n'
        'visible_initial = false\n'
    )
    b.add_node(
        '[node name="PauseMenu" type="CanvasLayer" parent="."]\n'
        'script = ExtResource("pause_script")\n'
    )


# ---- main ---------------------------------------------------------------

def convert(json_path):
    with open(json_path) as f:
        data = json.load(f)
    b = Builder(data)
    b.ext("root_script")
    # Root node first (must precede everything)
    root_attrs = [
        'script = ExtResource("root_script")',
    ]
    b.nodes.append('[node name="%s" type="Node3D"]\n%s\n'
                   % (data.get("name", data["id"]), "\n".join(root_attrs)))
    emit_environment(b, data.get("environment", {}))
    emit_floor(b, data.get("floor"))
    emit_walls(b, data.get("rooms", []), data.get("doorways", []))
    emit_doors(b, data.get("doorways", []))
    emit_tree_walls(b, data.get("tree_walls", []))
    emit_lights(b, data.get("lights", []))
    emit_spawns(b, data.get("spawns", []))
    emit_enemies(b, data.get("enemies", []))
    emit_props(b, data.get("props", []))
    emit_load_zones(b, data.get("load_zones", []))
    emit_player_camera_hud(b)

    out_path = os.path.join(SCENES_OUT, data["id"] + ".tscn")
    with open(out_path, "w") as f:
        f.write(b.emit())
    print("wrote", os.path.relpath(out_path))


def main():
    targets = sys.argv[1:]
    if targets:
        paths = [
            os.path.join(DUNGEONS_DIR, name + ".json") if not name.endswith(".json") else name
            for name in targets
        ]
    else:
        paths = sorted(
            os.path.join(DUNGEONS_DIR, f) for f in os.listdir(DUNGEONS_DIR)
            if f.endswith(".json")
        )
    for p in paths:
        convert(p)


if __name__ == "__main__":
    main()
