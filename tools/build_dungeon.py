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
    "process_ghost":    ("PackedScene", "uid://btuxprgh01", "res://scenes/enemy_process_ghost.tscn"),
    "chmod_zealot":     ("PackedScene", "uid://btuxchmd01", "res://scenes/enemy_chmod_zealot.tscn"),
    "fork_hydra":       ("PackedScene", "uid://btuxfork01", "res://scenes/enemy_fork_hydra.tscn"),
    "init_shade":       ("PackedScene", "uid://btuxinit01", "res://scenes/enemy_init_shade.tscn"),
    "codex_knight":     ("PackedScene", "uid://btuxbosscdx01", "res://scenes/enemy_codex_knight.tscn"),
    "gale_roost":       ("PackedScene", "uid://btuxbossglr01", "res://scenes/enemy_gale_roost.tscn"),
    "cinder_tomato":    ("PackedScene", "uid://btuxbosscnt01", "res://scenes/enemy_cinder_tomato.tscn"),
    "forge_wyrm":       ("PackedScene", "uid://btuxbossfwm01", "res://scenes/enemy_forge_wyrm.tscn"),
    "backwater_maw":    ("PackedScene", "uid://btuxbossbwm01", "res://scenes/enemy_backwater_maw.tscn"),
    "censor":           ("PackedScene", "uid://btuxbosscns01", "res://scenes/enemy_censor.tscn"),
    "init":             ("PackedScene", "uid://btuxbossini01", "res://scenes/enemy_init.tscn"),
    # Mini-bosses (between regular enemies and the dungeon's final boss).
    # Tougher than a tomato or knight, but no boss_arena requirement.
    "armored_knight":   ("PackedScene", "uid://btuxmbarmkt01", "res://scenes/enemy_armored_knight.tscn"),
    "wyrm_hatchling":   ("PackedScene", "uid://btuxmbwymh01", "res://scenes/enemy_wyrm_hatchling.tscn"),
    "shade_archon":     ("PackedScene", "uid://btuxmbshrc01", "res://scenes/enemy_shade_archon.tscn"),
    "bone_ogre":        ("PackedScene", "uid://btuxmbbnog01", "res://scenes/enemy_bone_ogre.tscn"),
    # Unix-flavored quirk enemies (DESIGN.md follow-up). Each picks one
    # tongue-in-cheek shell behaviour and turns it into a combat verb;
    # placement is a separate pass so these aren't yet referenced from
    # any dungeon JSON.
    "rm_phantom":     ("PackedScene", "uid://btuxrmph01", "res://scenes/enemy_rm_phantom.tscn"),
    "cp_doppel":      ("PackedScene", "uid://btuxcpdp01", "res://scenes/enemy_cp_doppel.tscn"),
    "kill_signal":    ("PackedScene", "uid://btuxklsg01", "res://scenes/enemy_kill_signal.tscn"),
    "cron_daemon":    ("PackedScene", "uid://btuxcrnd01", "res://scenes/enemy_cron_daemon.tscn"),
    "zombie_proc":    ("PackedScene", "uid://btuxzbpr01", "res://scenes/enemy_zombie_proc.tscn"),
    "null_pointer":   ("PackedScene", "uid://btuxnlpt01", "res://scenes/enemy_null_pointer.tscn"),
    "race_condition": ("PackedScene", "uid://btuxrccd01", "res://scenes/enemy_race_condition.tscn"),
    "deadlock_pair":  ("PackedScene", "uid://btuxdlpr01", "res://scenes/enemy_deadlock_pair.tscn"),
    "find_hawk":      ("PackedScene", "uid://btuxfdhk01", "res://scenes/enemy_find_hawk.tscn"),
    "cache_wraith":   ("PackedScene", "uid://btuxcwrh01", "res://scenes/enemy_cache_wraith.tscn"),
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
    "time_gate":        ("PackedScene", "uid://btuxtgte02", "res://scenes/time_gate.tscn"),
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
    "heart_piece":      ("PackedScene", "uid://btuxhpie01",  "res://scenes/heart_piece.tscn"),
    "heart_container":  ("PackedScene", "uid://btuxhcnt01",  "res://scenes/heart_container.tscn"),
    "glim":             ("PackedScene", "uid://btuxglim01", "res://scenes/glim.tscn"),
    # Dungeon 5–8 item pickups (DESIGN.md §3). All four use the generic
    # pickup.gd dispatch (Kind.ITEM + item_name); each pickup scene just
    # binds the right item_name + visual mesh.
    "hammer_pickup":       ("PackedScene", "uid://btuxpkhmr01", "res://scenes/pickup_hammer.tscn"),
    "anchor_boots_pickup": ("PackedScene", "uid://btuxpkanc01", "res://scenes/pickup_anchor_boots.tscn"),
    "glim_sight_pickup":   ("PackedScene", "uid://btuxpkgsi01", "res://scenes/pickup_glim_sight.tscn"),
    "glim_mirror_pickup":  ("PackedScene", "uid://btuxpkgmr01", "res://scenes/pickup_glim_mirror.tscn"),
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
    "heart_piece":     "heart_piece",
    "heart_container": "heart_container",
    # Dungeon 5–8 items (DESIGN.md §3).
    "hammer":       "hammer_pickup",
    "anchor_boots": "anchor_boots_pickup",
    "glim_sight":   "glim_sight_pickup",
    "glim_mirror":  "glim_mirror_pickup",
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
    "process_ghost": "process_ghost",
    "chmod_zealot":  "chmod_zealot",
    "fork_hydra":    "fork_hydra",
    "init_shade":    "init_shade",
    "codex_knight":  "codex_knight",
    "gale_roost":    "gale_roost",
    "cinder_tomato": "cinder_tomato",
    "forge_wyrm":    "forge_wyrm",
    "backwater_maw": "backwater_maw",
    "censor":        "censor",
    "init":          "init",
    # Mini-bosses.
    "armored_knight": "armored_knight",
    "wyrm_hatchling": "wyrm_hatchling",
    "shade_archon":   "shade_archon",
    "bone_ogre":      "bone_ogre",
    # Unix-flavored quirk enemies — see EXT_RESOURCES block above.
    "rm_phantom":     "rm_phantom",
    "cp_doppel":      "cp_doppel",
    "kill_signal":    "kill_signal",
    "cron_daemon":    "cron_daemon",
    "zombie_proc":    "zombie_proc",
    "null_pointer":   "null_pointer",
    "race_condition": "race_condition",
    "deadlock_pair":  "deadlock_pair",
    "find_hawk":      "find_hawk",
    "cache_wraith":   "cache_wraith",
}

