extends Control
class_name EditorCanvas

# Top-down, grid-cell-based level editor canvas. The user paints cells
# in/out of the current floor's cell set; walls auto-derive from cell-
# perimeter edges (any cell edge with no neighbor in the same floor is
# rendered as a wall). Multi-floor: floors at different Y stack and the
# inactive ones render as faded outlines so you can author over them.
#
# The canvas only draws and emits intent — all level data mutation lives
# in editor.gd, so undo can wrap the editor's mutation entry points.

signal canvas_click(world: Vector2, button: int, shift: bool, ctrl: bool)
signal canvas_drag(world: Vector2, delta: Vector2)
signal canvas_release(world: Vector2, button: int)
signal canvas_hover(world: Vector2)

var editor: Node = null

var pixels_per_meter: float = 22.0
var pan: Vector2 = Vector2(640, 360)

var _drag_pan: bool = false
var _drag_item: bool = false
var _last_world: Vector2 = Vector2.ZERO

const BG_COLOR        := Color(0.10, 0.11, 0.14)
const GRID_MINOR      := Color(0.18, 0.20, 0.26)
const GRID_MAJOR      := Color(0.30, 0.33, 0.40)
const AXIS_X          := Color(0.85, 0.30, 0.30)
const AXIS_Z          := Color(0.30, 0.45, 0.85)

const LEGACY_FLOOR    := Color(0.25, 0.45, 0.30, 0.30)
const LEGACY_ROOM     := Color(0.55, 0.60, 0.78, 0.85)
const LEGACY_DOORWAY_OPEN   := Color(0.40, 0.85, 0.95, 0.85)
const LEGACY_DOORWAY_DOOR   := Color(0.95, 0.65, 0.20, 0.85)
const LEGACY_TREEWALL := Color(0.18, 0.42, 0.22)

const SPAWN_COLOR     := Color(0.30, 1.00, 0.45)
const LIGHT_COLOR     := Color(1.00, 0.86, 0.55)
const SIGN_COLOR      := Color(0.65, 0.45, 0.20)
const CHEST_COLOR     := Color(0.85, 0.65, 0.20)
const LOAD_ZONE_COLOR := Color(0.55, 0.30, 0.85, 0.55)
const DOOR_LOCKED_COL := Color(0.95, 0.55, 0.20)
const DOOR_UNLOCK_COL := Color(0.95, 0.85, 0.40)
const DOOR_WALL_EXT   := Color(0.50, 0.42, 0.32, 0.85)
const ENEMY_COLOR := {
    "blob":   Color(0.30, 0.85, 0.40),
    "bat":    Color(0.85, 0.40, 0.85),
    "knight": Color(0.92, 0.85, 0.65),
}

const TOOL_PREVIEW    := Color(1.00, 0.90, 0.30, 0.45)
const PAINT_HOVER     := Color(0.40, 0.90, 0.40, 0.30)
const ERASE_HOVER     := Color(0.95, 0.35, 0.35, 0.30)

var _hover_world: Vector2 = Vector2.ZERO


func _ready() -> void:
    focus_mode = Control.FOCUS_ALL
    mouse_filter = Control.MOUSE_FILTER_STOP
    clip_contents = true


# ---- coord helpers -----------------------------------------------------

func world_to_canvas(p: Vector2) -> Vector2:
    return p * pixels_per_meter + pan


func canvas_to_world(p: Vector2) -> Vector2:
    return (p - pan) / pixels_per_meter


func cell_size() -> float:
    if editor and editor.level.has("grid"):
        return float(editor.level.grid.get("cell_size", 2.0))
    return 2.0


func world_to_cell(p: Vector2) -> Vector2i:
    var cs: float = cell_size()
    return Vector2i(int(floor(p.x / cs)), int(floor(p.y / cs)))


func cell_world_origin(cell: Vector2i) -> Vector2:
    var cs: float = cell_size()
    return Vector2(float(cell.x) * cs, float(cell.y) * cs)


