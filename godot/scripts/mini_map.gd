extends Control

# Top-down mini-map widget. Renders the walking-cell footprint of the
# current scene as a translucent fill with stroked outer boundaries,
# plus the player as a triangle pointing in their facing direction.
# The player triangle is fixed at the widget's centre; world cells
# scroll under it as the player moves.
#
# Cells come from any TerrainMesh nodes in the scene (we read their
# `cell_data` and `cell_size` exports). For maps with many cells we
# only render those within RENDER_RADIUS_METERS of the player so we
# stay under the per-tick budget.
#
# This script is also reused by the Map tab of the pause menu — see
# `_render_world_meters` and `centered_on_player`. With
# `centered_on_player = false` the widget centres on the bounding box
# of all walking cells instead and ignores the radius cap.

const WIDGET_SIZE: Vector2 = Vector2(200, 200)

# How many world meters fit across the widget. With a default 2m cell,
# 60 m ≈ 30 cells across — enough to see your immediate surroundings
# without drowning in detail.
const VIEW_RADIUS_METERS: float = 30.0
# Rendering window when the player is on a huge map. Cells outside this
# radius are skipped so we don't blow the budget.
const RENDER_RADIUS_METERS: float = 30.0
const MAX_CELLS_PER_TICK: int = 600

const FILL_COLOR := Color(0.30, 0.85, 0.65, 0.45)
const EDGE_COLOR := Color(0.90, 0.95, 1.00, 0.80)
const BORDER_COLOR := Color(0, 0, 0, 1)
const BACKDROP_COLOR := Color(0.05, 0.06, 0.10, 0.55)
const PLAYER_COLOR := Color(1.00, 0.92, 0.40, 1.0)

# When false (used by the pause-menu Map tab) we centre on the level
# bounding box and render every cell at a custom zoom.
@export var centered_on_player: bool = true
@export var view_radius_meters: float = VIEW_RADIUS_METERS
@export var render_radius_meters: float = RENDER_RADIUS_METERS

var _player: Node3D = null
var _terrain_cache: Array = []        # [{cells: Dict<Vector2i,bool>, size: float}]
var _world_bbox_min: Vector2 = Vector2.ZERO
var _world_bbox_max: Vector2 = Vector2.ZERO


func _ready() -> void:
    custom_minimum_size = WIDGET_SIZE
    size = WIDGET_SIZE
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    _refresh_player()
    _rebuild_terrain_cache()


func _process(_delta: float) -> void:
    if _player == null or not is_instance_valid(_player):
        _refresh_player()
    if _terrain_cache.is_empty():
        _rebuild_terrain_cache()
    queue_redraw()


func _refresh_player() -> void:
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0 and ps[0] is Node3D:
        _player = ps[0]


func _rebuild_terrain_cache() -> void:
    _terrain_cache.clear()
    var root: Node = get_tree().current_scene
    if root == null:
        return
    var min_x: float = INF
    var min_z: float = INF
    var max_x: float = -INF
    var max_z: float = -INF
    var any: bool = false
    for tm in _find_terrain_meshes(root):
        var cells: Dictionary = {}
        var cs: float = float(tm.get("cell_size") if tm.get("cell_size") != null else 2.0)
        var raw: Array = tm.get("cell_data") if tm.get("cell_data") != null else []
        for c in raw:
            var i: int = 0
            var j: int = 0
            if c is Dictionary:
                i = int(c.get("i", 0))
                j = int(c.get("j", 0))
            else:
                i = int(c[0])
                j = int(c[1])
            cells[Vector2i(i, j)] = true
            var wx: float = float(i) * cs
            var wz: float = float(j) * cs
            if wx < min_x: min_x = wx
            if wz < min_z: min_z = wz
            if wx + cs > max_x: max_x = wx + cs
            if wz + cs > max_z: max_z = wz + cs
            any = true
        _terrain_cache.append({"cells": cells, "size": cs})
    if any:
        _world_bbox_min = Vector2(min_x, min_z)
        _world_bbox_max = Vector2(max_x, max_z)


