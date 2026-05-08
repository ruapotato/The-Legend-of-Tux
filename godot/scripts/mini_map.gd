extends Control

# Top-down mini-map. Pre-renders the entire walking-cell footprint of
# the current scene to an Image once on _ready, stores it as an
# ImageTexture, and then every frame just blits the texture + draws a
# player-position triangle on top. That way even sourceplain (20k+
# cells) pays the per-cell cost exactly once instead of every frame.
#
# Always shows the WHOLE level (the user wants the full loaded area
# visible, not a window around the player). The player triangle moves
# inside the map rather than the map scrolling under a fixed cursor.
#
# Reused by the pause menu's Map tab via a larger widget_size override.

const WIDGET_SIZE: Vector2 = Vector2(220, 220)

const FILL_COLOR     := Color(0.30, 0.85, 0.65, 0.70)
const HIGH_COLOR     := Color(0.60, 0.95, 0.80, 0.80)
const LOW_COLOR      := Color(0.10, 0.45, 0.40, 0.70)
const BORDER_COLOR   := Color(0, 0, 0, 1)
const BACKDROP_COLOR := Color(0.05, 0.06, 0.10, 0.65)
const PLAYER_COLOR   := Color(1.00, 0.92, 0.40, 1.0)

@export var widget_size: Vector2 = WIDGET_SIZE
# Backwards-compat with pause-menu callers that flipped this; both
# modes now show the whole level, so the flag is effectively unused.
@export var centered_on_player: bool = false

var _player: Node3D = null
var _texture: ImageTexture = null
var _bbox_min: Vector2 = Vector2.ZERO
var _bbox_max: Vector2 = Vector2.ZERO
var _scale: float = 1.0          # px per world meter
var _origin_offset: Vector2 = Vector2.ZERO


func _ready() -> void:
    custom_minimum_size = widget_size
    size = widget_size
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    clip_contents = true   # clip rotation overflow to widget bounds
    _refresh_player()
    # Defer one frame so any TerrainMesh nodes have finished _ready().
    call_deferred("_rebuild_texture")


# Map is fixed — north (world -Z) is always up. The player triangle
# rotates with player facing so you can orient yourself by looking at
# the marker direction. Standard OoT-style.


func _process(_delta: float) -> void:
    if _player == null or not is_instance_valid(_player):
        _refresh_player()
    queue_redraw()


func _refresh_player() -> void:
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0 and ps[0] is Node3D:
        _player = ps[0]


func _rebuild_texture() -> void:
    var root: Node = get_tree().current_scene
    if root == null:
        return
    var entries: Array = []     # [{cells: dict<Vector2i,float>, size: float}]
    var min_x: float =  INF
    var min_z: float =  INF
    var max_x: float = -INF
    var max_z: float = -INF
    var any: bool = false
    for tm in _find_terrain_meshes(root):
        var cs: float = float(tm.get("cell_size") if tm.get("cell_size") != null else 1.0)
        var raw: Array = tm.get("cell_data") if tm.get("cell_data") != null else []
        var cells: Dictionary = {}
        for c in raw:
            var i: int = 0; var j: int = 0; var y_off: float = 0.0
            if c is Dictionary:
                i = int(c.get("i", 0)); j = int(c.get("j", 0))
                if c.has("y"): y_off = float(c["y"])
            else:
                i = int(c[0]); j = int(c[1])
                if c.size() >= 3 and c[2] != null:
                    y_off = float(c[2])
            cells[Vector2i(i, j)] = y_off
            var wx: float = float(i) * cs
            var wz: float = float(j) * cs
            if wx < min_x: min_x = wx
            if wz < min_z: min_z = wz
            if wx + cs > max_x: max_x = wx + cs
            if wz + cs > max_z: max_z = wz + cs
            any = true
        entries.append({"cells": cells, "size": cs})
    if not any:
        return

    # Pad bbox so the outer cells aren't flush against the widget edge.
    var pad: float = 2.0
    min_x -= pad; min_z -= pad; max_x += pad; max_z += pad
    _bbox_min = Vector2(min_x, min_z)
    _bbox_max = Vector2(max_x, max_z)

    var w_world: float = max_x - min_x
    var h_world: float = max_z - min_z
    _scale = min((widget_size.x - 8.0) / w_world,
                 (widget_size.y - 8.0) / h_world)
    _origin_offset = Vector2(
        (widget_size.x - w_world * _scale) * 0.5,
        (widget_size.y - h_world * _scale) * 0.5)

    var img_w: int = int(widget_size.x)
    var img_h: int = int(widget_size.y)
    var img := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
    img.fill(Color(0, 0, 0, 0))

    for entry in entries:
        var cs: float = entry.size
        var cells_dict: Dictionary = entry.cells
        for k in cells_dict:
            var y_off: float = cells_dict[k]
            var wx: float = float(k.x) * cs
            var wz: float = float(k.y) * cs
            var px0: int = int(_origin_offset.x + (wx - min_x) * _scale)
            var py0: int = int(_origin_offset.y + (wz - min_z) * _scale)
            var px1: int = max(px0 + 1,
                int(_origin_offset.x + (wx + cs - min_x) * _scale))
            var py1: int = max(py0 + 1,
                int(_origin_offset.y + (wz + cs - min_z) * _scale))
            # Tint by elevation so hills/valleys read on the map.
            var col: Color = FILL_COLOR
            if y_off > 0.4:
                col = HIGH_COLOR
            elif y_off < -0.3:
                col = LOW_COLOR
            var rw: int = max(1, px1 - px0)
            var rh: int = max(1, py1 - py0)
            img.fill_rect(
                Rect2i(clamp(px0, 0, img_w - 1),
                       clamp(py0, 0, img_h - 1),
                       max(1, min(rw, img_w - px0)),
                       max(1, min(rh, img_h - py0))),
                col)

    _texture = ImageTexture.create_from_image(img)


func _draw() -> void:
    var rect := Rect2(Vector2.ZERO, size)
    draw_rect(rect, BACKDROP_COLOR)
    if _texture:
        draw_texture(_texture, Vector2.ZERO)
    if _player and is_instance_valid(_player):
        var pp: Vector3 = _player.global_position
        var px: float = _origin_offset.x + (pp.x - _bbox_min.x) * _scale
        var py: float = _origin_offset.y + (pp.z - _bbox_min.y) * _scale
        # Player facing forward at rotation.y=0 points world -Z (north)
        # which is UP on the screen-Y-down map. Pass +rotation.y so
        # the triangle's `fwd = (-sin yaw, -cos yaw)` lands on the
        # right direction (verified against the four cardinals).
        _draw_player_triangle(Vector2(px, py), _player.rotation.y)
    draw_rect(rect, BORDER_COLOR, false, 2.0)


func _draw_player_triangle(at: Vector2, yaw: float) -> void:
    var fwd := Vector2(-sin(yaw), -cos(yaw))
    var right := Vector2(fwd.y, -fwd.x)
    var tip := at + fwd * 8.0
    var l   := at - fwd * 5.0 + right * 5.0
    var r   := at - fwd * 5.0 - right * 5.0
    draw_colored_polygon(PackedVector2Array([tip, l, r]), PLAYER_COLOR)
    draw_polyline(PackedVector2Array([tip, l, r, tip]),
                  PLAYER_COLOR.darkened(0.4), 1.5)


func _find_terrain_meshes(root: Node) -> Array:
    var out: Array = []
    var stack: Array = [root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n == null:
            continue
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