func cell_world_rect(cell: Vector2i) -> Rect2:
    var cs: float = cell_size()
    return Rect2(cell_world_origin(cell), Vector2(cs, cs))


func cell_canvas_rect(cell: Vector2i) -> Rect2:
    var wr: Rect2 = cell_world_rect(cell)
    var p0: Vector2 = world_to_canvas(wr.position)
    var p1: Vector2 = world_to_canvas(wr.position + wr.size)
    return Rect2(p0, p1 - p0)


# ---- input -------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        var mb := event as InputEventMouseButton
        var world := canvas_to_world(mb.position)
        if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
            _zoom_at(mb.position, 1.15); return
        if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
            _zoom_at(mb.position, 1.0 / 1.15); return
        if mb.button_index == MOUSE_BUTTON_MIDDLE:
            _drag_pan = mb.pressed; return
        if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
            if mb.pressed:
                _drag_item = true
                _last_world = world
                canvas_click.emit(world, mb.button_index,
                                  mb.shift_pressed, mb.ctrl_pressed)
            else:
                if _drag_item:
                    _drag_item = false
                    canvas_release.emit(world, mb.button_index)
            accept_event()
        return
    if event is InputEventMouseMotion:
        var mm := event as InputEventMouseMotion
        var world := canvas_to_world(mm.position)
        _hover_world = world
        if _drag_pan:
            pan += mm.relative
            queue_redraw()
        elif _drag_item:
            var dw := world - _last_world
            _last_world = world
            canvas_drag.emit(world, dw)
        else:
            canvas_hover.emit(world)
        queue_redraw()


func _zoom_at(screen_p: Vector2, factor: float) -> void:
    var w_before := canvas_to_world(screen_p)
    pixels_per_meter = clamp(pixels_per_meter * factor, 4.0, 80.0)
    var w_after := canvas_to_world(screen_p)
    pan += (w_after - w_before) * pixels_per_meter
    queue_redraw()


# ---- top-level draw ----------------------------------------------------

func _draw() -> void:
    draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
    _draw_grid()
    _draw_axes()
    if editor == null or editor.level.is_empty():
        return
    var L: Dictionary = editor.level
    _draw_legacy(L)
    _draw_other_floors(L)
    _draw_current_floor(L)
    _draw_load_zones(L)
    _draw_doors(L)
    _draw_lights(L)
    _draw_enemies(L)
    _draw_props(L)
    _draw_spawns(L)
    _draw_selection()
    _draw_tool_hover()


# ---- grid + axes -------------------------------------------------------

func _draw_grid() -> void:
    # Render in world units (meters). Cells underneath are cell_size * meter.
    var cs: float = cell_size()
    if pixels_per_meter * cs < 6.0:
        return
    var tl: Vector2 = canvas_to_world(Vector2.ZERO)
    var br: Vector2 = canvas_to_world(size)
    var x0: int = int(floor(tl.x))
    var x1: int = int(ceil(br.x))
    var z0: int = int(floor(tl.y))
    var z1: int = int(ceil(br.y))
    for x in range(x0, x1 + 1):
        var p0: Vector2 = world_to_canvas(Vector2(float(x), tl.y))
        var p1: Vector2 = world_to_canvas(Vector2(float(x), br.y))
        var col: Color = GRID_MAJOR if (x % 5 == 0) else GRID_MINOR
        draw_line(p0, p1, col, 1.0)
    for z in range(z0, z1 + 1):
        var q0: Vector2 = world_to_canvas(Vector2(tl.x, float(z)))
        var q1: Vector2 = world_to_canvas(Vector2(br.x, float(z)))
        var col: Color = GRID_MAJOR if (z % 5 == 0) else GRID_MINOR
        draw_line(q0, q1, col, 1.0)


