#!/usr/bin/env python3
"""Convert dungeons/*.json → godot/scenes/*.tscn

Run from repo root:
    python3 tools/build_dungeon.py             # convert all dungeons/*.json
    python3 tools/build_dungeon.py wyrdwood    # convert just wyrdwood.json

Schema (rough; see dungeons/*.json for live examples):
    {
      "name":        str,
      "id":          str,           # output filename (and target_scene path)
      "key_group":   str?,          # per-dungeon small-key bucket; defaults
                                    # to `id`. Adjacent levels share a
                                    # group (Ocarina-style multi-room
                                    # dungeon) by setting the same value.
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
                  "key_group"?: str,      # override the dungeon's key bucket
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
        {"type":"chest", "pos":[x,y,z], "rotation_y"?, "contents":"key|boomerang|...",
         "key_group"?: str,             # for contents=="key": override the
                                        # dungeon's key bucket so the chest
                                        # awards a key for a different group
         "open_message"?}
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
    "tomato":           ("PackedScene", "uid://btuxtmto01", "res://scenes/enemy_tomato.tscn"),
    "spore":            ("PackedScene", "uid://btuxspr01",  "res://scenes/enemy_spore.tscn"),
    "wisp_hunter":      ("PackedScene", "uid://btuxwsph01", "res://scenes/enemy_wisp_hunter.tscn"),
    "skull_spider":     ("PackedScene", "uid://btuxsklsp01", "res://scenes/enemy_skull_spider.tscn"),
    "wyrdking":         ("PackedScene", "uid://btuxwyrk01", "res://scenes/enemy_wyrdking.tscn"),
    "sign":             ("PackedScene", "uid://btuxsgnp01", "res://scenes/sign_post.tscn"),
    "bush":             ("PackedScene", "uid://btuxbush01", "res://scenes/bush.tscn"),
    "rock":             ("PackedScene", "uid://btuxrock01", "res://scenes/rock.tscn"),
    "tree":             ("PackedScene", "uid://btuxtree01", "res://scenes/tree_prop.tscn"),
    "door":             ("PackedScene", "uid://btuxdoor01", "res://scenes/door.tscn"),
    "chest":            ("PackedScene", "uid://btuxchst01", "res://scenes/treasure_chest.tscn"),
    "crystal_switch":   ("PackedScene", "uid://btuxcrys01", "res://scenes/crystal_switch.tscn"),
    "pressure_plate":   ("PackedScene", "uid://btuxplt01",  "res://scenes/pressure_plate.tscn"),
    "movable_block":    ("PackedScene", "uid://btuxblck01", "res://scenes/movable_block.tscn"),
    "torch":            ("PackedScene", "uid://btuxtrch01", "res://scenes/torch.tscn"),
    "eye_target":       ("PackedScene", "uid://btuxeye01",  "res://scenes/eye_target.tscn"),
    "triggered_gate":   ("PackedScene", "uid://btuxtgte01", "res://scenes/triggered_gate.tscn"),
    "npc":              ("PackedScene", "uid://btuxnpc01",  "res://scenes/npc.tscn"),
    "key_pickup":       ("PackedScene", "uid://btuxpkky01", "res://scenes/pickup_key.tscn"),
    "pebble_pickup":    ("PackedScene", "uid://btuxpkpb01", "res://scenes/pickup_pebble.tscn"),
    "heart_pickup":     ("PackedScene", "uid://btuxpkht01", "res://scenes/pickup_heart.tscn"),
    "boomerang_pickup": ("PackedScene", "uid://btuxpkbmrg01", "res://scenes/pickup_boomerang.tscn"),
    "arrow_pickup":     ("PackedScene", "uid://btuxpkar01", "res://scenes/pickup_arrow.tscn"),
    "seed_pickup":      ("PackedScene", "uid://btuxpksd01", "res://scenes/pickup_seed.tscn"),
    "bow_pickup":       ("PackedScene", "uid://btuxpkbow01", "res://scenes/pickup_bow.tscn"),
    "slingshot_pickup": ("PackedScene", "uid://btuxpksl01", "res://scenes/pickup_slingshot.tscn"),
    "bomb":             ("PackedScene", "uid://btuxbomb01",  "res://scenes/bomb.tscn"),
    "bomb_flower":      ("PackedScene", "uid://btuxbflw01",  "res://scenes/bomb_flower.tscn"),
    "destructible_wall":("PackedScene", "uid://btuxdwall01", "res://scenes/destructible_wall.tscn"),
    "hookshot_target":  ("PackedScene", "uid://btuxhshot01", "res://scenes/hookshot_target.tscn"),
    "owl_statue":       ("PackedScene", "uid://btuxowl01",   "res://scenes/owl_statue.tscn"),
    "bomb_pickup":      ("PackedScene", "uid://btuxpkbm01",  "res://scenes/pickup_bomb.tscn"),
    "hookshot_pickup":  ("PackedScene", "uid://btuxpkhs01",  "res://scenes/pickup_hookshot.tscn"),
    "fairy_bottle":     ("PackedScene", "uid://btuxfair01",  "res://scenes/fairy_bottle_pickup.tscn"),
    "glim":             ("PackedScene", "uid://btuxglim01", "res://scenes/glim.tscn"),
    "boss_arena":       ("PackedScene", "uid://btuxbarn01", "res://scenes/boss_arena.tscn"),
    "camera_script":    ("Script",      None,               "res://scripts/free_orbit_camera.gd"),
    "debug_script":     ("Script",      None,               "res://scripts/debug_overlay.gd"),
    "pause_script":     ("Script",      None,               "res://scripts/pause_menu.gd"),
    "root_script":      ("Script",      None,               "res://scripts/dungeon_root.gd"),
    "load_zone_script": ("Script",      None,               "res://scripts/load_zone.gd"),
    "tree_wall_script": ("Script",      None,               "res://scripts/tree_wall.gd"),
    "terrain_mesh_script": ("Script",   None,               "res://scripts/terrain_mesh.gd"),
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
}

ENEMY_TO_EXT = {
    "blob":         "blob",
    "knight":       "knight",
    "bat":          "bat",
    "tomato":       "tomato",
    "spore":        "spore",
    "wisp_hunter":  "wisp_hunter",
    "skull_spider": "skull_spider",
    "wyrdking":     "wyrdking",
}

WALL_THICKNESS = 0.5

# Filesystem path per level id (FILESYSTEM.md §2). Levels not in the
# map fall back to "" — the build script still emits an empty fs_path
# export so dungeon_root.gd has consistent shape.
PATH_MAP = {
    "wyrdkin_glade": "/opt/wyrdmark/glade",
    "wyrdwood":      "/opt/wyrdmark/woods",
    "sourceplain":   "/opt/wyrdmark/plain",
    "hearthold":     "/home/hearthold",
    "brookhold":     "/home/brookhold",
    "sigilkeep":     "/etc/wyrdmark",
    "dungeon_first": "/var/cache/wyrdmark/hollow",
    "stoneroost":    "/mnt/wyrdmark/stoneroost",
    "mirelake":      "/var/spool/mire",
    "burnt_hollow":  "/tmp/burnt",
    # New scaffolded directories — see FILESYSTEM.md §3.
    "crown":             "/",
    "wake":              "/boot",
    "wake_grub":         "/boot/grub",
    "scriptorium":       "/etc",
    "burrows":           "/home",
    "old_hold":          "/home/wyrdkin",
    "docks":             "/mnt",
    "wyrdmark_mounts":   "/mnt/wyrdmark",
    "docks_foreign":     "/mnt/foreign",
    "optional_yard":     "/opt",
    "wyrdmark_gateway":  "/opt/wyrdmark",
    "murk":              "/proc",
    "drift":             "/tmp",
    "sprawl":            "/usr",
    "binds":             "/usr/bin",
    "sharers":           "/usr/share",
    "old_plays":         "/usr/share/games",
    "locals":            "/usr/local",
    "library":           "/var",
    "cache":             "/var/cache",
    "cache_wyrdmark":    "/var/cache/wyrdmark",
    "stacks":            "/var/lib",
    "ledger":            "/var/log",
    "backwater":         "/var/spool",
    "forge":             "/dev",
    "null_door":         "/dev/null",
}


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
        attrs = [
            'transform = %s' % t3(x, 0, z, rot),
            'requires_key = %s' % requires_key,
            'locked_message = "%s"' % locked_msg,
            'unlock_message = "%s"' % unlock_msg,
        ]
        if "key_group" in door:
            attrs.append('key_group = "%s"' % escape(str(door["key_group"])))
        b.add_node(
            '[node name="Door%d" parent="." instance=ExtResource("door")]\n'
            % i + "\n".join(attrs) + "\n"
        )


def _cells_to_gd_array(raw_cells):
    """Emit a Godot Array literal that round-trips a heterogeneous
    cell list into the .tscn — TerrainMesh.gd parses each entry the
    same way at runtime. Cells stay as `[i, j]` arrays in the simple
    case; only y/color overrides force the longer form."""
    parts = []
    for c in raw_cells:
        if isinstance(c, dict):
            kv = []
            if "i" in c:     kv.append('"i": %d' % int(c["i"]))
            if "j" in c:     kv.append('"j": %d' % int(c["j"]))
            if "y" in c:     kv.append('"y": %g' % float(c["y"]))
            if "color" in c and isinstance(c["color"], list):
                col = c["color"]
                kv.append('"color": [%g, %g, %g, %g]'
                          % (col[0], col[1], col[2],
                             col[3] if len(col) >= 4 else 1.0))
            parts.append("{%s}" % ", ".join(kv))
        else:
            elems = []
            for idx, v in enumerate(c):
                if idx < 2:
                    elems.append("%d" % int(v))
                elif idx == 2 and v is not None:
                    elems.append("%g" % float(v))
                elif idx == 3 and isinstance(v, list):
                    elems.append("[%g, %g, %g, %g]"
                                 % (v[0], v[1], v[2],
                                    v[3] if len(v) >= 4 else 1.0))
            parts.append("[%s]" % ", ".join(elems))
    return "[%s]" % ", ".join(parts)


def emit_doors_v2(b, doors):
    """Render `data["doors"]` — doors are first-class level entities,
    placed at world coords with optional `wall_extension` that emits
    flanking solid walls so the door sits inside a contiguous barrier.

    Schema per door:
        {
            "pos":            [x, y, z],
            "rotation_y":     float,
            "type":           "locked" | "unlocked",
            "door_width":     float,    # gap reserved for the door (default 3)
            "wall_extension": float,    # length of flanking wall on each side (default 0)
            "wall_height":    float,    # default 4
            "wall_color":     [r,g,b,a],
            "locked_message": str,
            "unlock_message": str,
        }
    """
    if not doors:
        return
    counter = [0]

    def add_box(prefix, cx, cy, cz, sx, sy, sz, mat, rot_y):
        counter[0] += 1
        n = counter[0]
        shape = b.add_sub("BoxShape3D", [("size", vstr([sx, sy, sz]))])
        mesh  = b.add_sub("BoxMesh",    [("size", vstr([sx, sy, sz]))])
        b.add_node(
            '[node name="%s%d" type="StaticBody3D" parent="."]\n'
            'transform = %s\n'
            'collision_layer = 1\n'
            'collision_mask = 0\n\n'
            '[node name="Shape" type="CollisionShape3D" parent="%s%d"]\n'
            'shape = SubResource("%s")\n\n'
            '[node name="Mesh" type="MeshInstance3D" parent="%s%d"]\n'
            'mesh = SubResource("%s")\n'
            'surface_material_override/0 = SubResource("%s")\n'
            % (prefix, n, t3(cx, cy, cz, rot_y), prefix, n, shape,
               prefix, n, mesh, mat)
        )

    for i, d in enumerate(doors):
        x, y, z = d["pos"]
        rot = float(d.get("rotation_y", 0.0))
        kind = d.get("type", "locked")
        requires_key = "true" if kind == "locked" else "false"
        locked_msg = escape(d.get("locked_message",
                                  "Locked. A small key would open this door."))
        unlock_msg = escape(d.get("unlock_message",
                                  "The lock turns. The door opens."))
        door_width = float(d.get("door_width", 1.6))
        b.ext("door")
        attrs = [
            'transform = %s' % t3(x, y, z, rot),
            'requires_key = %s' % requires_key,
            'door_width = %g' % door_width,
            'locked_message = "%s"' % locked_msg,
            'unlock_message = "%s"' % unlock_msg,
        ]
        if "key_group" in d:
            attrs.append('key_group = "%s"' % escape(str(d["key_group"])))
        b.add_node(
            '[node name="Door%d" parent="." instance=ExtResource("door")]\n'
            % i + "\n".join(attrs) + "\n"
        )

        ext_len = float(d.get("wall_extension", 0.0))
        if ext_len > 0:
            wh = float(d.get("wall_height", 4.0))
            wc = d.get("wall_color", [0.45, 0.45, 0.45, 1.0])
            wt = float(d.get("wall_thickness", 0.2))
            mat = b.color_mat(wc, roughness=0.92)
            # Bleed the wall into the door body by `seam` on each side so
            # there's no sub-pixel gap where the corner meets — both
            # visually and for collision against the player capsule.
            seam = 0.1
            inner = door_width / 2.0 - seam
            seg_len = ext_len + seam
            offset = inner + seg_len / 2.0
            cos_r = math.cos(rot)
            sin_r = math.sin(rot)
            wcy = y + wh / 2.0
            for sign in (-1, 1):
                local_x = sign * offset
                wx = x + cos_r * local_x
                wz = z - sin_r * local_x
                add_box("DoorWall%d_%s" % (i, "L" if sign < 0 else "R"),
                        wx, wcy, wz, seg_len, wh, wt, mat, rot)


def emit_grid_floors(b, grid, load_zones=None, doors=None):
    """Render the editor's cell-paint grid format. For each floor in
    grid.floors, emit per-cell floor slabs and a wall segment along
    every cell-edge that has no neighbor cell. Wall segments are
    suppressed where they overlap a load_zone footprint, so the player
    can walk through doorways without manual openings."""
    if not grid:
        return
    cell_size = float(grid.get("cell_size", 2.0))
    floors = grid.get("floors", [])
    if not floors:
        return
    load_zones = load_zones or []
    doors = doors or []

    def in_load_zone(wx, wz):
        for lz in load_zones:
            pos = lz.get("pos", [0, 0, 0])
            sz  = lz.get("size", [3, 3, 1])
            if (abs(wx - pos[0]) < sz[0] / 2.0 + 0.1
                and abs(wz - pos[2]) < sz[2] / 2.0 + 0.1):
                return True
        # Doors carry their own flanking walls via wall_extension; if
        # they're embedded inside a grid floor's perimeter, suppress
        # the auto-wall at the door footprint so the player can pass.
        for d in doors:
            dx, _dy, dz = d["pos"]
            dw = float(d.get("door_width", 2.0))
            if abs(wx - dx) < dw / 2.0 + 0.1 and abs(wz - dz) < dw / 2.0 + 0.1:
                return True
        return False

    counter = [0]

    def add_box_static(prefix, cx, cy, cz, sx, sy, sz, mat):
        counter[0] += 1
        n = counter[0]
        shape = b.add_sub("BoxShape3D", [("size", vstr([sx, sy, sz]))])
        mesh  = b.add_sub("BoxMesh",    [("size", vstr([sx, sy, sz]))])
        b.add_node(
            '[node name="%s%d" type="StaticBody3D" parent="."]\n'
            'transform = %s\n'
            'collision_layer = 1\n'
            'collision_mask = 0\n\n'
            '[node name="Shape" type="CollisionShape3D" parent="%s%d"]\n'
            'shape = SubResource("%s")\n\n'
            '[node name="Mesh" type="MeshInstance3D" parent="%s%d"]\n'
            'mesh = SubResource("%s")\n'
            'surface_material_override/0 = SubResource("%s")\n'
            % (prefix, n, t3(cx, cy, cz), prefix, n, shape,
               prefix, n, mesh, mat)
        )

    for floor in floors:
        raw_cells = floor.get("cells", [])
        # Each cell entry is one of:
        #   [i, j]                       — flat default cell
        #   [i, j, y_offset]             — raised/lowered cell
        #   [i, j, y_offset, [r,g,b,a]]  — also recolored (path tint)
        #   {"i": i, "j": j, "y": ..., "color": [...]}  — object form
        cells = set()
        cell_y_off  = {}
        cell_col    = {}
        for c in raw_cells:
            if isinstance(c, dict):
                ci, cj = int(c["i"]), int(c["j"])
                if "y" in c:     cell_y_off[(ci, cj)] = float(c["y"])
                if "color" in c: cell_col[(ci, cj)]   = c["color"]
            else:
                ci, cj = int(c[0]), int(c[1])
                if len(c) >= 3 and c[2] is not None:
                    cell_y_off[(ci, cj)] = float(c[2])
                if len(c) >= 4 and c[3] is not None:
                    cell_col[(ci, cj)] = c[3]
            cells.add((ci, cj))
        if not cells:
            continue
        y           = float(floor.get("y", 0.0))
        wall_h      = float(floor.get("wall_height", 4.0))
        floor_color = floor.get("floor_color", [0.30, 0.50, 0.30, 1.0])
        wall_color  = floor.get("wall_color",  [0.45, 0.45, 0.45, 1.0])
        wall_material = floor.get("wall_material", "stone")
        has_floor   = bool(floor.get("has_floor", True))
        has_walls   = bool(floor.get("has_walls", True))
        has_roof    = bool(floor.get("has_roof", False))
        floor_mat   = b.color_mat(floor_color, roughness=0.95)
        wall_mat    = b.color_mat(wall_color,  roughness=0.92)

        def cell_world_y(ci, cj):
            return y + cell_y_off.get((ci, cj), 0.0)

        if has_floor:
            # Emit a single TerrainMesh node that builds a smoothed,
            # marching-squares-ish surface from the cell data at scene
            # ready time. This replaces the old grid of per-cell box
            # slabs — neighbours' corners share heights so per-cell y
            # offsets blend into hills, and boundary corners get inset
            # so a single missing cell becomes a diamond hole instead
            # of a hard square.
            counter[0] += 1
            n = counter[0]
            b.ext("terrain_mesh_script")
            cell_data_str = _cells_to_gd_array(raw_cells)
            fc = floor_color
            fc_str = "Color(%g, %g, %g, %g)" % (fc[0], fc[1], fc[2],
                                                 fc[3] if len(fc) >= 4 else 1.0)
            b.add_node(
                '[node name="TerrainMesh%d" type="Node3D" parent="."]\n'
                'script = ExtResource("terrain_mesh_script")\n'
                'cell_data = %s\n'
                'cell_size = %g\n'
                'floor_y = %g\n'
                'floor_color = %s\n'
                'skirt_depth = 6.0\n'
                'smoothing = 0.45\n'
                % (n, cell_data_str, cell_size, y, fc_str)
            )

        if has_walls:
            wall_thick = 0.2
            tree_seed = [42]
            if wall_material == "tree":
                b.ext("tree_wall_script")

            def emit_edge(p0, p1, mid_x, mid_z, sx, sz, ci, cj):
                """Emit either a tree_wall.gd polyline along (p0,p1) or a
                box wall at (mid_x, mid_z). p0/p1 in world XZ."""
                cy = cell_world_y(ci, cj)
                wcy_local = cy + wall_h / 2.0
                if wall_material == "tree":
                    tree_seed[0] += 1
                    counter[0] += 1
                    n = counter[0]
                    b.add_node(
                        '[node name="GridTree%d" type="Node3D" parent="."]\n'
                        'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 0)\n'
                        'script = ExtResource("tree_wall_script")\n'
                        'boundary_points = PackedVector2Array(%g, %g, %g, %g)\n'
                        'closed = false\n'
                        'wall_height = %g\n'
                        'spacing = 1.4\n'
                        'seed = %d\n'
                        % (n, cy, p0[0], p0[1], p1[0], p1[1], wall_h, tree_seed[0])
                    )
                else:
                    add_box_static("GridWall", mid_x, wcy_local, mid_z,
                                   sx, wall_h, sz, wall_mat)

            for (i, j) in cells:
                x_left  = i * cell_size
                x_right = (i + 1) * cell_size
                z_north = j * cell_size
                z_south = (j + 1) * cell_size
                cx_mid  = (x_left + x_right) / 2.0
                cz_mid  = (z_north + z_south) / 2.0
                if (i + 1, j) not in cells and not in_load_zone(x_right, cz_mid):
                    emit_edge((x_right, z_north), (x_right, z_south),
                              x_right, cz_mid, wall_thick, cell_size, i, j)
                if (i - 1, j) not in cells and not in_load_zone(x_left, cz_mid):
                    emit_edge((x_left, z_south), (x_left, z_north),
                              x_left, cz_mid, wall_thick, cell_size, i, j)
                if (i, j + 1) not in cells and not in_load_zone(cx_mid, z_south):
                    emit_edge((x_left, z_south), (x_right, z_south),
                              cx_mid, z_south, cell_size, wall_thick, i, j)
                if (i, j - 1) not in cells and not in_load_zone(cx_mid, z_north):
                    emit_edge((x_right, z_north), (x_left, z_north),
                              cx_mid, z_north, cell_size, wall_thick, i, j)

        if has_roof:
            roof_thick = 0.2
            for (i, j) in cells:
                cx = (i + 0.5) * cell_size
                cz = (j + 0.5) * cell_size
                cy = cell_world_y(i, j)
                add_box_static("GridRoof",
                               cx, cy + wall_h + roof_thick / 2.0, cz,
                               cell_size, roof_thick, cell_size, wall_mat)


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
            # `item` lets us drop an arbitrary unlockable through a
            # generic item pickup. The build script doesn't ship a
            # generic item scene yet, so for now `item` falls through
            # to whatever ext is configured for the named item.
            if contents_key == "item":
                ext_name = CONTENTS_TO_EXT.get(
                    p.get("item_name", ""), "boomerang_pickup")
            else:
                ext_name = CONTENTS_TO_EXT.get(contents_key, "")
            msg = escape(p.get("open_message", ""))
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if ext_name:
                b.ext(ext_name)
                attrs.append('contents_scene = ExtResource("%s")' % ext_name)
            if msg:
                attrs.append('open_message = "%s"' % msg)
            if "amount" in p:
                attrs.append('contents_amount = %d' % int(p["amount"]))
            if p.get("item_name"):
                attrs.append('contents_item_name = "%s"' % escape(str(p["item_name"])))
            # When a chest dispenses a small key, allow the JSON to
            # tag the spawned key with a different dungeon's group.
            if "key_group" in p:
                attrs.append('contents_key_group = "%s"' % escape(str(p["key_group"])))
            b.add_node(
                '[node name="Chest%d" parent="." instance=ExtResource("chest")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "bush":
            b.ext("bush")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "drop_chance" in p:
                attrs.append('drop_chance = %g' % float(p["drop_chance"]))
            if "pebble_amount" in p:
                attrs.append('pebble_amount = %d' % int(p["pebble_amount"]))
            b.add_node(
                '[node name="Bush%d" parent="." instance=ExtResource("bush")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "rock":
            b.ext("rock")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "pebble_chance" in p:
                attrs.append('pebble_chance = %g' % float(p["pebble_chance"]))
            b.add_node(
                '[node name="Rock%d" parent="." instance=ExtResource("rock")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "tree":
            b.ext("tree")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "pebble_chance" in p:
                attrs.append('pebble_chance = %g' % float(p["pebble_chance"]))
            if "trunk_height" in p:
                attrs.append('trunk_height = %g' % float(p["trunk_height"]))
            if "canopy_radius" in p:
                attrs.append('canopy_radius = %g' % float(p["canopy_radius"]))
            b.add_node(
                '[node name="Tree%d" parent="." instance=ExtResource("tree")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "npc":
            b.ext("npc")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            name = p.get("name", "")
            if name:
                attrs.append('npc_name = "%s"' % escape(str(name)))
            if "body_color" in p:
                attrs.append('body_color = %s' % cstr(p["body_color"]))
            if "hat_color" in p:
                attrs.append('hat_color = %s' % cstr(p["hat_color"]))
            if "idle_hint" in p:
                attrs.append('idle_hint = "%s"' % escape(str(p["idle_hint"])))
            # Tree comes through as a Godot dict literal — emit the JSON
            # text on the node and let npc.gd JSON-parse at scene-ready,
            # which is dramatically simpler than translating Python dicts
            # into GDScript syntax in raw text.
            tree = p.get("dialog_tree")
            if tree:
                tree_json = json.dumps(tree, ensure_ascii=False)
                attrs.append('dialog_tree_json = "%s"' % escape(tree_json))
            node_name = "Npc%d" % i
            if name:
                # Sanitise to a node-safe id but keep it readable.
                safe = "".join(ch if ch.isalnum() else "_" for ch in str(name))
                node_name = "Npc%d_%s" % (i, safe)
            b.add_node(
                '[node name="%s" parent="." instance=ExtResource("npc")]\n'
                % node_name + "\n".join(attrs) + "\n"
            )
        elif kind == "boss_arena":
            # Boss arena instance. The boss enemy is referenced by id
            # (e.g. "tomato"); we look up the matching ENEMY_TO_EXT
            # entry, ensure both ext_resources are loaded, and let the
            # arena script PackedScene-instantiate the boss at runtime.
            b.ext("boss_arena")
            boss_id = p.get("boss_scene_id", "")
            boss_ext = ENEMY_TO_EXT.get(boss_id)
            if not boss_ext:
                # Unknown boss — emit the arena anyway so the level still
                # converts; the runtime will warn and skip.
                print("WARN: boss_arena[%d] has unknown boss_scene_id '%s'" %
                      (i, boss_id))
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "boss_name" in p:
                attrs.append('boss_name = "%s"' % escape(str(p["boss_name"])))
            if boss_ext:
                b.ext(boss_ext)
                attrs.append('boss_scene = ExtResource("%s")' % boss_ext)
            if "arena_radius" in p:
                attrs.append('arena_radius = %g' % float(p["arena_radius"]))
            if "spawn_offset" in p:
                so = p["spawn_offset"]
                attrs.append('spawn_offset = %s' % vstr(so))
            if "region_track" in p:
                attrs.append('region_track = "%s"' % escape(str(p["region_track"])))
            b.add_node(
                '[node name="BossArena%d" parent="." instance=ExtResource("boss_arena")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "crystal_switch":
            b.ext("crystal_switch")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "target_id" in p:
                attrs.append('target_id = "%s"' % escape(str(p["target_id"])))
            if "stays_on" in p:
                attrs.append('stays_on = %s' % ("true" if p["stays_on"] else "false"))
            b.add_node(
                '[node name="CrystalSwitch%d" parent="." instance=ExtResource("crystal_switch")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "pressure_plate":
            b.ext("pressure_plate")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "target_id" in p:
                attrs.append('target_id = "%s"' % escape(str(p["target_id"])))
            if "holds" in p:
                attrs.append('holds = %s' % ("true" if p["holds"] else "false"))
            b.add_node(
                '[node name="PressurePlate%d" parent="." instance=ExtResource("pressure_plate")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "movable_block":
            b.ext("movable_block")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "cell_size" in p:
                attrs.append('cell_size = %g' % float(p["cell_size"]))
            b.add_node(
                '[node name="MovableBlock%d" parent="." instance=ExtResource("movable_block")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "torch":
            b.ext("torch")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "target_id" in p:
                attrs.append('target_id = "%s"' % escape(str(p["target_id"])))
            if "lit_on_spawn" in p:
                attrs.append('lit_on_spawn = %s' % ("true" if p["lit_on_spawn"] else "false"))
            b.add_node(
                '[node name="Torch%d" parent="." instance=ExtResource("torch")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "eye_target":
            b.ext("eye_target")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "target_id" in p:
                attrs.append('target_id = "%s"' % escape(str(p["target_id"])))
            b.add_node(
                '[node name="EyeTarget%d" parent="." instance=ExtResource("eye_target")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "triggered_gate":
            b.ext("triggered_gate")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "listen_id" in p:
                attrs.append('listen_id = "%s"' % escape(str(p["listen_id"])))
            if "open_offset" in p:
                attrs.append('open_offset = %s' % vstr(p["open_offset"]))
            if "open_duration" in p:
                attrs.append('open_duration = %g' % float(p["open_duration"]))
            b.add_node(
                '[node name="TriggeredGate%d" parent="." instance=ExtResource("triggered_gate")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "bomb_flower":
            b.ext("bomb_flower")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            b.add_node(
                '[node name="BombFlower%d" parent="." instance=ExtResource("bomb_flower")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "destructible_wall":
            b.ext("destructible_wall")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            b.add_node(
                '[node name="DestructibleWall%d" parent="." instance=ExtResource("destructible_wall")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "hookshot_target":
            b.ext("hookshot_target")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            b.add_node(
                '[node name="HookshotTarget%d" parent="." instance=ExtResource("hookshot_target")]\n'
                % i + "\n".join(attrs) + "\n"
            )
        elif kind == "owl_statue":
            b.ext("owl_statue")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "warp_id" in p:
                attrs.append('warp_id = "%s"' % escape(str(p["warp_id"])))
            if "warp_name" in p:
                attrs.append('warp_name = "%s"' % escape(str(p["warp_name"])))
            if "warp_target_scene" in p:
                attrs.append('warp_target_scene = "%s"'
                             % escape(str(p["warp_target_scene"])))
            if "warp_target_spawn" in p:
                attrs.append('warp_target_spawn = "%s"'
                             % escape(str(p["warp_target_spawn"])))
            # Sanitise the warp id into a node-safe suffix so two owls
            # in the same scene don't clash on default name "OwlStatue%d".
            wid_safe = "".join(ch if ch.isalnum() else "_"
                               for ch in str(p.get("warp_id", str(i))))
            b.add_node(
                '[node name="OwlStatue_%s" parent="." instance=ExtResource("owl_statue")]\n'
                % wid_safe + "\n".join(attrs) + "\n"
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
    # Root node first (must precede everything). The dungeon-wide
    # key_group field rides on the root so dungeon_root.gd can read it
    # at _ready and tell GameState which key bucket to use.
    key_group    = data.get("key_group",    data["id"])
    music_track  = data.get("music_track",  data["id"])
    display_name = data.get("name",         data["id"])
    fs_path      = data.get("fs_path",      PATH_MAP.get(data["id"], ""))
    root_attrs = [
        'script = ExtResource("root_script")',
        'key_group = "%s"'    % escape(str(key_group)),
        'music_track = "%s"'  % escape(str(music_track)),
        'display_name = "%s"' % escape(str(display_name)),
        'fs_path = "%s"'      % escape(str(fs_path)),
    ]
    b.nodes.append('[node name="%s" type="Node3D"]\n%s\n'
                   % (data.get("name", data["id"]), "\n".join(root_attrs)))
    emit_environment(b, data.get("environment", {}))
    emit_floor(b, data.get("floor"))
    emit_walls(b, data.get("rooms", []), data.get("doorways", []))
    emit_doors(b, data.get("doorways", []))
    emit_tree_walls(b, data.get("tree_walls", []))
    emit_grid_floors(b, data.get("grid"), data.get("load_zones", []),
                     data.get("doors", []))
    emit_doors_v2(b, data.get("doors", []))
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