WALL_THICKNESS = 0.5

# Minimum gap width (meters of opening at the boundary) carved through
# the tree wall for every load_zone. Even a small load_zone gets at
# least this much clearance so the player can walk through without
# clipping branches. Translated into an arc-width (radians) per
# tree_wall when emitting the gap.
LOAD_ZONE_MIN_GAP_M = 4.0

# How many cells of "cleared dirt path" to lay leading INWARD from
# each load_zone toward the level centroid. The path is a visible
# cue that "this is the way out" — tuned to 3 so the trail is
# visible from a few meters away without dominating the level art.
LOAD_ZONE_PATH_CELLS = 3

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
    # v2 expansion — see FILESYSTEM.md §2.1.
    # Top-level (7).
    "bin":               "/bin",
    "sbin":              "/sbin",
    "lib":               "/lib",
    "lost_found":        "/lost+found",
    "root_hold":         "/root",
    "srv":               "/srv",
    "sys":               "/sys",
    # Under /etc (2).
    "etc_initd":         "/etc/init.d",
    "etc_passwd":        "/etc/passwd",
    # Under /home (2).
    "home_lirien":       "/home/lirien",
    "home_khorgaul":     "/home/khorgaul",
    # Under /proc (3).
    "proc_init":         "/proc/init",
    "proc_sys":          "/proc/sys",
    "proc_42":           "/proc/42",
    # Under /usr (5 — including usr_share_man).
    "usr_lib":           "/usr/lib",
    "usr_sbin":          "/usr/sbin",
    "usr_src":           "/usr/src",
    "usr_include":       "/usr/include",
    "usr_share_man":     "/usr/share/man",
    # Under /var (4).
    "var_mail":          "/var/mail",
    "var_run":           "/var/run",
    "var_tmp":           "/var/tmp",
    "var_games":         "/var/games",
    # Under /dev (4).
    "dev_zero":          "/dev/zero",
    "dev_random":        "/dev/random",
    "dev_tty":           "/dev/tty",
    "dev_loop":          "/dev/loop",
    # Canonical Unix sub-dirs the player will instantly recognise (10).
    # Hearthold (/home/hearthold) children.
    "hearthold_desktop":   "/home/hearthold/Desktop",
    "hearthold_downloads": "/home/hearthold/Downloads",
    # Old Hold (/home/wyrdkin) children — dotfiles + cache + history.
    "wyrdkin_config":        "/home/wyrdkin/.config",
    "wyrdkin_cache":         "/home/wyrdkin/.cache",
    "wyrdkin_bash_history":  "/home/wyrdkin/.bash_history",
    # Scriptorium (/etc) children — classic /etc tablets.
    "etc_hosts": "/etc/hosts",
    "etc_motd":  "/etc/motd",
    "etc_fstab": "/etc/fstab",
    # Ledger (/var/log) — running syslog.
    "var_log_syslog": "/var/log/syslog",
    # Drift (/tmp) — the X11 socket directory.
    "tmp_x11_unix": "/tmp/.X11-unix",
    # Canonical XDG user dirs across all five home villages (18).
    # Hearthold already has Desktop+Downloads; add Documents+Music.
    "hearthold_documents": "/home/hearthold/Documents",
    "hearthold_music":     "/home/hearthold/Music",
    # Brookhold — all four.
    "brookhold_desktop":   "/home/brookhold/Desktop",
    "brookhold_documents": "/home/brookhold/Documents",
    "brookhold_music":     "/home/brookhold/Music",
    "brookhold_downloads": "/home/brookhold/Downloads",
    # Wyrdkin (Tux's grandparents' Old Hold) — all four.
    "wyrdkin_desktop":     "/home/wyrdkin/Desktop",
    "wyrdkin_documents":   "/home/wyrdkin/Documents",
    "wyrdkin_music":       "/home/wyrdkin/Music",
    "wyrdkin_downloads":   "/home/wyrdkin/Downloads",
    # Lirien — all four.
    "lirien_desktop":      "/home/lirien/Desktop",
    "lirien_documents":    "/home/lirien/Documents",
    "lirien_music":        "/home/lirien/Music",
    "lirien_downloads":    "/home/lirien/Downloads",
    # Khorgaul — all four.
    "khorgaul_desktop":    "/home/khorgaul/Desktop",
    "khorgaul_documents":  "/home/khorgaul/Documents",
    "khorgaul_music":      "/home/khorgaul/Music",
    "khorgaul_downloads":  "/home/khorgaul/Downloads",
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