func _draw_axes() -> void:
    var origin: Vector2 = world_to_canvas(Vector2.ZERO)
    draw_line(origin, world_to_canvas(Vector2(3, 0)), AXIS_X, 2.0)
    draw_line(origin, world_to_canvas(Vector2(0, 3)), AXIS_Z, 2.0)


# ---- legacy field rendering -------------------------------------------

func _rect_canvas(rect: Array) -> Rect2:
    var p0: Vector2 = world_to_canvas(Vector2(rect[0], rect[1]))
    var p1: Vector2 = world_to_canvas(Vector2(rect[2], rect[3]))
    return Rect2(p0, p1 - p0)


func _draw_legacy(L: Dictionary) -> void:
    var f = L.get("floor")
    if f and f.has("rect"):
        var col: Color = LEGACY_FLOOR
        if f.has("color") and f.color is Array and f.color.size() >= 3:
            col = Color(f.color[0], f.color[1], f.color[2], 0.30)
        draw_rect(_rect_canvas(f.rect), col)
    for r in L.get("rooms", []):
        if r.has("rect"):
            draw_rect(_rect_canvas(r.rect), LEGACY_ROOM, false, 2.0)
    for dw in L.get("doorways", []):
        if dw.has("x") and dw.has("z"):
            var p: Vector2 = world_to_canvas(Vector2(dw.x, dw.z))
            var w: float = float(dw.get("width", 2.0)) * pixels_per_meter
            var has_door = dw.get("door") != null
            var col: Color = LEGACY_DOORWAY_DOOR if has_door else LEGACY_DOORWAY_OPEN
            draw_rect(Rect2(p - Vector2(w / 2.0, 4), Vector2(w, 8)), col)
    for tw in L.get("tree_walls", []):
        var pts: Array = []
        for p in tw.get("boundary", []):
            pts.append(world_to_canvas(Vector2(p[0], p[1])))
        var closed: bool = tw.get("closed", true)
        var loop: int = pts.size() if closed else (pts.size() - 1)
        if pts.size() < 2: continue
        for i in range(loop):
            var a: Vector2 = pts[i]
            var b: Vector2 = pts[(i + 1) % pts.size()]
            draw_line(a, b, LEGACY_TREEWALL, 3.0)


# ---- floor / cell rendering -------------------------------------------

func _make_cell_set(floor: Dictionary) -> Dictionary:
    var s: Dictionary = {}
    for c in floor.get("cells", []):
        var ci: int; var cj: int
        var data = null
        if c is Dictionary:
            ci = int(c.get("i", 0)); cj = int(c.get("j", 0)); data = c
        else:
            ci = int(c[0]); cj = int(c[1]); data = c
        s[Vector2i(ci, cj)] = data
    return s


func _cell_override_color(cell_data) -> Color:
    # Pull a [r,g,b,a] override out of either array or object cell forms.
    # Returns Color with a == 0 if no override.
    if cell_data is Array and cell_data.size() >= 4:
        var arr = cell_data[3]
        if arr is Array and arr.size() >= 3:
            return Color(arr[0], arr[1], arr[2], min(float(arr[3]) if arr.size() >= 4 else 1.0, 1.0))
    elif cell_data is Dictionary and cell_data.has("color"):
        var arr = cell_data.color
        if arr is Array and arr.size() >= 3:
            return Color(arr[0], arr[1], arr[2], min(float(arr[3]) if arr.size() >= 4 else 1.0, 1.0))
    return Color(0, 0, 0, 0)


func _cell_y_offset(cell_data) -> float:
    if cell_data is Array and cell_data.size() >= 3 and cell_data[2] != null:
        return float(cell_data[2])
    if cell_data is Dictionary and cell_data.has("y"):
        return float(cell_data["y"])
    return 0.0


