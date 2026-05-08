#!/usr/bin/env python3
"""Migrate dungeons/*.json from the legacy floor-rect/rooms/doorways
schema to the new editor-native grid-cell format.

For each level:
  - If `rooms` are present (indoor levels), the union of all room rects
    is converted to a cell set. Walls auto-derive at the perimeter.
  - If only `floor.rect` is present (outdoor levels), the floor rect is
    converted to a cell set. has_walls is set to false so the existing
    `tree_walls` polylines remain the visual boundary.
  - Legacy `floor`, `rooms`, `doorways` fields are dropped.
  - `tree_walls` is kept on outdoor levels (for tree visuals); dropped
    on indoor levels.

Run from the repo root:
    python3 tools/migrate_to_grid.py
"""

import json
import math
import os
import sys

ROOT          = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS_DIR  = os.path.join(ROOT, "dungeons")
CELL_SIZE     = 2.0
DEFAULT_FLOOR = [0.30, 0.50, 0.30, 1.0]
DEFAULT_WALL  = [0.45, 0.45, 0.45, 1.0]


def cells_in_rect(rect):
    """Yield (i, j) cell indices that fully tile rect, with cell size
    CELL_SIZE. Cells are aligned to the world grid so adjacent levels
    using the same cell size land on consistent indices."""
    x_min, z_min, x_max, z_max = rect
    # Use ceil for the lower bound and floor for the upper bound so we
    # only emit cells that fully fit inside the rect — `round` was using
    # banker's rounding and over-shooting odd-boundary levels.
    i_lo = int(math.ceil(x_min / CELL_SIZE))
    i_hi = int(math.floor(x_max / CELL_SIZE))
    j_lo = int(math.ceil(z_min / CELL_SIZE))
    j_hi = int(math.floor(z_max / CELL_SIZE))
    for i in range(i_lo, i_hi):
        for j in range(j_lo, j_hi):
            yield (i, j)


def doorways_to_doors(rooms, doorways):
    """Convert legacy doorway-with-door entries into the new top-level
    `doors` schema. The wall_extension is sized so the flanking wall
    fills the room from the door to each room edge — preserving the
    visual partition that legacy `rooms` provided."""
    out = []
    if not doorways:
        return out
    by_id = {r.get("id"): r for r in rooms}
    for dw in doorways:
        door = dw.get("door")
        if not door:
            continue
        kind = door.get("type", "open")
        if kind == "open":
            continue
        x = float(dw.get("x", 0.0))
        z = float(dw.get("z", 0.0))
        width = float(dw.get("width", 3.0))
        # Figure out wall_extension from the room rect that contains the
        # door. Doors between rooms run along the shared edge — we use
        # whichever of the door's room IDs has its rect crossing the
        # door, and extend to the room's bounds along the perpendicular.
        ext = 0.0
        room_ids = dw.get("rooms", [])
        if room_ids:
            r = by_id.get(room_ids[0])
            if r and "rect" in r:
                x_min, z_min, x_max, z_max = r["rect"]
                # Door at z = boundary between rooms (axis-aligned).
                # Walls extend along X if door is on a horizontal edge.
                if abs(z - z_min) < 0.5 or abs(z - z_max) < 0.5:
                    ext = max(0.0, ((x_max - x_min) - width) / 2.0)
                else:
                    ext = max(0.0, ((z_max - z_min) - width) / 2.0)
        out.append({
            "pos": [x, 0.0, z],
            "rotation_y": 0.0,
            "type": "locked" if kind == "locked" else "unlocked",
            "door_width": width,
            "wall_extension": ext,
            "wall_height": 4.0,
            "wall_color": [0.42, 0.38, 0.32, 1.0],
            "locked_message": door.get(
                "locked_message",
                "Locked. A small key would open this door."),
            "unlock_message": door.get(
                "unlock_message",
                "The lock turns. The door opens."),
        })
    return out


def migrate(data):
    if "grid" in data:
        return False, "already grid"

    rooms = data.get("rooms", [])
    floor = data.get("floor")
    if not rooms and not floor:
        return False, "no floor or rooms"

    seen = set()
    cells = []
    if rooms:
        wall_color  = DEFAULT_WALL
        floor_color = DEFAULT_FLOOR
        wall_height = 4.0
        for room in rooms:
            if "rect" not in room:
                continue
            for (i, j) in cells_in_rect(room["rect"]):
                if (i, j) in seen:
                    continue
                seen.add((i, j))
                cells.append([i, j])
            if "wall_color" in room:
                wall_color = room["wall_color"]
            if "wall_height" in room:
                wall_height = float(room["wall_height"])
        if floor and isinstance(floor, dict) and "color" in floor:
            floor_color = floor["color"]
        has_walls = True
    else:
        for (i, j) in cells_in_rect(floor["rect"]):
            cells.append([i, j])
        floor_color = floor.get("color", DEFAULT_FLOOR)
        wall_color  = DEFAULT_WALL
        wall_height = 4.0
        has_walls   = False

    grid_floor = {
        "y":             float(floor["y"]) if (floor and "y" in floor) else 0.0,
        "name":          "ground",
        "cells":         cells,
        "wall_height":   wall_height,
        "wall_color":    wall_color,
        "floor_color":   floor_color,
        "wall_material": "stone",
        "has_floor":     True,
        "has_walls":     has_walls,
        "has_roof":      False,
    }

    # Convert legacy doorways-with-doors into top-level doors entries.
    converted_doors = doorways_to_doors(rooms, data.get("doorways", []))

    # Insert "grid" near the top of the dict for readability.
    new_data = {}
    for key in ("name", "id", "environment"):
        if key in data:
            new_data[key] = data[key]
    new_data["grid"] = {"cell_size": CELL_SIZE, "floors": [grid_floor]}
    if converted_doors:
        new_data["doors"] = converted_doors
    for key, value in data.items():
        if key in new_data:
            continue
        if key in ("floor", "rooms", "doorways"):
            continue
        if key == "tree_walls" and has_walls:
            # Indoor migration drops legacy tree fences entirely.
            continue
        new_data[key] = value

    data.clear()
    data.update(new_data)
    return True, "%d cells (%s)" % (len(cells), "indoor" if has_walls else "outdoor")


def main():
    paths = sorted(
        os.path.join(DUNGEONS_DIR, f) for f in os.listdir(DUNGEONS_DIR)
        if f.endswith(".json")
    )
    if len(sys.argv) > 1:
        wanted = set(sys.argv[1:])
        paths = [p for p in paths if os.path.basename(p).rsplit(".", 1)[0] in wanted
                 or os.path.basename(p) in wanted]

    for p in paths:
        with open(p) as f:
            data = json.load(f)
        changed, info = migrate(data)
        if changed:
            with open(p, "w") as f:
                json.dump(data, f, indent=2)
            print("migrated %s — %s" % (os.path.basename(p), info))
        else:
            print("skipped  %s — %s" % (os.path.basename(p), info))


if __name__ == "__main__":
    main()