# ---- ground-y bake -----------------------------------------------------
#
# Each prop kind needs to sit at a specific height above the cell floor.
# These offsets are baked into `transform.origin.y` at build time so the
# runtime ground_snap.gd raycast is only a safety net, not the primary
# fix. Values are the height (m) at which the prop's ORIGIN should sit
# above the cell's world-y. 0.0 means "origin coincides with the floor
# surface" (most static props have their mesh origin at the trunk/base).
_PROP_Y_OFFSETS = {
    "tree":              0.0,
    "rock":              0.0,
    "bush":              0.0,
    "sign":              0.0,
    "npc":               0.0,
    "chest":             0.0,
    "owl_statue":        0.0,
    "bomb_flower":       0.0,
    "door":              0.0,
    "triggered_gate":    0.0,
    "time_gate":         0.0,
    "crystal_switch":    0.0,
    "pressure_plate":    0.0,
    "eye_target":        0.0,
    "movable_block":     0.0,
    "boss_arena":        0.0,
    "torch":             0.0,
    "destructible_wall": 0.0,
    "hookshot_target":   0.0,
    # Pickups float slightly above the floor so they're visible against
    # textured ground. Not currently emitted as standalone props (chests
    # spawn them at runtime), but kept here for forward compatibility
    # and in case a future scatter pass drops them directly.
    "heart_pickup":      0.3,
    "key_pickup":        0.3,
    "pebble_pickup":     0.3,
    "boomerang_pickup":  0.3,
    "arrow_pickup":      0.3,
    "seed_pickup":       0.3,
    "bow_pickup":        0.3,
    "slingshot_pickup":  0.3,
    "bomb_pickup":       0.3,
    "hookshot_pickup":   0.3,
    "fairy_bottle":      0.3,
    "heart_piece":       0.3,
    "heart_container":   0.3,
    "hammer_pickup":     0.3,
    "anchor_boots_pickup": 0.3,
    "glim_sight_pickup": 0.3,
    "glim_mirror_pickup": 0.3,
}

# Spawn markers sit at the player capsule's midpoint above the floor.
_SPAWN_Y_OFFSET = 0.5

# Load-zone triggers sit at chest-height above the floor so the trigger
# box is centred on the player's body, not buried at ankle level.
_LOAD_ZONE_Y_OFFSET = 1.4

# When a JSON-authored y exceeds the cell's ground+offset by more than
# this threshold, we treat it as INTENTIONALLY raised (e.g. a platform,
# a chest perched on a stone). Keep the authored y in that case.
# Threshold for treating an authored y as an "intentional platform"
# rather than a default-zero placeholder. With v10 terrain hills hitting
# +4m / -4m, a tree authored at y=0 sitting above a -3m cell looks
# "raised" by 3m even though it's just a scaffolder default. Bumped
# from 1.0 to 5.0 (above the worst-case hill amplitude of ±3.7m) so
# only genuinely-intentional raises (e.g. spawn_offset chests, platform-
# stacked props) are preserved.
_INTENTIONAL_RAISE_THRESHOLD = 5.0


# Per-grid memoised cell→world-y maps. Keyed by `id(grid)` so a
# single conversion run reuses one dict across spawns/props/load_zones;
# emptied implicitly when the JSON dict is GCed between levels.
_CELL_Y_CACHE = {}


def _build_cell_y_table(grid):
    """Build {(ci, cj): world_y} for every walking cell on every floor
    in `grid`. Lower floors win on collision so props on the bottom
    floor sit on the ground; in practice multi-floor outdoor maps don't
    exist yet, so the iteration order is mostly cosmetic."""
    table = {}
    for floor in grid.get("floors", []) or []:
        base_y = float(floor.get("y", 0.0))
        for c in floor.get("cells", []) or []:
            if isinstance(c, dict):
                ci, cj = int(c["i"]), int(c["j"])
                cy = float(c["y"]) if "y" in c else 0.0
            else:
                ci, cj = int(c[0]), int(c[1])
                cy = float(c[2]) if len(c) >= 3 and c[2] is not None else 0.0
            key = (ci, cj)
            # First write wins (bottom floor). If we ever stack floors
            # the lower one is what props sit on, which is what we want.
            if key not in table:
                table[key] = base_y + cy
    return table