func _draw_other_floors(L: Dictionary) -> void:
    var grid = L.get("grid")
    if grid == null: return
    var current_idx: int = editor.current_floor_idx
    var floors: Array = grid.get("floors", [])
    for i in range(floors.size()):
        if i == current_idx: continue
        var f: Dictionary = floors[i]
        var col: Color = _floor_color(f)
        col.a = 0.10
        for c in f.get("cells", []):
            var rc: Rect2 = cell_canvas_rect(Vector2i(int(c[0]), int(c[1])))
            draw_rect(rc, col)
            draw_rect(rc, Color(col.r, col.g, col.b, 0.40), false, 1.0)


func _draw_current_floor(L: Dictionary) -> void:
    var grid = L.get("grid")
    if grid == null: return
    var floors: Array = grid.get("floors", [])
    if editor.current_floor_idx < 0 or editor.current_floor_idx >= floors.size():
        return
    var f: Dictionary = floors[editor.current_floor_idx]
    var floor_col: Color = _floor_color(f)
    var wall_col: Color = _wall_color(f)
    var cell_set: Dictionary = _make_cell_set(f)
    var cs: float = cell_size()

    # Filled cells. Per-cell color override beats the floor default;
    # per-cell elevation is hinted by darkening / brightening the tile.
    var font := get_theme_default_font()
    for key in cell_set.keys():
        var rc: Rect2 = cell_canvas_rect(key)
        var data = cell_set[key]
        var override: Color = _cell_override_color(data)
        var col: Color = floor_col
        if override.a > 0.0:
            col = Color(override.r, override.g, override.b, 0.85)
        var dy: float = _cell_y_offset(data)
        if abs(dy) > 0.001:
            # Lighten for raised cells, darken for lowered — gives the
            # canvas a quick height cue without going full isometric.
            var shade: float = clamp(dy * 0.06, -0.4, 0.4)
            col = col.lightened(shade) if shade >= 0 else col.darkened(-shade)
        draw_rect(rc, col)
        if abs(dy) > 0.001 and pixels_per_meter * cell_size() > 18:
            draw_string(font, rc.position + Vector2(2, 11),
                        ("+%.1f" % dy) if dy > 0 else ("%.1f" % dy),
                        HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.7))

    # Walls along edges with no cell neighbor.
    for key in cell_set.keys():
        var ci: Vector2i = key
        var x0: float = float(ci.x) * cs
        var z0: float = float(ci.y) * cs
        var x1: float = x0 + cs
        var z1: float = z0 + cs
        if not cell_set.has(ci + Vector2i(1, 0)):
            draw_line(world_to_canvas(Vector2(x1, z0)),
                      world_to_canvas(Vector2(x1, z1)), wall_col, 3.0)
        if not cell_set.has(ci + Vector2i(-1, 0)):
            draw_line(world_to_canvas(Vector2(x0, z0)),
                      world_to_canvas(Vector2(x0, z1)), wall_col, 3.0)
        if not cell_set.has(ci + Vector2i(0, 1)):
            draw_line(world_to_canvas(Vector2(x0, z1)),
                      world_to_canvas(Vector2(x1, z1)), wall_col, 3.0)
        if not cell_set.has(ci + Vector2i(0, -1)):
            draw_line(world_to_canvas(Vector2(x0, z0)),
                      world_to_canvas(Vector2(x1, z0)), wall_col, 3.0)


func _floor_color(f: Dictionary) -> Color:
    var arr = f.get("floor_color", [0.30, 0.50, 0.30, 1.0])
    if arr is Array and arr.size() >= 3:
        return Color(arr[0], arr[1], arr[2], 0.55)
    return Color(0.30, 0.50, 0.30, 0.55)


func _wall_color(f: Dictionary) -> Color:
    var arr = f.get("wall_color", [0.55, 0.55, 0.55, 1.0])
    if arr is Array and arr.size() >= 3:
        return Color(arr[0], arr[1], arr[2], 1.0)
    return Color(0.55, 0.55, 0.55, 1.0)


# ---- entity rendering --------------------------------------------------

func _entity_alpha_for_y(world_y: float) -> float:
    if editor == null: return 1.0
    var current_y: float = editor.current_floor_y()
    if abs(world_y - current_y) <= 2.0:
        return 1.0
    return 0.40