func _find_terrain_meshes(root: Node) -> Array:
    var out: Array = []
    var stack: Array = [root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n == null:
            continue
        # Duck-type by checking for the `cell_data` property — avoids a
        # hard dependency on TerrainMesh's class_name resolving.
        var props: Array = n.get_property_list()
        var has_cell_data: bool = false
        for p in props:
            if p.name == "cell_data":
                has_cell_data = true
                break
        if has_cell_data:
            out.append(n)
        for child in n.get_children():
            stack.append(child)
    return out


func _draw() -> void:
    var rect := Rect2(Vector2.ZERO, size)
    draw_rect(rect, BACKDROP_COLOR, true)

    var px: float = 0.0
    var pz: float = 0.0
    var pyaw: float = 0.0
    if _player != null and is_instance_valid(_player):
        px = _player.global_position.x
        pz = _player.global_position.z
        pyaw = _player.rotation.y

    var view_radius: float = max(view_radius_meters, 1.0)
    var center_world: Vector2
    if centered_on_player:
        center_world = Vector2(px, pz)
    else:
        # Center on level bbox; size the view to fit it.
        if _world_bbox_max.x > _world_bbox_min.x:
            center_world = (_world_bbox_min + _world_bbox_max) * 0.5
            var half_w: float = (_world_bbox_max.x - _world_bbox_min.x) * 0.5
            var half_h: float = (_world_bbox_max.y - _world_bbox_min.y) * 0.5
            view_radius = max(half_w, half_h) + 2.0
        else:
            center_world = Vector2(px, pz)

    # World->widget transform: a square of side (2*view_radius) maps to
    # the widget's smaller dimension. Y in widget = -Z in world (so
    # north is up).
    var widget_min: float = min(size.x, size.y)
    var scale: float = widget_min / (2.0 * view_radius)

    var cells_drawn: int = 0
    for tm_entry in _terrain_cache:
        var cells: Dictionary = tm_entry.cells
        var cs: float = tm_entry.size
        var px_size: float = cs * scale
        # Skip cells outside the render window when player-centred and
        # the map is large.
        var skip_far: bool = centered_on_player and cells.size() > MAX_CELLS_PER_TICK
        var rr2: float = render_radius_meters * render_radius_meters

        for key in cells:
            var ci: int = key.x
            var cj: int = key.y
            var wx: float = (float(ci) + 0.5) * cs
            var wz: float = (float(cj) + 0.5) * cs
            if skip_far:
                var dx: float = wx - px
                var dz: float = wz - pz
                if dx * dx + dz * dz > rr2:
                    continue
            var p := _world_to_widget(Vector2(wx, wz), center_world, scale)
            var cell_rect := Rect2(p - Vector2(px_size * 0.5, px_size * 0.5),
                                   Vector2(px_size, px_size))
            draw_rect(cell_rect, FILL_COLOR, true)
            cells_drawn += 1

        # Boundary edges: cell edges with no walking neighbour.
        for key in cells:
            var ci2: int = key.x
            var cj2: int = key.y
            var wx2: float = float(ci2) * cs
            var wz2: float = float(cj2) * cs
            if skip_far:
                var ccx: float = wx2 + cs * 0.5
                var ccz: float = wz2 + cs * 0.5
                var ddx: float = ccx - px
                var ddz: float = ccz - pz
                if ddx * ddx + ddz * ddz > rr2:
                    continue
            var corners := {
                "nw": _world_to_widget(Vector2(wx2, wz2), center_world, scale),
                "ne": _world_to_widget(Vector2(wx2 + cs, wz2), center_world, scale),
                "sw": _world_to_widget(Vector2(wx2, wz2 + cs), center_world, scale),
                "se": _world_to_widget(Vector2(wx2 + cs, wz2 + cs), center_world, scale),
            }
            if not cells.has(Vector2i(ci2, cj2 - 1)):
                draw_line(corners.nw, corners.ne, EDGE_COLOR, 1.0)
            if not cells.has(Vector2i(ci2, cj2 + 1)):
                draw_line(corners.sw, corners.se, EDGE_COLOR, 1.0)
            if not cells.has(Vector2i(ci2 - 1, cj2)):
                draw_line(corners.nw, corners.sw, EDGE_COLOR, 1.0)
            if not cells.has(Vector2i(ci2 + 1, cj2)):
                draw_line(corners.ne, corners.se, EDGE_COLOR, 1.0)

    # Player triangle in the centre, pointing in facing direction.
    var center := size * 0.5
    if not centered_on_player and _player != null:
        center = _world_to_widget(Vector2(px, pz), center_world, scale)
    _draw_player_triangle(center, pyaw)

    # Black border last so it sits on top of everything.
    draw_rect(rect, BORDER_COLOR, false, 2.0)


func _world_to_widget(world_xz: Vector2, center_world: Vector2,
                      scale: float) -> Vector2:
    var dx: float = world_xz.x - center_world.x
    var dz: float = world_xz.y - center_world.y
    # Widget X = world X; widget Y = -world Z so north (-Z) appears up.
    return size * 0.5 + Vector2(dx, dz) * scale


func _draw_player_triangle(at: Vector2, yaw: float) -> void:
    # Tux's "forward" in world space is -Z when yaw=0 (facing north).
    # That should map to "up" on the widget (-Y in widget space). Yaw
    # rotates around +Y in 3D, which in our top-down view rotates
    # clockwise as yaw increases. Flip the angle so a positive yaw
    # turns the triangle the same way the camera turns.
    var angle: float = -yaw
    var tip := Vector2(0, -8).rotated(angle)
    var bl  := Vector2(-6, 6).rotated(angle)
    var br  := Vector2(6, 6).rotated(angle)
    var pts := PackedVector2Array([at + tip, at + bl, at + br])
    draw_colored_polygon(pts, PLAYER_COLOR)
    draw_polyline(PackedVector2Array([at + tip, at + bl, at + br, at + tip]),
                  Color(0, 0, 0, 1), 1.0)