def cell_y_lookup(grid, world_x, world_z):
    """Return the world-y of the walking cell under (world_x, world_z),
    or None if no grid is configured or the (x, z) isn't on a walking
    cell. The y is the floor's base y plus the per-cell y_offset.

    Used by emit_spawns / emit_props / emit_load_zones to bake the
    correct ground height into every emitted transform — replacing
    runtime ground_snap.gd as the primary fix for "trees float / rocks
    fall" reports."""
    if not grid:
        return None
    cell_size = float(grid.get("cell_size", 2.0))
    key = id(grid)
    table = _CELL_Y_CACHE.get(key)
    if table is None:
        table = _build_cell_y_table(grid)
        _CELL_Y_CACHE[key] = table
    if not table:
        return None
    ci = int(math.floor(world_x / cell_size))
    cj = int(math.floor(world_z / cell_size))
    return table.get((ci, cj))


def resolve_ground_y(grid, kind, pos):
    """Compute the y at which a prop of `kind` at world (x, _, z) should
    sit, replacing the JSON-authored y with `cell_y + per_prop_offset`.

    Preserves the JSON y when it's been deliberately raised above the
    ground (e.g. a chest on top of a platform). Detection is conservative:
    if `json_y - cell_y > 1.0 m`, we treat it as intentional and leave
    the authored y untouched.

    Returns (y, source) where source is "baked" if we replaced the y,
    "authored" if we kept it, or "passthrough" if no grid lookup was
    available."""
    x, json_y, z = float(pos[0]), float(pos[1]), float(pos[2])
    cy = cell_y_lookup(grid, x, z)
    if cy is None:
        return json_y, "passthrough"
    offset = _PROP_Y_OFFSETS.get(kind, 0.0)
    target = cy + offset
    if json_y - cy > _INTENTIONAL_RAISE_THRESHOLD:
        # Deliberately raised — e.g. a chest perched on a stone, a sign
        # mounted on a platform. Keep the authored y so we don't yank
        # the prop down into the floor.
        return json_y, "authored"
    return target, "baked"


def _grid_floor_centroid(floor, cell_size):
    """World-XZ centroid of a grid floor's walking cells, weighted by
    cell count. Used as the reference point for "outward direction"
    when carving load_zone gaps."""
    raw_cells = floor.get("cells", [])
    if not raw_cells:
        return (0.0, 0.0)
    sx = 0.0; sz = 0.0; n = 0
    for c in raw_cells:
        if isinstance(c, dict):
            ci, cj = int(c["i"]), int(c["j"])
        else:
            ci, cj = int(c[0]), int(c[1])
        sx += (ci + 0.5) * cell_size
        sz += (cj + 0.5) * cell_size
        n += 1
    return (sx / n, sz / n)


def _grid_floor_bbox(floor, cell_size):
    """World-XZ bbox (x_min, z_min, x_max, z_max) of a grid floor's
    walking cells. Edge of the level for snapping load_zones."""
    raw_cells = floor.get("cells", [])
    if not raw_cells:
        return (0.0, 0.0, 0.0, 0.0)
    i_lo = i_hi = None
    j_lo = j_hi = None
    for c in raw_cells:
        if isinstance(c, dict):
            ci, cj = int(c["i"]), int(c["j"])
        else:
            ci, cj = int(c[0]), int(c[1])
        if i_lo is None or ci < i_lo: i_lo = ci
        if i_hi is None or ci > i_hi: i_hi = ci
        if j_lo is None or cj < j_lo: j_lo = cj
        if j_hi is None or cj > j_hi: j_hi = cj
    return (i_lo * cell_size, j_lo * cell_size,
            (i_hi + 1) * cell_size, (j_hi + 1) * cell_size)