func _draw_spawns(L: Dictionary) -> void:
    var font := get_theme_default_font()
    for sp in L.get("spawns", []):
        var pos: Array = sp.get("pos", [0, 0, 0])
        var p: Vector2 = world_to_canvas(Vector2(pos[0], pos[2]))
        var a: float = _entity_alpha_for_y(float(pos[1]))
        var col: Color = SPAWN_COLOR
        col.a = a
        draw_circle(p, 9.0, col)
        var rot: float = float(sp.get("rotation_y", 0.0))
        var dir: Vector2 = Vector2(-sin(rot), -cos(rot)) * 16.0
        draw_line(p, p + dir, col.darkened(0.2), 2.0)
        draw_string(font, p + Vector2(11, -10), String(sp.get("id", "?")),
                    HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)


func _draw_lights(L: Dictionary) -> void:
    for lt in L.get("lights", []):
        var pos: Array = lt.get("pos", [0, 0, 0])
        var p: Vector2 = world_to_canvas(Vector2(pos[0], pos[2]))
        var a: float = _entity_alpha_for_y(float(pos[1]))
        var col: Color = LIGHT_COLOR
        if lt.has("color") and lt.color is Array and lt.color.size() >= 3:
            col = Color(lt.color[0], lt.color[1], lt.color[2])
        col.a = a
        draw_circle(p, 5.0, col.darkened(0.2))
        var rng: float = float(lt.get("range", 8.0)) * pixels_per_meter
        draw_arc(p, rng, 0.0, TAU, 32, Color(col.r, col.g, col.b, a * 0.30), 1.0)


