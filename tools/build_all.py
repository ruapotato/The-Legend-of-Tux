#!/usr/bin/env python3
"""Top-level build dispatcher.

Walks every level id in `dungeons/*.json` and `blueprints/*.json` and
emits a single `godot/scenes/<id>.tscn` for each. When BOTH a
`blueprints/<id>.json` and a `dungeons/<id>.json` exist, the blueprint
wins (the new pipeline replaces the old cell-based one).

This keeps the 92 cell-based legacy levels building cleanly while the
3 (or N) new blueprint-built levels override their old JSONs without
the old JSON needing to be deleted.

Run:
    python3 tools/build_all.py                # build every level
    python3 tools/build_all.py wyrdkin_glade  # build a subset by id
"""
import os
import sys
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS   = os.path.join(ROOT, "dungeons")
BLUEPRINTS = os.path.join(ROOT, "blueprints")


def list_ids(dirpath):
    if not os.path.isdir(dirpath):
        return set()
    return {f.rsplit(".", 1)[0]
            for f in os.listdir(dirpath) if f.endswith(".json")}


def main():
    blueprint_ids = list_ids(BLUEPRINTS)
    dungeon_ids   = list_ids(DUNGEONS)

    requested = sys.argv[1:]
    if requested:
        # Normalise to bare ids.
        requested = [r.rsplit(".", 1)[0] if r.endswith(".json")
                     else os.path.basename(r)
                     for r in requested]
    else:
        requested = sorted(blueprint_ids | dungeon_ids)

    # Bucket: which converter handles each id.
    use_blueprint = [r for r in requested if r in blueprint_ids]
    use_dungeon   = [r for r in requested
                     if r not in blueprint_ids and r in dungeon_ids]
    missing       = [r for r in requested
                     if r not in blueprint_ids and r not in dungeon_ids]
    for m in missing:
        print(f"WARN: no blueprint or dungeon JSON for '{m}'", file=sys.stderr)

    py = sys.executable

    if use_blueprint:
        print(f"==> blueprint pipeline: {len(use_blueprint)} level(s)")
        cmd = [py, os.path.join(ROOT, "tools", "build_from_blueprint.py")] + use_blueprint
        rc = subprocess.call(cmd)
        if rc != 0:
            return rc

    if use_dungeon:
        print(f"==> dungeon pipeline: {len(use_dungeon)} level(s)")
        cmd = [py, os.path.join(ROOT, "tools", "build_dungeon.py")] + use_dungeon
        rc = subprocess.call(cmd)
        if rc != 0:
            return rc

    return 0


if __name__ == "__main__":
    sys.exit(main())