def _preprocess_load_zones(data):
    """Mutate `data["load_zones"]` so each zone is snapped to the
    outward edge of the level, and emit per-floor path_cells (cleared
    corridor leading from the zone back toward the centroid).

    Returns a dict floor_index -> list of (i, j) cells to add as
    path_cells on that floor's TerrainMesh, plus a per-zone "expanded
    footprint" used by the grid wall-suppression pass so the gap in
    the tree wall is wide enough for the player to walk through (not
    just the trigger box's literal width).

    Skips zones that point at "grotto_*" scenes and have auto:false
    — those are interior cellar entrances, NOT boundary portals, and
    pulling them to the level edge would teleport them across the
    map. We can detect this from the JSON shape: an `auto:false` zone
    is always a "press E to enter" cellar trapdoor, not an outdoor
    transition.
    """
    out = {"footprints": [], "path_cells_per_floor": {}}
    grid = data.get("grid")
    load_zones = data.get("load_zones", [])
    if not grid or not load_zones:
        # Even with no grid we still want to expose the footprints so
        # the wall-suppression pass has uniform shape.
        for lz in load_zones:
            pos = lz.get("pos", [0, 0, 0])
            sz  = lz.get("size", [3, 3, 1])
            out["footprints"].append({
                "pos":  pos,
                "halfx": sz[0] / 2.0 + 0.1,
                "halfz": sz[2] / 2.0 + 0.1,
            })
        return out

    cell_size = float(grid.get("cell_size", 2.0))
    floors = grid.get("floors", [])
    if not floors:
        for lz in load_zones:
            pos = lz.get("pos", [0, 0, 0])
            sz  = lz.get("size", [3, 3, 1])
            out["footprints"].append({
                "pos":  pos,
                "halfx": sz[0] / 2.0 + 0.1,
                "halfz": sz[2] / 2.0 + 0.1,
            })
        return out

    # Use the first (only) floor for centroid + bbox. Multi-floor
    # outdoor maps don't exist in the current dungeon set; if they
    # ever do, an explicit per-zone "floor_index" override would be
    # easy to add.
    floor_idx = 0
    floor = floors[floor_idx]
    cells_set = set()
    for c in floor.get("cells", []):
        if isinstance(c, dict):
            cells_set.add((int(c["i"]), int(c["j"])))
        else:
            cells_set.add((int(c[0]), int(c[1])))

    cx, cz = _grid_floor_centroid(floor, cell_size)
    bx0, bz0, bx1, bz1 = _grid_floor_bbox(floor, cell_size)
    extra_path_cells = []

    for lz in load_zones:
        pos = list(lz.get("pos", [0, 0, 0]))
        sz  = list(lz.get("size", [3.0, 3.0, 1.0]))
        is_interior = (lz.get("auto", True) is False)

        # Outward direction from level centroid → load zone position.
        dx = pos[0] - cx
        dz = pos[2] - cz
        dlen = math.hypot(dx, dz)
        if dlen < 1e-3 or is_interior:
            # Either degenerate (zone on top of centroid) or it's an
            # interior cellar trapdoor — leave the position alone, but
            # still publish a footprint for wall suppression.
            out["footprints"].append({
                "pos":  pos,
                "halfx": sz[0] / 2.0 + 0.1,
                "halfz": sz[2] / 2.0 + 0.1,
            })
            continue
        ux = dx / dlen
        uz = dz / dlen

        # Walk the outward ray from the original load_zone position
        # OUTWARD until we leave the walking cell footprint. The last
        # walking cell we crossed is the level edge along that ray —
        # snap the trigger to its outer face. This is more robust
        # than snapping to the bbox: irregular footprints (sourceplain
        # is a wide cross, not a square) put the actual edge at a
        # very different place from the bbox extreme.
        edge_cell = None
        # Step along the ray in half-cell increments in both
        # directions: first inward to find SOME walking cell to seed
        # with (the lz might already be outside the footprint), then
        # outward to find the last walking cell.
        step = cell_size * 0.5
        seed_cell = (int(math.floor(pos[0] / cell_size)),
                     int(math.floor(pos[2] / cell_size)))
        if seed_cell not in cells_set:
            # Walk inward up to the bbox span looking for a cell to
            # start from. Cap the search so degenerate inputs don't
            # spin forever.
            span = math.hypot(bx1 - bx0, bz1 - bz0)
            max_steps = int(span / step) + 4
            found = None
            for k in range(1, max_steps):
                tx = pos[0] - ux * step * k
                tz = pos[2] - uz * step * k
                ck = (int(math.floor(tx / cell_size)),
                      int(math.floor(tz / cell_size)))
                if ck in cells_set:
                    found = (tx, tz, ck)
                    break
            if found is None:
                # Could not seed — leave the load_zone alone, just
                # publish its footprint for wall suppression.
                out["footprints"].append({
                    "pos":  pos,
                    "halfx": sz[0] / 2.0 + 0.1,
                    "halfz": sz[2] / 2.0 + 0.1,
                })
                continue
            seed_x, seed_z, seed_cell = found
        else:
            seed_x, seed_z = pos[0], pos[2]

        # Walk outward from seed until we exit the footprint. The
        # last (tx, tz) inside is the snap point.
        last_in_x, last_in_z = seed_x, seed_z
        span = math.hypot(bx1 - bx0, bz1 - bz0)
        max_out_steps = int(span / step) + 4
        for k in range(1, max_out_steps):
            tx = seed_x + ux * step * k
            tz = seed_z + uz * step * k
            ck = (int(math.floor(tx / cell_size)),
                  int(math.floor(tz / cell_size)))
            if ck in cells_set:
                last_in_x, last_in_z = tx, tz
                edge_cell = ck
            else:
                break
        # Snap pos to (last_in_x, last_in_z), then pull half a cell
        # back inward so the trigger is clear of the wall edge —
        # otherwise the box-collider in tree_wall.gd's gap-piece
        # boundary would sometimes catch the player as they crossed.
        # Pulling 0.5*cell_size keeps us inside the last walking cell.
        new_x = last_in_x - ux * cell_size * 0.5
        new_z = last_in_z - uz * cell_size * 0.5
        # Apply the snap. Y is preserved.
        pos[0] = new_x
        pos[2] = new_z
        lz["pos"] = pos

        # Path cells: walk INWARD from the snapped trigger position
        # toward the centroid, recording the closest LOAD_ZONE_PATH_CELLS
        # cells inside the footprint. Step at half-cell increments so
        # we don't skip past a cell on diagonal paths, and dedupe.
        seen = set()
        # Cap the walk to a generous distance — diagonal corridors
        # through irregular footprints can take a few cells before
        # the first hit.
        max_path_steps = int(span / step) + 4
        for step_idx in range(1, max_path_steps):
            tx = new_x - ux * step * step_idx
            tz = new_z - uz * step * step_idx
            ci = int(math.floor(tx / cell_size))
            cj = int(math.floor(tz / cell_size))
            if (ci, cj) in cells_set and (ci, cj) not in seen:
                seen.add((ci, cj))
                extra_path_cells.append((ci, cj))
                if len(seen) >= LOAD_ZONE_PATH_CELLS:
                    break
        # Expanded footprint: at least the gap arc width worth of
        # opening centred at the snapped position, perpendicular to
        # the outward direction. Translate "gap arc width" into a
        # straight perpendicular distance: at radius dlen, an arc of
        # width w (radians) spans approximately dlen*w meters.
        # We just want the OPENING in the boundary to be at least
        # LOAD_ZONE_MIN_GAP_M wide.
        gap_m = max(LOAD_ZONE_MIN_GAP_M, sz[0], sz[2])
        # The opening axis is perpendicular to the outward direction.
        # If outward is mostly along x, the opening spans z (and vice
        # versa). Snap axes for the wider footprint:
        if abs(ux) >= abs(uz):
            half_open = max(sz[2] * 0.5, gap_m * 0.5)
            footprint = {
                "pos":  list(pos),
                "halfx": sz[0] / 2.0 + 0.1,
                "halfz": half_open + 0.1,
            }
        else:
            half_open = max(sz[0] * 0.5, gap_m * 0.5)
            footprint = {
                "pos":  list(pos),
                "halfx": half_open + 0.1,
                "halfz": sz[2] / 2.0 + 0.1,
            }
        out["footprints"].append(footprint)

    if extra_path_cells:
        out["path_cells_per_floor"][floor_idx] = extra_path_cells
    return out