func _draw_enemies(L: Dictionary) -> void:
    var font := get_theme_default_font()
    for e in L.get("enemies", []):
        var t: String = String(e.get("type", ""))
        var col: Color = ENEMY_COLOR.get(t, Color(1, 0.4, 0.4))
        var pos: Array = e.get("pos", [0, 0, 0])
        var a: float = _entity_alpha_for_y(float(pos[1]))
        col.a = a
        var p: Vector2 = world_to_canvas(Vector2(pos[0], pos[2]))
        draw_circle(p, 7.0, col)
        draw_string(font, p + Vector2(9, 4), t,
                    HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


func _draw_props(L: Dictionary) -> void:
    var font := get_theme_default_font()
    for pr in L.get("props", []):
        var t: String = String(pr.get("type", ""))
        var pos: Array = pr.get("pos", [0, 0, 0])
        var p: Vector2 = world_to_canvas(Vector2(pos[0], pos[2]))
        var a: float = _entity_alpha_for_y(float(pos[1]))
        var col: Color = SIGN_COLOR if t == "sign" else CHEST_COLOR
        col.a = a
        draw_rect(Rect2(p - Vector2(7, 7), Vector2(14, 14)), col)
        var label: String = "S" if t == "sign" else "C"
        draw_string(font, p - Vector2(4, -4), label,
                    HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color(0, 0, 0, a))


func _draw_load_zones(L: Dictionary) -> void:
    var font := get_theme_default_font()
    for lz in L.get("load_zones", []):
        var pos: Array = lz.get("pos", [0, 0, 0])
        var sz: Array = lz.get("size", [3, 3, 1])
        var p: Vector2 = world_to_canvas(Vector2(pos[0], pos[2]))
        var w: float = float(sz[0]) * pixels_per_meter
        var h: float = float(sz[2]) * pixels_per_meter
        var rect := Rect2(p - Vector2(w / 2.0, h / 2.0), Vector2(w, h))
        draw_rect(rect, LOAD_ZONE_COLOR)
        draw_rect(rect, LOAD_ZONE_COLOR.lightened(0.2), false, 1.5)
        draw_string(font, p, String(lz.get("target_scene", "?")),
                    HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color(0.85, 0.65, 1.0))


func _draw_doors(L: Dictionary) -> void:
    var font := get_theme_default_font()
    for door in L.get("doors", []):
        var pos: Array = door.get("pos", [0, 0, 0])
        var rot: float = float(door.get("rotation_y", 0.0))
        var dwidth: float = float(door.get("door_width", 3.0))
        var ext_len: float = float(door.get("wall_extension", 0.0))
        var kind: String = String(door.get("type", "locked"))
        var p: Vector2 = world_to_canvas(Vector2(pos[0], pos[2]))
        var col: Color = DOOR_LOCKED_COL if kind == "locked" else DOOR_UNLOCK_COL

        # Door slab — short rectangle perpendicular to wall axis.
        var fwd: Vector2 = Vector2(-sin(rot), -cos(rot))     # facing direction
        var side: Vector2 = Vector2(cos(rot), -sin(rot))     # along the wall
        var half_w: float = dwidth / 2.0 * pixels_per_meter
        var half_t: float = 0.4 * pixels_per_meter / 2.0
        var p_a: Vector2 = p + side * half_w + fwd * half_t
        var p_b: Vector2 = p - side * half_w + fwd * half_t
        var p_c: Vector2 = p - side * half_w - fwd * half_t
        var p_d: Vector2 = p + side * half_w - fwd * half_t
        var poly: PackedVector2Array = PackedVector2Array([p_a, p_b, p_c, p_d])
        draw_colored_polygon(poly, col)
        draw_polyline(poly + PackedVector2Array([p_a]), col.darkened(0.3), 1.5)

        # Wall extensions on each side.
        if ext_len > 0:
            var off: float = (dwidth / 2.0 + ext_len / 2.0) * pixels_per_meter
            for sign in [-1.0, 1.0]:
                var center: Vector2 = p + side * off * sign
                var hw: float = ext_len / 2.0 * pixels_per_meter
                var hh: float = 0.2 * pixels_per_meter / 2.0
                var a := center + side * hw + fwd * hh
                var b := center - side * hw + fwd * hh
                var c := center - side * hw - fwd * hh
                var d := center + side * hw - fwd * hh
                draw_colored_polygon(PackedVector2Array([a, b, c, d]), DOOR_WALL_EXT)

        # Lock glyph — yellow circle with key cutout for locked doors.
        if kind == "locked":
            draw_circle(p, 5.0, Color(0.95, 0.85, 0.30))
            draw_circle(p, 2.0, Color(0.20, 0.15, 0.05))

        draw_string(font, p + Vector2(8, -8), "door", HORIZONTAL_ALIGNMENT_LEFT,
                    -1, 11, col)


func _draw_selection() -> void:
    if editor == null: return
    var sel = editor.get_selection()
    if sel == null or sel.data == null: return
    var d: Dictionary = sel.data
    if not d.has("pos"): return
    var p: Vector2 = world_to_canvas(Vector2(d.pos[0], d.pos[2]))
    draw_circle(p, 18.0, Color(1.0, 0.9, 0.30, 0.25))
    draw_arc(p, 18.0, 0, TAU, 32, Color(1.0, 0.85, 0.30), 2.0)


func _draw_tool_hover() -> void:
    if editor == null: return
    var t: String = editor.current_tool
    if t == "paint" or t == "erase":
        var ci: Vector2i = world_to_cell(_hover_world)
        var rc: Rect2 = cell_canvas_rect(ci)
        var col: Color = ERASE_HOVER if t == "erase" else PAINT_HOVER
        draw_rect(rc, col)
        draw_rect(rc, col.lightened(0.3), false, 1.5)
    elif t == "load_zone":
        var p: Vector2 = world_to_canvas(_hover_world)
        var w: float = 4.0 * pixels_per_meter
        var h: float = 1.5 * pixels_per_meter
        draw_rect(Rect2(p - Vector2(w/2, h/2), Vector2(w, h)),
                  Color(0.55, 0.30, 0.85, 0.25), false, 1.5)
