#!/usr/bin/env python3
"""Scaffold a new dungeon JSON for a Wyrdmark-Filesystem directory.
Generates a minimal-but-playable level with:

  - sensible default environment per scope (passthrough / hub / kingdom)
  - small cell footprint sized to scope
  - default and parent-arrival spawn markers
  - load_zones to every neighbour declared in the SCAFFOLD table
  - a single sign noting the directory's path

Run from project root:
    python3 tools/scaffold_directory.py            # generate all
    python3 tools/scaffold_directory.py wake drift # generate specific ids

Existing dungeon files with the same id are NOT overwritten unless
--force is passed.
"""

import json
import math
import os
import sys

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

# ---- per-directory authoring metadata --------------------------------------
#
# id, fs_path, display_name, scope, theme, neighbours [(id, prompt)],
# environment palette, music id (defaults to id), key_group (defaults
# to id), arrival prompt for sign.
#
# scope: "passthrough" (~12x12), "hub" (~30x30), "kingdom" (~50x50)

SCAFFOLD = [
    # Root + summit
    {
        "id": "crown", "name": "The Crown", "scope": "hub",
        "theme": "summit", "music": "crown",
        "neighbours": [
            ("wake",         "[E] Down to the Wake"),
            ("scriptorium",  "[E] To the Scriptorium"),
            ("burrows",      "[E] Down to the Burrows"),
            ("docks",        "[E] To the Docks"),
            ("optional_yard","[E] Into the Optional Yard"),
            ("murk",         "[E] Down to the Murk"),
            ("drift",        "[E] To the Drift"),
            ("sprawl",       "[E] Into the Sprawl"),
            ("library",      "[E] To the Library"),
            ("forge",        "[E] To the Forge"),
        ],
    },
    # Boot
    {
        "id": "wake", "name": "The Wake", "scope": "hub",
        "theme": "boot", "music": "wake",
        "neighbours": [
            ("crown",     "[E] Up to the Crown"),
            ("wake_grub", "[E] Into the Sub-shrine"),
            ("scriptorium","[E] To the Scriptorium"),
            ("burrows",   "[E] To the Burrows"),
            ("sprawl",    "[E] To the Sprawl"),
        ],
    },
    {
        "id": "wake_grub", "name": "Wake Sub-shrine", "scope": "passthrough",
        "theme": "boot", "music": "wake",
        "neighbours": [("wake", "[E] Back to the Wake")],
    },
    # Etc
    {
        "id": "scriptorium", "name": "The Scriptorium", "scope": "hub",
        "theme": "stone-vault", "music": "sigilkeep",
        "neighbours": [
            ("crown",     "[E] Up to the Crown"),
            ("sigilkeep", "[E] To Sigilkeep"),
            ("wake",      "[E] To the Wake"),
            ("burrows",   "[E] To the Burrows"),
        ],
    },
    # Home
    {
        "id": "burrows", "name": "The Burrows", "scope": "hub",
        "theme": "village-commons", "music": "hearthold",
        "neighbours": [
            ("crown",     "[E] Up to the Crown"),
            ("hearthold", "[E] To Hearthold"),
            ("brookhold", "[E] To Brookhold"),
            ("old_hold",  "[E] Old Hold"),
            ("scriptorium", "[E] To the Scriptorium"),
            ("sprawl",    "[E] To the Sprawl"),
        ],
    },
    {
        "id": "old_hold", "name": "The Old Hold", "scope": "passthrough",
        "theme": "overgrown-homestead", "music": "wyrdkin_glade",
        "neighbours": [("burrows", "[E] Back to the Burrows")],
    },
    # Mnt
    {
        "id": "docks", "name": "The Docks", "scope": "hub",
        "theme": "windy-quayside", "music": "stoneroost",
        "neighbours": [
            ("crown",            "[E] Up to the Crown"),
            ("wyrdmark_mounts",  "[E] Wyrdmark Mounts"),
            ("docks_foreign",    "[E] Foreign Mount"),
        ],
    },
    {
        "id": "wyrdmark_mounts", "name": "Wyrdmark Mounts",
        "scope": "passthrough", "theme": "windy-plateau", "music": "stoneroost",
        "neighbours": [
            ("docks",      "[E] Back to the Docks"),
            ("stoneroost", "[E] On to Stoneroost"),
        ],
    },
    {
        "id": "docks_foreign", "name": "Foreign Mount", "scope": "passthrough",
        "theme": "stone-shrine", "music": "stoneroost",
        "neighbours": [("docks", "[E] Back to the Docks")],
    },
    # Opt
    {
        "id": "optional_yard", "name": "The Optional Yard", "scope": "hub",
        "theme": "parkland", "music": "wyrdkin_glade",
        "neighbours": [
            ("crown",             "[E] Up to the Crown"),
            ("wyrdmark_gateway",  "[E] Into the Wyrdmark"),
        ],
    },
    {
        "id": "wyrdmark_gateway", "name": "Wyrdmark Gateway",
        "scope": "passthrough", "theme": "stone-arch", "music": "wyrdkin_glade",
        "neighbours": [
            ("optional_yard", "[E] Back to the Optional Yard"),
            ("wyrdkin_glade", "[E] Into the Glade"),
            ("wyrdwood",      "[E] Into the Wyrdwood"),
            ("sourceplain",   "[E] Onto the Sourceplain"),
        ],
    },
    # Proc / tmp
    {
        "id": "murk", "name": "The Murk", "scope": "hub",
        "theme": "fog-swamp", "music": "burnt_hollow",
        "neighbours": [
            ("crown", "[E] Up to the Crown"),
        ],
    },
    {
        "id": "drift", "name": "The Drift", "scope": "kingdom",
        "theme": "festival-town", "music": "drift",
        "neighbours": [
            ("crown", "[E] Up to the Crown"),
            ("burnt_hollow", "[E] Out to the Burnt Hollow"),
        ],
    },
    # Usr
    {
        "id": "sprawl", "name": "The Sprawl", "scope": "hub",
        "theme": "contested-junction", "music": "hearthold",
        "neighbours": [
            ("crown",   "[E] Up to the Crown"),
            ("binds",   "[E] To the Binds"),
            ("sharers", "[E] To the Sharers"),
            ("locals",  "[E] To the Locals"),
            ("burrows", "[E] To the Burrows"),
            ("wake",    "[E] To the Wake"),
        ],
    },
    {
        "id": "binds", "name": "The Binds", "scope": "hub",
        "theme": "market-alleys", "music": "hearthold",
        "neighbours": [("sprawl", "[E] Back to the Sprawl")],
    },
    {
        "id": "sharers", "name": "The Sharers", "scope": "hub",
        "theme": "open-courtyards", "music": "sigilkeep",
        "neighbours": [
            ("sprawl",    "[E] Back to the Sprawl"),
            ("old_plays", "[E] To the Old Plays"),
        ],
    },
    {
        "id": "old_plays", "name": "The Old Plays", "scope": "passthrough",
        "theme": "derelict-carnival", "music": "drift",
        "neighbours": [("sharers", "[E] Back to the Sharers")],
    },
    {
        "id": "locals", "name": "The Locals", "scope": "hub",
        "theme": "frontier-town", "music": "brookhold",
        "neighbours": [("sprawl", "[E] Back to the Sprawl")],
    },
    # Var
    {
        "id": "library", "name": "The Library of Past Echoes",
        "scope": "kingdom", "theme": "vast-archive", "music": "sigilkeep",
        "neighbours": [
            ("crown",     "[E] Up to the Crown"),
            ("cache",     "[E] Down to the Cache"),
            ("stacks",    "[E] To the Stacks"),
            ("ledger",    "[E] To the Ledger"),
            ("backwater", "[E] To the Backwater"),
        ],
    },
    {
        "id": "cache", "name": "The Cache", "scope": "hub",
        "theme": "lower-archive", "music": "sigilkeep",
        "neighbours": [
            ("library",         "[E] Up to the Library"),
            ("cache_wyrdmark",  "[E] Wyrdmark records"),
        ],
    },
    {
        "id": "cache_wyrdmark", "name": "Wyrdmark Records",
        "scope": "passthrough", "theme": "alcove", "music": "sigilkeep",
        "neighbours": [
            ("cache",          "[E] Back to the Cache"),
            ("dungeon_first",  "[E] Into the Hollow"),
        ],
    },
    {
        "id": "stacks", "name": "The Stacks", "scope": "hub",
        "theme": "labelled-shelves", "music": "sigilkeep",
        "neighbours": [("library", "[E] Back to the Library")],
    },
    {
        "id": "ledger", "name": "The Ledger", "scope": "hub",
        "theme": "running-scrolls", "music": "sigilkeep",
        "neighbours": [("library", "[E] Back to the Library")],
    },
    {
        "id": "backwater", "name": "The Backwater", "scope": "passthrough",
        "theme": "shallow-stream", "music": "mirelake",
        "neighbours": [
            ("library",   "[E] Back to the Library"),
            ("mirelake",  "[E] Down to Mirelake"),
        ],
    },
    # Dev
    {
        "id": "forge", "name": "The Forge", "scope": "kingdom",
        "theme": "industrial", "music": "burnt_hollow",
        "neighbours": [
            ("crown",     "[E] Up to the Crown"),
            ("null_door", "[E] The Null Door"),
        ],
    },
    {
        "id": "null_door", "name": "The Null Door", "scope": "passthrough",
        "theme": "black-doorway", "music": "dungeon_first",
        "neighbours": [("forge", "[E] Back to the Forge")],
    },
    # ---- v2 expansion (FILESYSTEM.md §2.2) — 27 new dirs --------------
    # Every new dir is a leaf in the FHS tree, so each scaffolds as a
    # small passthrough room with one outgoing zone back to its parent.
    # Non-tree shortcuts (sbin↔usr_sbin, lib↔usr_lib, var_mail↔homes,
    # proc_init↔sys, dev_loop loop) are deferred to a later content pass.
    # Top-level (7).
    {
        "id": "bin", "name": "The Toolshed", "scope": "passthrough",
        "theme": "tool-workshop", "music": "hearthold",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    {
        "id": "sbin", "name": "Sentinel Hall", "scope": "passthrough",
        "theme": "stone-vault", "music": "sigilkeep",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    {
        "id": "lib", "name": "The Loomhouse", "scope": "passthrough",
        "theme": "loomhouse", "music": "sigilkeep",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    {
        "id": "lost_found", "name": "Hall of Lost Things",
        "scope": "passthrough", "theme": "alcove", "music": "sigilkeep",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    {
        "id": "root_hold", "name": "Root's Hold", "scope": "passthrough",
        "theme": "overgrown-homestead", "music": "wyrdkin_glade",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    {
        "id": "srv", "name": "The Servery", "scope": "passthrough",
        "theme": "village-commons", "music": "hearthold",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    {
        "id": "sys", "name": "The Heartworks", "scope": "passthrough",
        "theme": "heartworks", "music": "crown",
        "neighbours": [("crown", "[E] Up to the Crown")],
    },
    # Under /etc (2).
    {
        "id": "etc_initd", "name": "The Initiates", "scope": "passthrough",
        "theme": "alcove", "music": "sigilkeep",
        "neighbours": [("scriptorium", "[E] Back to the Scriptorium")],
    },
    {
        "id": "etc_passwd", "name": "The Names Hall", "scope": "passthrough",
        "theme": "stone-vault", "music": "sigilkeep",
        "neighbours": [("scriptorium", "[E] Back to the Scriptorium")],
    },
    # Under /home (2).
    {
        "id": "home_lirien", "name": "Lirien's Chamber",
        "scope": "passthrough", "theme": "tower-study", "music": "crown",
        "neighbours": [("burrows", "[E] Back to the Burrows")],
    },
    {
        "id": "home_khorgaul", "name": "The Khorgaul Roost",
        "scope": "passthrough", "theme": "burned-hold", "music": "burnt_hollow",
        "neighbours": [("burrows", "[E] Back to the Burrows")],
    },
    # Under /proc (3).
    {
        "id": "proc_init", "name": "The First Process",
        "scope": "passthrough", "theme": "fog-swamp", "music": "burnt_hollow",
        "neighbours": [("murk", "[E] Back to the Murk")],
    },
    {
        "id": "proc_sys", "name": "The Murk Senate",
        "scope": "passthrough", "theme": "fog-swamp", "music": "burnt_hollow",
        "neighbours": [("murk", "[E] Back to the Murk")],
    },
    {
        "id": "proc_42", "name": "Process 42",
        "scope": "passthrough", "theme": "fog-swamp", "music": "burnt_hollow",
        "neighbours": [("murk", "[E] Back to the Murk")],
    },
    # Under /usr (5).
    {
        "id": "usr_lib", "name": "Sprawl Library", "scope": "passthrough",
        "theme": "labelled-shelves", "music": "sigilkeep",
        "neighbours": [("sprawl", "[E] Back to the Sprawl")],
    },
    {
        "id": "usr_sbin", "name": "Sprawl Outpost", "scope": "passthrough",
        "theme": "stone-vault", "music": "sigilkeep",
        "neighbours": [("sprawl", "[E] Back to the Sprawl")],
    },
    {
        "id": "usr_src", "name": "The Sourcerooms", "scope": "passthrough",
        "theme": "vast-archive", "music": "sigilkeep",
        "neighbours": [("sprawl", "[E] Back to the Sprawl")],
    },
    {
        "id": "usr_include", "name": "Sprawl Index Hall",
        "scope": "passthrough", "theme": "labelled-shelves", "music": "sigilkeep",
        "neighbours": [("sprawl", "[E] Back to the Sprawl")],
    },
    {
        "id": "usr_share_man", "name": "The Manuscripts",
        "scope": "passthrough", "theme": "alcove", "music": "sigilkeep",
        "neighbours": [("sharers", "[E] Back to the Sharers")],
    },
    # Under /var (4).
    {
        "id": "var_mail", "name": "The Postmark", "scope": "passthrough",
        "theme": "labelled-shelves", "music": "sigilkeep",
        "neighbours": [("library", "[E] Back to the Library")],
    },
    {
        "id": "var_run", "name": "The Pulse Room", "scope": "passthrough",
        "theme": "running-scrolls", "music": "sigilkeep",
        "neighbours": [("library", "[E] Back to the Library")],
    },
    {
        "id": "var_tmp", "name": "The Long Drift", "scope": "passthrough",
        "theme": "festival-town", "music": "drift",
        "neighbours": [("library", "[E] Back to the Library")],
    },
    {
        "id": "var_games", "name": "The Scoreroom", "scope": "passthrough",
        "theme": "derelict-carnival", "music": "drift",
        "neighbours": [("library", "[E] Back to the Library")],
    },
    # Under /dev (4).
    {
        "id": "dev_zero", "name": "The Quietness", "scope": "passthrough",
        "theme": "quietness", "music": "dungeon_first",
        "neighbours": [("forge", "[E] Back to the Forge")],
    },
    {
        "id": "dev_random", "name": "The Wild Hum", "scope": "passthrough",
        "theme": "wild-hum", "music": "burnt_hollow",
        "neighbours": [("forge", "[E] Back to the Forge")],
    },
    {
        "id": "dev_tty", "name": "The Speaker's Room",
        "scope": "passthrough", "theme": "speakers-room", "music": "sigilkeep",
        "neighbours": [("forge", "[E] Back to the Forge")],
    },
    {
        "id": "dev_loop", "name": "The Recursion Hall",
        "scope": "passthrough", "theme": "recursion-hall", "music": "burnt_hollow",
        "neighbours": [("forge", "[E] Back to the Forge")],
    },
    # ---- canonical Unix sub-dirs the player will instantly recognise (10) ----
    # Each is a leaf in the tree. Parents wire to them via patched JSONs.
    # Under /home/hearthold (2).
    {
        "id": "hearthold_desktop", "name": "Hearthold Desktop",
        "scope": "passthrough", "theme": "village-commons", "music": "hearthold",
        "neighbours": [("hearthold", "[E] Back to Hearthold")],
    },
    {
        "id": "hearthold_downloads", "name": "Hearthold Downloads",
        "scope": "passthrough", "theme": "labelled-shelves", "music": "hearthold",
        "neighbours": [("hearthold", "[E] Back to Hearthold")],
    },
    # Under /home/wyrdkin (3) — Tux's grandparents' hold + dotfiles.
    {
        "id": "wyrdkin_config", "name": "The Ritual Room",
        "scope": "passthrough", "theme": "alcove", "music": "wyrdkin_glade",
        "neighbours": [("old_hold", "[E] Back to the Old Hold")],
    },
    {
        "id": "wyrdkin_cache", "name": "The Stale Pantry",
        "scope": "passthrough", "theme": "lower-archive", "music": "wyrdkin_glade",
        "neighbours": [("old_hold", "[E] Back to the Old Hold")],
    },
    {
        "id": "wyrdkin_bash_history", "name": "The Hall of Spoken Lines",
        "scope": "passthrough", "theme": "running-scrolls", "music": "wyrdkin_glade",
        "neighbours": [("old_hold", "[E] Back to the Old Hold")],
    },
    # Under /etc (3).
    {
        "id": "etc_hosts", "name": "The Hosts Tablet",
        "scope": "passthrough", "theme": "stone-vault", "music": "sigilkeep",
        "neighbours": [("scriptorium", "[E] Back to the Scriptorium")],
    },
    {
        "id": "etc_motd", "name": "The Message of the Day",
        "scope": "passthrough", "theme": "stone-vault", "music": "sigilkeep",
        "neighbours": [("scriptorium", "[E] Back to the Scriptorium")],
    },
    {
        "id": "etc_fstab", "name": "The Mount Table",
        "scope": "passthrough", "theme": "labelled-shelves", "music": "sigilkeep",
        "neighbours": [("scriptorium", "[E] Back to the Scriptorium")],
    },
    # Under /var/log (1).
    {
        "id": "var_log_syslog", "name": "The Syslog Hall",
        "scope": "passthrough", "theme": "running-scrolls", "music": "sigilkeep",
        "neighbours": [("ledger", "[E] Back to the Ledger")],
    },
    # Under /tmp (1).
    {
        "id": "tmp_x11_unix", "name": "The X11 Socket Room",
        "scope": "passthrough", "theme": "wild-hum", "music": "drift",
        "neighbours": [("drift", "[E] Back to the Drift")],
    },
]

# ---- environment palettes per theme ---------------------------------------

PALETTES = {
    "summit":            {"sky_top":[0.45,0.55,0.78,1],"sky_horizon":[0.85,0.85,0.95,1],"ground_horizon":[0.62,0.62,0.70,1],"ground_bottom":[0.30,0.32,0.36,1],"ambient_color":[0.78,0.82,0.92,1],"ambient_energy":0.45,"fog_density":0.0035,"fog_color":[0.78,0.82,0.92,1],"sun_dir":[-0.4,-0.7,-0.4],"sun_color":[1.0,0.96,0.85,1],"sun_energy":1.4,"floor_color":[0.50,0.50,0.55,1],"wall_color":[0.40,0.40,0.45,1]},
    "boot":              {"sky_top":[0.40,0.36,0.55,1],"sky_horizon":[0.70,0.55,0.45,1],"ground_horizon":[0.45,0.36,0.32,1],"ground_bottom":[0.20,0.18,0.16,1],"ambient_color":[0.70,0.62,0.55,1],"ambient_energy":0.45,"fog_density":0.003,"fog_color":[0.55,0.45,0.40,1],"sun_dir":[0.5,-0.5,-0.5],"sun_color":[1.0,0.78,0.55,1],"sun_energy":1.2,"floor_color":[0.42,0.36,0.30,1],"wall_color":[0.32,0.28,0.24,1]},
    "stone-vault":       {"sky_top":[0.20,0.22,0.30,1],"sky_horizon":[0.40,0.36,0.36,1],"ground_horizon":[0.30,0.28,0.30,1],"ground_bottom":[0.10,0.10,0.12,1],"ambient_color":[0.55,0.55,0.65,1],"ambient_energy":0.40,"fog_density":0.002,"fog_color":[0.30,0.30,0.40,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.85,0.85,1.0,1],"sun_energy":0.85,"floor_color":[0.32,0.30,0.36,1],"wall_color":[0.22,0.20,0.26,1]},
    "village-commons":   {"sky_top":[0.55,0.70,0.85,1],"sky_horizon":[0.95,0.85,0.65,1],"ground_horizon":[0.55,0.45,0.30,1],"ground_bottom":[0.20,0.18,0.10,1],"ambient_color":[0.85,0.85,0.78,1],"ambient_energy":0.50,"fog_density":0.0015,"fog_color":[0.85,0.85,0.75,1],"sun_dir":[-0.4,-0.7,-0.4],"sun_color":[1.0,0.96,0.82,1],"sun_energy":1.3,"floor_color":[0.55,0.45,0.30,1],"wall_color":[0.42,0.34,0.22,1]},
    "overgrown-homestead":{"sky_top":[0.45,0.55,0.65,1],"sky_horizon":[0.80,0.78,0.65,1],"ground_horizon":[0.40,0.42,0.30,1],"ground_bottom":[0.18,0.18,0.12,1],"ambient_color":[0.72,0.78,0.72,1],"ambient_energy":0.42,"fog_density":0.003,"fog_color":[0.72,0.75,0.65,1],"sun_dir":[-0.4,-0.6,-0.5],"sun_color":[0.95,0.92,0.78,1],"sun_energy":1.0,"floor_color":[0.40,0.42,0.28,1],"wall_color":[0.30,0.28,0.20,1]},
    "windy-quayside":    {"sky_top":[0.45,0.55,0.70,1],"sky_horizon":[0.80,0.82,0.85,1],"ground_horizon":[0.50,0.48,0.45,1],"ground_bottom":[0.18,0.18,0.18,1],"ambient_color":[0.78,0.82,0.85,1],"ambient_energy":0.42,"fog_density":0.003,"fog_color":[0.72,0.78,0.82,1],"sun_dir":[-0.5,-0.6,-0.4],"sun_color":[1.0,0.95,0.85,1],"sun_energy":1.1,"floor_color":[0.42,0.45,0.50,1],"wall_color":[0.30,0.32,0.35,1]},
    "windy-plateau":     {"sky_top":[0.40,0.50,0.65,1],"sky_horizon":[0.65,0.68,0.70,1],"ground_horizon":[0.45,0.42,0.40,1],"ground_bottom":[0.22,0.20,0.18,1],"ambient_color":[0.80,0.82,0.85,1],"ambient_energy":0.42,"fog_density":0.005,"fog_color":[0.65,0.66,0.70,1],"sun_dir":[-0.4,-0.7,-0.5],"sun_color":[1.0,0.95,0.82,1],"sun_energy":1.0,"floor_color":[0.40,0.38,0.34,1],"wall_color":[0.30,0.28,0.24,1]},
    "stone-shrine":      {"sky_top":[0.30,0.30,0.40,1],"sky_horizon":[0.55,0.45,0.40,1],"ground_horizon":[0.40,0.36,0.32,1],"ground_bottom":[0.18,0.16,0.14,1],"ambient_color":[0.55,0.55,0.58,1],"ambient_energy":0.40,"fog_density":0.005,"fog_color":[0.45,0.40,0.40,1],"sun_dir":[-0.3,-0.6,-0.5],"sun_color":[0.85,0.78,0.85,1],"sun_energy":0.7,"floor_color":[0.34,0.32,0.30,1],"wall_color":[0.22,0.20,0.20,1]},
    "parkland":          {"sky_top":[0.50,0.65,0.80,1],"sky_horizon":[0.85,0.82,0.70,1],"ground_horizon":[0.40,0.50,0.30,1],"ground_bottom":[0.16,0.18,0.12,1],"ambient_color":[0.85,0.88,0.78,1],"ambient_energy":0.50,"fog_density":0.0012,"fog_color":[0.82,0.85,0.78,1],"sun_dir":[-0.4,-0.7,-0.3],"sun_color":[1.0,0.96,0.82,1],"sun_energy":1.3,"floor_color":[0.30,0.50,0.28,1],"wall_color":[0.20,0.25,0.18,1]},
    "stone-arch":        {"sky_top":[0.50,0.65,0.80,1],"sky_horizon":[0.90,0.80,0.62,1],"ground_horizon":[0.40,0.45,0.30,1],"ground_bottom":[0.16,0.18,0.12,1],"ambient_color":[0.85,0.88,0.78,1],"ambient_energy":0.50,"fog_density":0.0015,"fog_color":[0.85,0.82,0.75,1],"sun_dir":[-0.4,-0.7,-0.3],"sun_color":[1.0,0.96,0.82,1],"sun_energy":1.2,"floor_color":[0.45,0.42,0.32,1],"wall_color":[0.30,0.26,0.20,1]},
    "fog-swamp":         {"sky_top":[0.30,0.34,0.40,1],"sky_horizon":[0.55,0.55,0.55,1],"ground_horizon":[0.36,0.34,0.30,1],"ground_bottom":[0.12,0.12,0.10,1],"ambient_color":[0.55,0.55,0.62,1],"ambient_energy":0.30,"fog_density":0.012,"fog_color":[0.50,0.55,0.55,1],"sun_dir":[-0.3,-0.5,-0.6],"sun_color":[0.75,0.78,0.85,1],"sun_energy":0.6,"floor_color":[0.22,0.26,0.22,1],"wall_color":[0.18,0.20,0.18,1]},
    "festival-town":     {"sky_top":[0.55,0.55,0.78,1],"sky_horizon":[0.95,0.65,0.55,1],"ground_horizon":[0.55,0.40,0.35,1],"ground_bottom":[0.22,0.16,0.14,1],"ambient_color":[0.85,0.78,0.78,1],"ambient_energy":0.50,"fog_density":0.0012,"fog_color":[0.85,0.78,0.85,1],"sun_dir":[-0.4,-0.7,-0.4],"sun_color":[1.0,0.85,0.65,1],"sun_energy":1.3,"floor_color":[0.55,0.45,0.32,1],"wall_color":[0.45,0.32,0.22,1]},
    "contested-junction":{"sky_top":[0.45,0.55,0.70,1],"sky_horizon":[0.85,0.78,0.62,1],"ground_horizon":[0.50,0.42,0.30,1],"ground_bottom":[0.18,0.16,0.12,1],"ambient_color":[0.85,0.82,0.78,1],"ambient_energy":0.50,"fog_density":0.0015,"fog_color":[0.80,0.78,0.72,1],"sun_dir":[-0.4,-0.7,-0.4],"sun_color":[1.0,0.95,0.78,1],"sun_energy":1.2,"floor_color":[0.50,0.45,0.32,1],"wall_color":[0.36,0.30,0.22,1]},
    "market-alleys":     {"sky_top":[0.40,0.50,0.70,1],"sky_horizon":[0.85,0.72,0.55,1],"ground_horizon":[0.50,0.40,0.30,1],"ground_bottom":[0.18,0.16,0.12,1],"ambient_color":[0.85,0.78,0.72,1],"ambient_energy":0.50,"fog_density":0.0015,"fog_color":[0.78,0.72,0.65,1],"sun_dir":[-0.4,-0.7,-0.4],"sun_color":[1.0,0.85,0.65,1],"sun_energy":1.2,"floor_color":[0.55,0.42,0.30,1],"wall_color":[0.40,0.30,0.20,1]},
    "open-courtyards":   {"sky_top":[0.55,0.65,0.80,1],"sky_horizon":[0.92,0.85,0.65,1],"ground_horizon":[0.55,0.50,0.35,1],"ground_bottom":[0.22,0.20,0.16,1],"ambient_color":[0.88,0.85,0.78,1],"ambient_energy":0.55,"fog_density":0.0012,"fog_color":[0.85,0.85,0.78,1],"sun_dir":[-0.4,-0.7,-0.3],"sun_color":[1.0,0.96,0.78,1],"sun_energy":1.3,"floor_color":[0.65,0.55,0.42,1],"wall_color":[0.45,0.36,0.26,1]},
    "derelict-carnival": {"sky_top":[0.45,0.40,0.60,1],"sky_horizon":[0.72,0.55,0.55,1],"ground_horizon":[0.45,0.35,0.32,1],"ground_bottom":[0.18,0.14,0.14,1],"ambient_color":[0.65,0.55,0.65,1],"ambient_energy":0.40,"fog_density":0.003,"fog_color":[0.55,0.45,0.55,1],"sun_dir":[-0.3,-0.6,-0.5],"sun_color":[0.85,0.65,0.65,1],"sun_energy":0.85,"floor_color":[0.45,0.35,0.30,1],"wall_color":[0.32,0.25,0.22,1]},
    "frontier-town":     {"sky_top":[0.50,0.60,0.75,1],"sky_horizon":[0.85,0.72,0.55,1],"ground_horizon":[0.55,0.45,0.30,1],"ground_bottom":[0.20,0.18,0.12,1],"ambient_color":[0.85,0.82,0.78,1],"ambient_energy":0.50,"fog_density":0.002,"fog_color":[0.78,0.75,0.65,1],"sun_dir":[-0.4,-0.7,-0.4],"sun_color":[1.0,0.92,0.72,1],"sun_energy":1.2,"floor_color":[0.55,0.45,0.30,1],"wall_color":[0.40,0.30,0.20,1]},
    "vast-archive":      {"sky_top":[0.25,0.22,0.30,1],"sky_horizon":[0.45,0.40,0.40,1],"ground_horizon":[0.32,0.28,0.30,1],"ground_bottom":[0.10,0.10,0.12,1],"ambient_color":[0.65,0.55,0.55,1],"ambient_energy":0.40,"fog_density":0.0025,"fog_color":[0.32,0.28,0.32,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.95,0.85,0.65,1],"sun_energy":0.85,"floor_color":[0.40,0.35,0.30,1],"wall_color":[0.28,0.25,0.22,1]},
    "lower-archive":     {"sky_top":[0.18,0.18,0.25,1],"sky_horizon":[0.32,0.28,0.30,1],"ground_horizon":[0.25,0.22,0.22,1],"ground_bottom":[0.08,0.08,0.10,1],"ambient_color":[0.55,0.50,0.55,1],"ambient_energy":0.35,"fog_density":0.004,"fog_color":[0.30,0.25,0.30,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.78,0.72,0.62,1],"sun_energy":0.6,"floor_color":[0.30,0.28,0.26,1],"wall_color":[0.22,0.20,0.20,1]},
    "alcove":            {"sky_top":[0.18,0.18,0.25,1],"sky_horizon":[0.32,0.28,0.30,1],"ground_horizon":[0.25,0.22,0.22,1],"ground_bottom":[0.08,0.08,0.10,1],"ambient_color":[0.55,0.50,0.55,1],"ambient_energy":0.35,"fog_density":0.003,"fog_color":[0.32,0.28,0.32,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.85,0.78,0.65,1],"sun_energy":0.65,"floor_color":[0.32,0.28,0.26,1],"wall_color":[0.22,0.20,0.20,1]},
    "labelled-shelves":  {"sky_top":[0.22,0.22,0.30,1],"sky_horizon":[0.40,0.38,0.40,1],"ground_horizon":[0.30,0.28,0.30,1],"ground_bottom":[0.10,0.10,0.10,1],"ambient_color":[0.65,0.62,0.58,1],"ambient_energy":0.45,"fog_density":0.002,"fog_color":[0.32,0.30,0.30,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.95,0.85,0.65,1],"sun_energy":0.85,"floor_color":[0.40,0.36,0.30,1],"wall_color":[0.30,0.26,0.22,1]},
    "running-scrolls":   {"sky_top":[0.20,0.22,0.28,1],"sky_horizon":[0.36,0.32,0.36,1],"ground_horizon":[0.28,0.26,0.26,1],"ground_bottom":[0.10,0.10,0.12,1],"ambient_color":[0.55,0.50,0.55,1],"ambient_energy":0.40,"fog_density":0.003,"fog_color":[0.32,0.30,0.34,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.85,0.78,0.62,1],"sun_energy":0.75,"floor_color":[0.36,0.32,0.28,1],"wall_color":[0.25,0.22,0.20,1]},
    "shallow-stream":    {"sky_top":[0.50,0.62,0.65,1],"sky_horizon":[0.78,0.78,0.70,1],"ground_horizon":[0.40,0.42,0.36,1],"ground_bottom":[0.16,0.18,0.16,1],"ambient_color":[0.65,0.72,0.68,1],"ambient_energy":0.42,"fog_density":0.005,"fog_color":[0.62,0.68,0.65,1],"sun_dir":[-0.4,-0.6,-0.5],"sun_color":[0.95,0.92,0.78,1],"sun_energy":1.0,"floor_color":[0.30,0.38,0.32,1],"wall_color":[0.22,0.26,0.22,1]},
    "industrial":        {"sky_top":[0.20,0.16,0.20,1],"sky_horizon":[0.45,0.30,0.25,1],"ground_horizon":[0.30,0.22,0.18,1],"ground_bottom":[0.10,0.08,0.06,1],"ambient_color":[0.55,0.40,0.40,1],"ambient_energy":0.40,"fog_density":0.005,"fog_color":[0.30,0.22,0.20,1],"sun_dir":[-0.5,-0.6,-0.4],"sun_color":[1.0,0.55,0.30,1],"sun_energy":0.85,"floor_color":[0.25,0.20,0.18,1],"wall_color":[0.18,0.14,0.12,1]},
    "black-doorway":     {"sky_top":[0.05,0.04,0.06,1],"sky_horizon":[0.12,0.10,0.12,1],"ground_horizon":[0.10,0.08,0.10,1],"ground_bottom":[0.04,0.04,0.05,1],"ambient_color":[0.30,0.28,0.32,1],"ambient_energy":0.30,"fog_density":0.012,"fog_color":[0.10,0.08,0.10,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.40,0.35,0.45,1],"sun_energy":0.4,"floor_color":[0.12,0.10,0.12,1],"wall_color":[0.06,0.05,0.06,1]},
    # ---- v2 expansion palettes ---------------------------------------
    "tool-workshop":     {"sky_top":[0.30,0.28,0.30,1],"sky_horizon":[0.55,0.45,0.35,1],"ground_horizon":[0.42,0.34,0.28,1],"ground_bottom":[0.16,0.14,0.12,1],"ambient_color":[0.78,0.68,0.55,1],"ambient_energy":0.45,"fog_density":0.002,"fog_color":[0.50,0.42,0.34,1],"sun_dir":[-0.4,-0.6,-0.4],"sun_color":[1.0,0.82,0.55,1],"sun_energy":1.0,"floor_color":[0.45,0.36,0.28,1],"wall_color":[0.32,0.26,0.20,1]},
    "loomhouse":         {"sky_top":[0.30,0.28,0.40,1],"sky_horizon":[0.65,0.55,0.55,1],"ground_horizon":[0.45,0.36,0.40,1],"ground_bottom":[0.18,0.14,0.18,1],"ambient_color":[0.75,0.65,0.72,1],"ambient_energy":0.45,"fog_density":0.0025,"fog_color":[0.55,0.45,0.55,1],"sun_dir":[-0.4,-0.7,-0.3],"sun_color":[0.95,0.78,0.85,1],"sun_energy":1.0,"floor_color":[0.42,0.32,0.36,1],"wall_color":[0.30,0.22,0.26,1]},
    "tower-study":       {"sky_top":[0.18,0.20,0.40,1],"sky_horizon":[0.40,0.38,0.55,1],"ground_horizon":[0.25,0.25,0.35,1],"ground_bottom":[0.10,0.10,0.16,1],"ambient_color":[0.55,0.60,0.78,1],"ambient_energy":0.40,"fog_density":0.003,"fog_color":[0.30,0.32,0.45,1],"sun_dir":[-0.3,-0.6,-0.5],"sun_color":[0.78,0.82,1.0,1],"sun_energy":0.85,"floor_color":[0.25,0.28,0.36,1],"wall_color":[0.18,0.20,0.28,1]},
    "burned-hold":       {"sky_top":[0.20,0.14,0.16,1],"sky_horizon":[0.42,0.22,0.18,1],"ground_horizon":[0.28,0.18,0.14,1],"ground_bottom":[0.10,0.06,0.05,1],"ambient_color":[0.55,0.40,0.36,1],"ambient_energy":0.40,"fog_density":0.005,"fog_color":[0.30,0.20,0.18,1],"sun_dir":[-0.5,-0.6,-0.4],"sun_color":[0.95,0.55,0.35,1],"sun_energy":0.85,"floor_color":[0.25,0.18,0.14,1],"wall_color":[0.16,0.12,0.10,1]},
    "heartworks":        {"sky_top":[0.10,0.18,0.30,1],"sky_horizon":[0.30,0.45,0.65,1],"ground_horizon":[0.20,0.30,0.42,1],"ground_bottom":[0.08,0.10,0.16,1],"ambient_color":[0.55,0.72,0.92,1],"ambient_energy":0.55,"fog_density":0.0035,"fog_color":[0.30,0.45,0.65,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.62,0.85,1.0,1],"sun_energy":1.0,"floor_color":[0.20,0.30,0.42,1],"wall_color":[0.14,0.20,0.30,1]},
    "quietness":         {"sky_top":[0.55,0.55,0.58,1],"sky_horizon":[0.75,0.75,0.75,1],"ground_horizon":[0.55,0.55,0.55,1],"ground_bottom":[0.30,0.30,0.30,1],"ambient_color":[0.85,0.85,0.85,1],"ambient_energy":0.50,"fog_density":0.001,"fog_color":[0.78,0.78,0.78,1],"sun_dir":[-0.4,-0.7,-0.3],"sun_color":[1.0,1.0,1.0,1],"sun_energy":1.1,"floor_color":[0.65,0.65,0.65,1],"wall_color":[0.50,0.50,0.50,1]},
    "wild-hum":          {"sky_top":[0.30,0.10,0.40,1],"sky_horizon":[0.65,0.25,0.55,1],"ground_horizon":[0.42,0.22,0.40,1],"ground_bottom":[0.16,0.08,0.18,1],"ambient_color":[0.75,0.55,0.85,1],"ambient_energy":0.50,"fog_density":0.004,"fog_color":[0.50,0.30,0.55,1],"sun_dir":[-0.4,-0.6,-0.5],"sun_color":[1.0,0.55,0.85,1],"sun_energy":1.0,"floor_color":[0.45,0.25,0.45,1],"wall_color":[0.28,0.16,0.30,1]},
    "speakers-room":     {"sky_top":[0.20,0.20,0.28,1],"sky_horizon":[0.40,0.38,0.42,1],"ground_horizon":[0.30,0.28,0.30,1],"ground_bottom":[0.12,0.10,0.12,1],"ambient_color":[0.62,0.62,0.68,1],"ambient_energy":0.42,"fog_density":0.002,"fog_color":[0.32,0.30,0.36,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.85,0.85,0.95,1],"sun_energy":0.9,"floor_color":[0.36,0.34,0.38,1],"wall_color":[0.24,0.22,0.26,1]},
    "recursion-hall":    {"sky_top":[0.10,0.12,0.18,1],"sky_horizon":[0.25,0.22,0.30,1],"ground_horizon":[0.18,0.16,0.22,1],"ground_bottom":[0.06,0.06,0.10,1],"ambient_color":[0.42,0.42,0.55,1],"ambient_energy":0.35,"fog_density":0.008,"fog_color":[0.18,0.16,0.22,1],"sun_dir":[-0.3,-0.7,-0.4],"sun_color":[0.55,0.55,0.78,1],"sun_energy":0.5,"floor_color":[0.20,0.18,0.24,1],"wall_color":[0.12,0.10,0.16,1]},
}


# ---- cells / load_zones / spawns ------------------------------------------

def cells_rect(rx_min: int, rz_min: int, rx_max: int, rz_max: int):
    return [[i, j] for i in range(rx_min, rx_max) for j in range(rz_min, rz_max)]


def make_level(entry, scope_size_overrides=None):
    """Build the JSON dict for one scaffold entry."""
    ent = entry
    palette = PALETTES[ent["theme"]]
    music = ent.get("music", ent["id"])

    # Cell footprint by scope.
    radii = {
        "passthrough": (6, 6),
        "hub":         (16, 16),
        "kingdom":     (28, 28),
    }
    rx, rz = radii[ent["scope"]]
    cells = cells_rect(-rx, -rz, rx, rz)

    # Spawns: default at south edge, plus from_<neighbour> for each
    # neighbour at the opposite edge from where they go. Simple
    # scheme — they all share the south spawn position; in a deeper
    # pass each neighbour can get its own marker.
    spawns = [{"id": "default",
               "pos": [0.0, 0.5, float(rz - 1)], "rotation_y": math.pi}]
    for nb_id, _ in ent["neighbours"]:
        spawns.append({"id": "from_" + nb_id,
                       "pos": [0.0, 0.5, float(rz - 1)],
                       "rotation_y": math.pi})

    # Load zones: place them spaced out around the central origin so a
    # passthrough or hub feels physical to walk through. Each neighbour
    # gets a slot on a circle of radius r.
    n = max(1, len(ent["neighbours"]))
    r = max(4.0, float(rx - 3))
    load_zones = []
    for i, (nb_id, prompt) in enumerate(ent["neighbours"]):
        angle = (-math.pi * 0.5) + (math.tau * i / n)  # start north
        zx = round(math.cos(angle) * r, 2)
        zz = round(math.sin(angle) * r, 2)
        # Determine size orientation: thin axis points outward.
        # Quick heuristic: thin on whichever axis has larger absolute.
        sx, sz = (1.5, 4.0) if abs(zx) > abs(zz) else (4.0, 1.5)
        load_zones.append({
            "pos": [zx, 1.4, zz],
            "size": [sx, 3.0, sz],
            "rotation_y": 0.0,
            "target_scene": nb_id,
            "target_spawn": "from_" + ent["id"],
            "prompt": prompt,
        })

    # One sign noting where they are.
    fs_path = next(
        (p for p in [ent.get("fs_path")] if p),
        None) or _fs_path_from_id(ent["id"])
    props = [{
        "type": "sign",
        "pos": [0.0, 0.0, float(rz - 4)],
        "rotation_y": math.pi,
        "message": "%s\n\n%s" % (ent["name"], fs_path or ""),
    }]

    return {
        "name": ent["name"],
        "id":   ent["id"],
        "key_group":   ent["id"],
        "music_track": music,
        "fs_path":     fs_path or "",
        "environment": {k: v for k, v in palette.items()
                        if k in ("sky_top", "sky_horizon",
                                 "ground_horizon", "ground_bottom",
                                 "ambient_color", "ambient_energy",
                                 "fog_density", "fog_color",
                                 "sun_dir", "sun_color", "sun_energy")},
        "grid": {
            "cell_size": 1.0,
            "floors": [{
                "y": 0.0,
                "name": "ground",
                "cells": cells,
                "wall_height": 4.0,
                "wall_color":  palette["wall_color"],
                "floor_color": palette["floor_color"],
                "wall_material": "tree" if ent["theme"] in (
                    "parkland", "stone-arch", "windy-plateau",
                    "overgrown-homestead") else "stone",
                "has_floor": True,
                "has_walls": True,
                "has_roof":  False,
            }],
        },
        "spawns": spawns,
        "lights": [],
        "enemies": [],
        "props": props,
        "load_zones": load_zones,
    }


def _fs_path_from_id(level_id: str) -> str:
    """Pull the canonical filesystem path from build_dungeon's PATH_MAP."""
    try:
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        from build_dungeon import PATH_MAP
        return PATH_MAP.get(level_id, "")
    except Exception:
        return ""


def main():
    targets = set(sys.argv[1:])
    force = False
    if "--force" in targets:
        force = True
        targets.discard("--force")
    for ent in SCAFFOLD:
        if targets and ent["id"] not in targets:
            continue
        path = os.path.join(DUNGEONS, ent["id"] + ".json")
        if os.path.exists(path) and not force:
            print("skip %-20s (exists; use --force)" % ent["id"])
            continue
        data = make_level(ent)
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        print("wrote %-20s -> %s (%d cells, %d neighbours)" % (
            ent["id"], data["fs_path"],
            sum(len(fl["cells"]) for fl in data["grid"]["floors"]),
            len(data["load_zones"])))


if __name__ == "__main__":
    main()