def emit_grid_floors(b, grid, load_zones=None, doors=None,
                     lz_footprints=None, path_cells_per_floor=None):
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
    # Footprints from _preprocess_load_zones — wider than the raw
    # zone boxes so we carve a real walkable gap, not a 1m slot in
    # the wall the player has to thread through pixel-perfect.
    if lz_footprints is None:
        lz_footprints = []
        for lz in load_zones:
            pos = lz.get("pos", [0, 0, 0])
            sz  = lz.get("size", [3, 3, 1])
            lz_footprints.append({
                "pos":  pos,
                "halfx": sz[0] / 2.0 + 0.1,
                "halfz": sz[2] / 2.0 + 0.1,
            })
    path_cells_per_floor = path_cells_per_floor or {}

    # Union of EVERY floor's walking cells — used by the per-floor wall
    # emission below so we don't emit a wall between two floors that
    # overlap. Example: brookhold has a 'yard' floor and a 'paddock'
    # floor; for paddock-perimeter cells whose neighbour is a yard cell
    # (not a paddock cell), we don't want to drop a fence wall there —
    # otherwise the player can hop into the paddock but can't leave.
    # The fence still appears at paddock-cells whose neighbour is void
    # in ALL floors.
    all_walking_cells: set = set()
    for f in floors:
        for c in f.get("cells", []):
            if isinstance(c, dict):
                all_walking_cells.add((int(c.get("i", 0)),
                                       int(c.get("j", 0))))
            else:
                all_walking_cells.add((int(c[0]), int(c[1])))

    def in_load_zone(wx, wz):
        for fp in lz_footprints:
            pos = fp["pos"]
            if (abs(wx - pos[0]) < fp["halfx"]
                and abs(wz - pos[2]) < fp["halfz"]):
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

    for floor_idx, floor in enumerate(floors):
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
            # path_cells: cleared corridor cells laid down by the
            # load-zone preprocessor so each gap in the tree wall
            # reads as a packed-dirt trail leading out of the level.
            extra_paths = path_cells_per_floor.get(floor_idx, [])
            path_cells_str = "[%s]" % ", ".join(
                "Vector2i(%d, %d)" % (ci, cj) for (ci, cj) in extra_paths
            )
            b.add_node(
                '[node name="TerrainMesh%d" type="Node3D" parent="."]\n'
                'script = ExtResource("terrain_mesh_script")\n'
                'cell_data = %s\n'
                'cell_size = %g\n'
                'floor_y = %g\n'
                'floor_color = %s\n'
                'skirt_depth = 6.0\n'
                'smoothing = 0.45\n'
                'path_cells = %s\n'
                % (n, cell_data_str, cell_size, y, fc_str, path_cells_str)
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
                # Wall only emits if the neighbour cell is in NO floor.
                # If it's a walking cell in a different floor (paddock
                # vs yard), the player can step between — no wall.
                if (i + 1, j) not in all_walking_cells and not in_load_zone(x_right, cz_mid):
                    emit_edge((x_right, z_north), (x_right, z_south),
                              x_right, cz_mid, wall_thick, cell_size, i, j)
                if (i - 1, j) not in all_walking_cells and not in_load_zone(x_left, cz_mid):
                    emit_edge((x_left, z_south), (x_left, z_north),
                              x_left, cz_mid, wall_thick, cell_size, i, j)
                if (i, j + 1) not in all_walking_cells and not in_load_zone(cx_mid, z_south):
                    emit_edge((x_left, z_south), (x_right, z_south),
                              cx_mid, z_south, cell_size, wall_thick, i, j)
                if (i, j - 1) not in all_walking_cells and not in_load_zone(cx_mid, z_north):
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


def _tree_wall_gaps_for_boundary(boundary, load_zones):
    """For an explicit tree_walls polygon, compute the angle-based
    `gaps` Array of {angle, width} dicts to carve out clearings for
    every load_zone whose position is "outside" or "near the
    perimeter of" the polygon. The angle is measured from the
    polygon centroid in radians (0 = +x = east, +y screen-z = north,
    matching tree_wall.gd's _in_gap)."""
    if not boundary or not load_zones:
        return []
    cx = sum(p[0] for p in boundary) / float(len(boundary))
    cz = sum(p[1] for p in boundary) / float(len(boundary))
    # Approx polygon "radius" — average distance from centroid to
    # each vertex. Used to convert the desired gap_metres into a gap
    # arc width.
    avg_r = sum(math.hypot(p[0] - cx, p[1] - cz) for p in boundary) / float(len(boundary))
    if avg_r < 1e-3:
        return []
    out = []
    for lz in load_zones:
        if lz.get("auto", True) is False:
            # Interior cellar trapdoors don't punch through outdoor
            # tree walls — skip.
            continue
        pos = lz.get("pos", [0, 0, 0])
        sz  = lz.get("size", [3.0, 3.0, 1.0])
        dx = pos[0] - cx
        dz = pos[2] - cz
        if math.hypot(dx, dz) < 1e-3:
            continue
        ang = math.atan2(dz, dx)
        gap_m = max(LOAD_ZONE_MIN_GAP_M, sz[0], sz[2])
        # arc_width = gap_m / radius (small-angle approx is fine —
        # gaps are typically a few-degree arcs).
        width = gap_m / avg_r
        # Floor at ~10° of arc so even huge polygons get a visible
        # opening, ceiling at ~60° so we don't carve away the whole
        # wall on tiny enclosures.
        width = max(0.18, min(width, 1.05))
        out.append({"angle": ang, "width": width})
    return out


def emit_tree_walls(b, walls, load_zones=None):
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

        # Carve gaps for each load_zone whose outward direction
        # punches through this polygon. Combines any author-supplied
        # `gaps` (e.g. ornamental clearings) with the auto-computed
        # ones; tree_wall.gd treats them as a flat list.
        author_gaps = list(tw.get("gaps", []))
        auto_gaps = _tree_wall_gaps_for_boundary(boundary, load_zones or [])
        all_gaps = author_gaps + auto_gaps
        if all_gaps:
            gap_strs = [
                '{"angle": %g, "width": %g}' % (float(g["angle"]), float(g["width"]))
                for g in all_gaps
            ]
            props.append("gaps = [%s]" % ", ".join(gap_strs))
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


def emit_spawns(b, spawns, grid=None):
    b.add_node('[node name="Spawns" type="Node3D" parent="."]\n')
    for sp in (spawns or []):
        x, y, z = sp["pos"]
        rot = float(sp.get("rotation_y", 0.0))
        # Bake the cell's ground y + capsule-midpoint offset into the
        # spawn marker so the player materialises ON the floor rather
        # than ankle-deep in a hill (or floating above one).
        cy = cell_y_lookup(grid, x, z)
        if cy is not None and (y - cy) <= _INTENTIONAL_RAISE_THRESHOLD:
            y = cy + _SPAWN_Y_OFFSET
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


def emit_props(b, props, grid=None):
    for i, p in enumerate(props or []):
        kind = p["type"]
        x, y, z = p["pos"]
        # Bake the cell's ground y + per-prop offset into the prop's
        # transform.origin.y. The JSON y is preserved only when it's
        # been deliberately raised above the floor (chest on a platform).
        # See resolve_ground_y / _PROP_Y_OFFSETS above.
        y, _ground_src = resolve_ground_y(grid, kind, (x, y, z))
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
            # Optional cross-scene gating: hide the chest until the
            # named GameState quest_flag is set. The build script just
            # forwards the string; treasure_chest.gd reads it on _ready
            # and self-hides if GameState.has_flag(...) is false.
            if "requires" in p:
                attrs.append('requires_flag = "%s"' % escape(str(p["requires"])))
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
            if "boss_id" in p:
                attrs.append('boss_id = "%s"' % escape(str(p["boss_id"])))
            elif boss_id:
                attrs.append('boss_id = "%s"' % escape(boss_id))
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
        elif kind == "time_gate":
            # Phase-of-day gate. Solid until TimeOfDay.t enters its
            # `time_phase` window (day/night/dawn/dusk/any), then
            # collision drops + alpha tweens out. See time_gate.gd.
            b.ext("time_gate")
            attrs = ['transform = %s' % t3(x, y, z, rot)]
            if "time_phase" in p:
                attrs.append('time_phase = "%s"' % escape(str(p["time_phase"])))
            b.add_node(
                '[node name="TimeGate%d" parent="." instance=ExtResource("time_gate")]\n'
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


def emit_load_zones(b, zones, grid=None):
    # Load zones are INVISIBLE triggers now — they sit at the level
    # boundary inside a deliberate gap in the tree wall (carved by
    # _preprocess_load_zones + tree_wall.gd's `gaps` export). The
    # player sees: a packed-dirt path leading to a clearing in the
    # trees; no black veil, no visible box. The Hint label still
    # floats above the gap as a "Travel — wyrdwood" wayfinding cue,
    # and load_zone.gd grows a soft ground-glow ring when the player
    # is within 6 m so there's still a visual confirmation.
    for i, lz in enumerate(zones or []):
        b.ext("load_zone_script")
        x, y, z = lz["pos"]
        sx, sy, sz = lz.get("size", [3.0, 3.0, 1.0])
        rot = float(lz.get("rotation_y", 0.0))
        # Bake the ground y + chest-height offset into the trigger box
        # so it sits on the cell, not whatever literal y the JSON had.
        # Preserve obviously-raised authored y (lz on a platform).
        cy = cell_y_lookup(grid, x, z)
        if cy is not None and (y - cy) <= _INTENTIONAL_RAISE_THRESHOLD:
            y = cy + _LOAD_ZONE_Y_OFFSET
        target_scene = lz["target_scene"]
        if not target_scene.startswith("res://"):
            target_scene = "res://scenes/%s.tscn" % target_scene
        target_spawn = lz.get("target_spawn", "default")
        auto = "true" if lz.get("auto", True) else "false"
        prompt = escape(lz.get("prompt", ""))
        shape = b.add_sub("BoxShape3D", [("size", vstr([sx, sy, sz]))])
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
            '[node name="Hint" type="Label3D" parent="LoadZone%d"]\n'
            'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, %g, 0)\n'
            'text = "%s"\n'
            'font_size = 32\n'
            'outline_size = 8\n'
            'billboard = 1\n'
            'no_depth_test = true\n'
            % (i, shape, i, sy + 0.8, prompt or "Travel")
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
    # Reset memoised cell→y tables — `id(grid)` can be reused across
    # levels by CPython if the previous data dict was GCed, so clearing
    # explicitly keeps the bake deterministic.
    _CELL_Y_CACHE.clear()
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
    # Per-directory aesthetic palette (DESIGN.md §8). Each is an
    # optional 3-array of floats in [0,1]; written as Color exports on
    # the root so dungeon_root.gd can build a procedural sky + sun at
    # runtime if the scene has no static WorldEnvironment.
    for key in ("sky_color", "fog_color", "ambient_color", "sun_color"):
        val = data.get(key)
        if val is None:
            continue
        # Accept 3- or 4-arrays; pad alpha to 1.0.
        if len(val) == 3:
            val = list(val) + [1.0]
        root_attrs.append('%s = Color(%g, %g, %g, %g)' % (
            key, val[0], val[1], val[2], val[3]))
    b.nodes.append('[node name="%s" type="Node3D"]\n%s\n'
                   % (data.get("name", data["id"]), "\n".join(root_attrs)))
    # Snap load_zones to the level boundary, compute wider footprints
    # for wall suppression, and lay path_cells leading inward from
    # each gap. Done BEFORE any geometry emission so every consumer
    # sees the snapped positions and the wider footprints.
    lz_info = _preprocess_load_zones(data)

    emit_environment(b, data.get("environment", {}))
    emit_floor(b, data.get("floor"))
    emit_walls(b, data.get("rooms", []), data.get("doorways", []))
    emit_doors(b, data.get("doorways", []))
    emit_tree_walls(b, data.get("tree_walls", []), data.get("load_zones", []))
    emit_grid_floors(b, data.get("grid"), data.get("load_zones", []),
                     data.get("doors", []),
                     lz_footprints=lz_info["footprints"],
                     path_cells_per_floor=lz_info["path_cells_per_floor"])
    emit_doors_v2(b, data.get("doors", []))
    emit_lights(b, data.get("lights", []))
    emit_spawns(b, data.get("spawns", []), grid=data.get("grid"))
    emit_enemies(b, data.get("enemies", []))
    emit_props(b, data.get("props", []), grid=data.get("grid"))
    emit_load_zones(b, data.get("load_zones", []), grid=data.get("grid"))
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
