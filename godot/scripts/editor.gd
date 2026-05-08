extends Control

# Top-down JSON dungeon editor for The Legend of Tux. Cell-paint based:
# you click cells on the canvas grid to add or remove them from the
# current floor's cell set. Walls auto-derive from cell-perimeter edges.
# Multi-floor: each floor has its own cell set + Y elevation, and the
# editor stacks them visually so you can author multi-story structures.
#
# Tools (palette):
#   select          pick / move (drag) / delete (right-click)
#   paint           left-click cells to add to current floor; right-click to erase
#   erase           explicit erase (left-click removes cells)
#   spawn           click to place spawn marker (snaps to grid optionally)
#   light           click to place point light
#   blob/bat/knight click to place enemy
#   sign/chest      click to place prop
#   load_zone       click to place load zone (then pick target in inspector)
#
# Floors are managed via a dropdown + add/remove buttons. Each floor:
#   {y, name, cells: [[i,j],...], wall_height, wall_color, floor_color, ...}
#
# Bidirectional load zone link: when a load_zone is selected, the
# inspector shows a "Make return link" button that opens the target
# JSON, adds a matching return load_zone + spawn pair pointing back to
# this level, and saves both files.

const EditorCanvas = preload("res://scripts/editor_canvas.gd")

const TOOLS_DEF := [
    ["select",    "Select"],
    ["paint",     "Paint Cell"],
    ["erase",     "Erase Cell"],
    ["spawn",     "+ Spawn"],
    ["light",     "+ Light"],
    ["blob",      "+ Blob"],
    ["bat",       "+ Bat"],
    ["knight",    "+ Knight"],
    ["sign",      "+ Sign"],
    ["chest",     "+ Chest"],
    ["door",      "+ Door"],
    ["load_zone", "+ Load Zone"],
]

const CHEST_CONTENTS := ["", "key", "pebble", "heart", "boomerang", "item"]
const DOOR_TYPES     := ["locked", "unlocked"]

const ENEMY_DEFAULT_Y := {"blob": 0.0, "bat": 1.4, "knight": 0.0}

# Default colors for new floors (cycle through to differentiate).
const FLOOR_PALETTE := [
    [[0.30, 0.50, 0.30, 1.0], [0.45, 0.45, 0.45, 1.0]],   # green floor, grey wall
    [[0.45, 0.40, 0.55, 1.0], [0.30, 0.30, 0.35, 1.0]],
    [[0.65, 0.55, 0.40, 1.0], [0.40, 0.30, 0.20, 1.0]],
    [[0.40, 0.50, 0.65, 1.0], [0.30, 0.35, 0.45, 1.0]],
]

const MAX_UNDO: int = 60

# ---- state -------------------------------------------------------------

var level: Dictionary = {}
var current_path: String = ""
var current_tool: String = "select"
var selected = null    # null or {category: String, data: Dictionary}
var current_floor_idx: int = 0
var snap_to_grid: bool = true
var undo_stack: Array = []
var redo_stack: Array = []
var dungeons_path: String

# Per-cell paint metadata. paint_color.a == 0 means "use the floor's
# default color"; non-zero alpha turns this into a per-cell tint
# (useful for drawing path tiles, stained pavement, etc.). paint_y is
# meters of vertical displacement applied to the cell's floor slab,
# letting you build slopes, ramps, and stepped terrain without
# leaving the cell-paint workflow.
var paint_y: float = 0.0
var paint_color: Color = Color(1, 1, 1, 0)

# Painting "mode" — set on mouse down, used during drag so we don't
# flip-flop the cell state every frame.
var _paint_mode: String = ""  # "add" | "remove" | ""
var _painted_during_stroke: Dictionary = {}

# ---- UI refs -----------------------------------------------------------

var canvas: EditorCanvas
var inspector_box: VBoxContainer
var status_label: Label
var file_dropdown: OptionButton
var floor_dropdown: OptionButton
var tool_buttons: Dictionary = {}
var snap_btn: Button
var paint_y_spin: SpinBox
var paint_color_btn: ColorPickerButton


# ---- init --------------------------------------------------------------

func _ready() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    dungeons_path = ProjectSettings.globalize_path("res://").path_join("../dungeons").simplify_path()
    _build_ui()
    _refresh_file_list()
    if file_dropdown.item_count > 0:
        file_dropdown.select(0)
        _on_file_selected(0)
    else:
        _refresh_inspector()


# Used by canvas to read live state.
func get_selection():
    return selected


func current_floor_y() -> float:
    var f = _current_floor()
    if f == null: return 0.0
    return float(f.get("y", 0.0))


# ---- UI construction ---------------------------------------------------

func _build_ui() -> void:
    var bg := ColorRect.new()
    bg.color = Color(0.07, 0.08, 0.11)
    bg.anchor_right = 1.0
    bg.anchor_bottom = 1.0
    bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(bg)

    # Hard-split layout: HBox with the editor on the left and a fixed-
    # width inspector panel pinned to the right. Avoids HSplit's offset-
    # math edge cases that could clip the inspector to a few pixels.
    var hbox := HBoxContainer.new()
    hbox.anchor_right = 1.0
    hbox.anchor_bottom = 1.0
    hbox.add_theme_constant_override("separation", 0)
    add_child(hbox)

    var left := VBoxContainer.new()
    left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    left.size_flags_vertical = Control.SIZE_EXPAND_FILL
    left.add_theme_constant_override("separation", 0)
    hbox.add_child(left)

    # ---- Row 1: file ops + global actions ------------------------------
    var top_bar := HBoxContainer.new()
    top_bar.custom_minimum_size = Vector2(0, 32)
    top_bar.add_theme_constant_override("separation", 4)
    left.add_child(top_bar)

    file_dropdown = OptionButton.new()
    file_dropdown.custom_minimum_size = Vector2(180, 28)
    file_dropdown.item_selected.connect(_on_file_selected)
    top_bar.add_child(file_dropdown)
    top_bar.add_child(_make_button("New",    _on_new_level))
    top_bar.add_child(_make_button("Reload", _on_reload))
    top_bar.add_child(_make_button("Save",   _on_save))
    top_bar.add_child(_make_button("Build",  _on_build))
    top_bar.add_child(_make_button("Play",   _on_play))
    top_bar.add_child(_make_button("Menu",   _on_menu))

    var spacer1 := Control.new()
    spacer1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    top_bar.add_child(spacer1)

    snap_btn = _make_button("Snap: ON", _on_toggle_snap)
    snap_btn.toggle_mode = true
    snap_btn.button_pressed = true
    top_bar.add_child(snap_btn)
    top_bar.add_child(_make_button("Undo (^Z)", _on_undo))
    top_bar.add_child(_make_button("Redo (^Y)", _on_redo))

    # ---- Row 2: floor management ---------------------------------------
    var floor_bar := HBoxContainer.new()
    floor_bar.custom_minimum_size = Vector2(0, 32)
    floor_bar.add_theme_constant_override("separation", 4)
    left.add_child(floor_bar)

    var floor_lbl := Label.new()
    floor_lbl.text = "Floor:"
    floor_lbl.add_theme_color_override("font_color", Color(0.85, 0.95, 0.85))
    floor_bar.add_child(floor_lbl)
    floor_dropdown = OptionButton.new()
    floor_dropdown.custom_minimum_size = Vector2(160, 28)
    floor_dropdown.item_selected.connect(_on_floor_selected)
    floor_bar.add_child(floor_dropdown)
    floor_bar.add_child(_make_button("+Floor", _on_add_floor))
    floor_bar.add_child(_make_button("-Floor", _on_remove_floor))

    var paint_sep := VSeparator.new()
    paint_sep.custom_minimum_size = Vector2(2, 28)
    floor_bar.add_child(paint_sep)

    var py_lbl := Label.new()
    py_lbl.text = "Cell Y:"
    floor_bar.add_child(py_lbl)
    paint_y_spin = SpinBox.new()
    paint_y_spin.min_value = -50.0
    paint_y_spin.max_value = 50.0
    paint_y_spin.step = 0.25
    paint_y_spin.value = 0.0
    paint_y_spin.custom_minimum_size = Vector2(80, 28)
    paint_y_spin.value_changed.connect(func(v: float) -> void: paint_y = v)
    floor_bar.add_child(paint_y_spin)

    var pc_lbl := Label.new()
    pc_lbl.text = "Cell Color:"
    floor_bar.add_child(pc_lbl)
    paint_color_btn = ColorPickerButton.new()
    paint_color_btn.color = Color(1, 1, 1, 0)
    paint_color_btn.custom_minimum_size = Vector2(50, 28)
    paint_color_btn.color_changed.connect(func(c: Color) -> void: paint_color = c)
    floor_bar.add_child(paint_color_btn)
    floor_bar.add_child(_make_button("Reset", func() -> void:
        paint_color = Color(1, 1, 1, 0)
        paint_color_btn.color = paint_color))

    var spacer2 := Control.new()
    spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    floor_bar.add_child(spacer2)

    var hint := Label.new()
    hint.text = "Wheel zoom · Mid pan · RClick delete"
    hint.add_theme_color_override("font_color", Color(0.55, 0.60, 0.70))
    hint.add_theme_font_size_override("font_size", 11)
    floor_bar.add_child(hint)

    # ---- Row 3: tool palette -------------------------------------------
    var palette := HBoxContainer.new()
    palette.add_theme_constant_override("separation", 2)
    palette.custom_minimum_size = Vector2(0, 30)
    left.add_child(palette)
    for entry in TOOLS_DEF:
        var key: String = entry[0]
        var b := Button.new()
        b.text = entry[1]
        b.toggle_mode = true
        b.button_pressed = (key == current_tool)
        b.pressed.connect(func() -> void: _set_tool(key))
        palette.add_child(b)
        tool_buttons[key] = b

    # ---- Canvas --------------------------------------------------------
    canvas = EditorCanvas.new()
    canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
    canvas.editor = self
    canvas.canvas_click.connect(_on_canvas_click)
    canvas.canvas_drag.connect(_on_canvas_drag)
    canvas.canvas_release.connect(_on_canvas_release)
    canvas.canvas_hover.connect(_on_canvas_hover)
    left.add_child(canvas)

    # ---- Status bar (bottom) -------------------------------------------
    var status_bar := PanelContainer.new()
    status_bar.custom_minimum_size = Vector2(0, 24)
    left.add_child(status_bar)
    var status_margin := MarginContainer.new()
    status_margin.add_theme_constant_override("margin_left", 8)
    status_margin.add_theme_constant_override("margin_right", 8)
    status_margin.add_theme_constant_override("margin_top", 2)
    status_margin.add_theme_constant_override("margin_bottom", 2)
    status_bar.add_child(status_margin)
    status_label = Label.new()
    status_label.text = "no level loaded"
    status_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.65, 1))
    status_margin.add_child(status_label)

    # ---- Right-side inspector ------------------------------------------
    var inspector_panel := PanelContainer.new()
    inspector_panel.custom_minimum_size = Vector2(380, 0)
    inspector_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    hbox.add_child(inspector_panel)

    var pad := MarginContainer.new()
    pad.add_theme_constant_override("margin_left", 12)
    pad.add_theme_constant_override("margin_right", 12)
    pad.add_theme_constant_override("margin_top", 10)
    pad.add_theme_constant_override("margin_bottom", 10)
    inspector_panel.add_child(pad)

    var scroll := ScrollContainer.new()
    scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    pad.add_child(scroll)

    inspector_box = VBoxContainer.new()
    inspector_box.add_theme_constant_override("separation", 6)
    inspector_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(inspector_box)


func _make_button(label: String, cb: Callable) -> Button:
    var b := Button.new()
    b.text = label
    b.pressed.connect(cb)
    return b


func _set_tool(t: String) -> void:
    current_tool = t
    for k in tool_buttons:
        tool_buttons[k].set_pressed_no_signal(k == t)
    canvas.queue_redraw()


# ---- file ops ----------------------------------------------------------

func _refresh_file_list() -> void:
    var keep := file_dropdown.get_item_text(file_dropdown.selected) if file_dropdown.selected >= 0 else ""
    file_dropdown.clear()
    var dir := DirAccess.open(dungeons_path)
    if dir == null:
        status_label.text = "dungeons dir not found: %s" % dungeons_path
        return
    var files: Array = []
    dir.list_dir_begin()
    var fn: String = dir.get_next()
    while fn != "":
        if not dir.current_is_dir() and fn.ends_with(".json"):
            files.append(fn)
        fn = dir.get_next()
    files.sort()
    var pick_idx: int = 0
    for i in range(files.size()):
        file_dropdown.add_item(files[i])
        if files[i] == keep:
            pick_idx = i
    if file_dropdown.item_count > 0:
        file_dropdown.select(pick_idx)


func _on_file_selected(idx: int) -> void:
    var fn := file_dropdown.get_item_text(idx)
    _load_file(dungeons_path.path_join(fn))


func _on_reload() -> void:
    if current_path != "":
        _load_file(current_path)


func _load_file(path: String) -> void:
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        _set_status("load failed: %s" % path, true)
        return
    var text := f.get_as_text()
    f.close()
    var json := JSON.new()
    var err := json.parse(text)
    if err != OK:
        _set_status("JSON parse error: line %d" % json.get_error_line(), true)
        return
    if not (json.data is Dictionary):
        _set_status("JSON root is not an object", true)
        return
    level = json.data
    current_path = path
    selected = null
    undo_stack.clear()
    redo_stack.clear()
    current_floor_idx = 0
    _refresh_floor_dropdown()
    _set_status("loaded: %s" % path.get_file())
    canvas.queue_redraw()
    _refresh_inspector()


func _on_save() -> void:
    if current_path == "":
        _set_status("no file to save", true)
        return
    var f := FileAccess.open(current_path, FileAccess.WRITE)
    if f == null:
        _set_status("save failed: %s" % current_path, true)
        return
    f.store_string(JSON.stringify(level, "  "))
    f.close()
    _set_status("saved: %s" % current_path.get_file())


func _on_build() -> void:
    var script_abs := ProjectSettings.globalize_path("res://").path_join("../tools/build_dungeon.py").simplify_path()
    var args := [script_abs]
    if level.has("id"):
        args.append(String(level.id))
    var output: Array = []
    var rc := OS.execute("python3", args, output, true)
    var last_line: String = ""
    if output.size() > 0:
        var lines: PackedStringArray = String(output[0]).split("\n")
        for i in range(lines.size() - 1, -1, -1):
            if String(lines[i]).strip_edges() != "":
                last_line = String(lines[i]).strip_edges(); break
    _set_status("build rc=%d %s" % [rc, last_line], rc != 0)


func _on_play() -> void:
    if not level.has("id"):
        _set_status("no level id", true); return
    var scene_path := "res://scenes/%s.tscn" % String(level.id)
    if not ResourceLoader.exists(scene_path):
        _set_status("scene not built — Build first", true); return
    get_tree().change_scene_to_file(scene_path)


func _on_menu() -> void:
    get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_new_level() -> void:
    var dlg := AcceptDialog.new()
    dlg.title = "New Level"
    dlg.dialog_hide_on_ok = false
    var vb := VBoxContainer.new()
    var lbl := Label.new()
    lbl.text = "New level id (filename, no .json):"
    vb.add_child(lbl)
    var le := LineEdit.new()
    le.text = "new_level"
    le.custom_minimum_size = Vector2(280, 0)
    vb.add_child(le)
    dlg.add_child(vb)
    add_child(dlg)
    dlg.popup_centered(Vector2i(360, 140))
    dlg.confirmed.connect(func() -> void:
        var id: String = le.text.strip_edges()
        if id == "" or "/" in id or "." in id:
            _set_status("bad id", true); dlg.queue_free(); return
        var path: String = dungeons_path.path_join(id + ".json")
        if FileAccess.file_exists(path):
            _set_status("file already exists", true); dlg.queue_free(); return
        var template: Dictionary = _new_level_template(id)
        var f := FileAccess.open(path, FileAccess.WRITE)
        f.store_string(JSON.stringify(template, "  "))
        f.close()
        _refresh_file_list()
        for i in range(file_dropdown.item_count):
            if file_dropdown.get_item_text(i) == id + ".json":
                file_dropdown.select(i)
                _on_file_selected(i)
                break
        dlg.queue_free()
    )


func _new_level_template(id: String) -> Dictionary:
    return {
        "name": id.capitalize(),
        "id": id,
        "environment": {
            "sky_top":        [0.30, 0.45, 0.70, 1.0],
            "sky_horizon":    [0.55, 0.65, 0.75, 1.0],
            "ground_horizon": [0.45, 0.45, 0.40, 1.0],
            "ground_bottom":  [0.20, 0.20, 0.18, 1.0],
            "ambient_color":  [0.85, 0.85, 0.95, 1.0],
            "ambient_energy": 0.35,
            "fog_density":    0.001,
            "fog_color":      [0.45, 0.55, 0.65, 1.0],
            "sun_dir":        [-0.5, -0.8, -0.3],
            "sun_color":      [1.00, 0.98, 0.88, 1.0],
            "sun_energy":     1.1,
        },
        "grid": {
            "cell_size": 2.0,
            "floors": [{
                "y":            0.0,
                "name":         "ground",
                "cells":        [],
                "wall_height":  4.0,
                "wall_color":   [0.45, 0.45, 0.45, 1.0],
                "floor_color":  [0.30, 0.50, 0.30, 1.0],
                "wall_material": "stone",
                "has_floor":    true,
                "has_walls":    true,
                "has_roof":     false,
            }],
        },
        "spawns": [{"id": "default", "pos": [0.0, 0.0, 0.0], "rotation_y": 0.0}],
        "lights": [],
        "enemies": [],
        "props": [],
        "load_zones": [],
    }


# ---- floor management --------------------------------------------------

func _grid() -> Dictionary:
    if not level.has("grid"):
        level["grid"] = {
            "cell_size": 2.0,
            "floors": [],
        }
    return level.grid


func _floors() -> Array:
    return _grid().get("floors", [])


func _current_floor():
    var fs: Array = _floors()
    if current_floor_idx < 0 or current_floor_idx >= fs.size():
        return null
    return fs[current_floor_idx]


func _ensure_default_floor() -> void:
    var grid: Dictionary = _grid()
    var fs: Array = grid.get("floors", [])
    if fs.is_empty():
        var pal = FLOOR_PALETTE[0]
        fs.append({
            "y":            0.0,
            "name":         "ground",
            "cells":        [],
            "wall_height":  4.0,
            "wall_color":   pal[1],
            "floor_color":  pal[0],
            "wall_material": "stone",
            "has_floor":    true,
            "has_roof":     false,
        })
        grid["floors"] = fs
        current_floor_idx = 0
        _refresh_floor_dropdown()


func _refresh_floor_dropdown() -> void:
    floor_dropdown.clear()
    var fs: Array = _floors()
    for i in range(fs.size()):
        var f: Dictionary = fs[i]
        var label: String = "%s (y=%.1f)" % [String(f.get("name", "floor%d" % i)), float(f.get("y", 0.0))]
        floor_dropdown.add_item(label)
    if current_floor_idx >= fs.size():
        current_floor_idx = max(0, fs.size() - 1)
    if fs.size() > 0:
        floor_dropdown.select(current_floor_idx)


func _on_floor_selected(idx: int) -> void:
    current_floor_idx = idx
    canvas.queue_redraw()
    _refresh_inspector()


func _on_add_floor() -> void:
    _push_undo()
    var grid: Dictionary = _grid()
    var fs: Array = grid.get("floors", [])
    var max_y: float = 0.0
    for f in fs:
        max_y = max(max_y, float(f.get("y", 0.0)) + float(f.get("wall_height", 4.0)))
    var pal_idx: int = fs.size() % FLOOR_PALETTE.size()
    var pal = FLOOR_PALETTE[pal_idx]
    fs.append({
        "y":            max_y,
        "name":         "floor%d" % (fs.size() + 1),
        "cells":        [],
        "wall_height":  4.0,
        "wall_color":   pal[1],
        "floor_color":  pal[0],
        "wall_material": "stone",
        "has_floor":    true,
        "has_roof":     false,
    })
    grid["floors"] = fs
    current_floor_idx = fs.size() - 1
    _refresh_floor_dropdown()
    canvas.queue_redraw()
    _refresh_inspector()


func _on_remove_floor() -> void:
    var fs: Array = _floors()
    if fs.size() <= 1:
        _set_status("can't remove the last floor", true); return
    _push_undo()
    fs.remove_at(current_floor_idx)
    if current_floor_idx >= fs.size():
        current_floor_idx = fs.size() - 1
    _refresh_floor_dropdown()
    canvas.queue_redraw()
    _refresh_inspector()


# ---- canvas dispatch ---------------------------------------------------

func _on_canvas_click(world: Vector2, button: int, _shift: bool, _ctrl: bool) -> void:
    var snapped: Vector2 = _snap(world)
    if current_tool == "paint" or current_tool == "erase":
        _begin_paint_stroke(world, button)
        return
    if current_tool == "select":
        if button == MOUSE_BUTTON_RIGHT:
            var hit = _pick(world)
            if hit:
                _push_undo(); _delete(hit); selected = null
                canvas.queue_redraw(); _refresh_inspector()
            return
        selected = _pick(world)
        _refresh_inspector()
        canvas.queue_redraw()
        return
    # Entity placement tools.
    if button == MOUSE_BUTTON_RIGHT:
        var hit = _pick(world)
        if hit:
            _push_undo(); _delete(hit); selected = null
            canvas.queue_redraw(); _refresh_inspector()
        return
    _push_undo()
    selected = _place_new(snapped, current_tool)
    canvas.queue_redraw()
    _refresh_inspector()


func _on_canvas_drag(world: Vector2, _delta: Vector2) -> void:
    if current_tool == "paint" or current_tool == "erase":
        _continue_paint_stroke(world)
        return
    if current_tool == "select" and selected != null:
        var d: Dictionary = selected.data
        if d.has("pos") and d.pos.size() >= 3:
            var snapped: Vector2 = _snap(world)
            d.pos[0] = snapped.x
            d.pos[2] = snapped.y
            canvas.queue_redraw()
            _refresh_inspector()


func _on_canvas_release(_world: Vector2, _button: int) -> void:
    _paint_mode = ""
    _painted_during_stroke.clear()


func _on_canvas_hover(_world: Vector2) -> void:
    pass


# ---- snap --------------------------------------------------------------

func _snap(world: Vector2) -> Vector2:
    if not snap_to_grid: return world
    var cs: float = canvas.cell_size()
    return Vector2(round(world.x / cs) * cs, round(world.y / cs) * cs)


func _on_toggle_snap() -> void:
    snap_to_grid = snap_btn.button_pressed
    snap_btn.text = "Snap: %s" % ("ON" if snap_to_grid else "OFF")


# ---- paint -------------------------------------------------------------

func _begin_paint_stroke(world: Vector2, button: int) -> void:
    _ensure_default_floor()
    var f = _current_floor()
    if f == null: return
    var ci: Vector2i = canvas.world_to_cell(world)
    var has_cell: bool = _cell_in_floor(ci, f)
    if current_tool == "erase":
        _paint_mode = "remove"
    elif button == MOUSE_BUTTON_RIGHT:
        _paint_mode = "remove"
    else:
        _paint_mode = "add"
    _push_undo()
    _painted_during_stroke.clear()
    _apply_cell_paint(ci, has_cell)


func _continue_paint_stroke(world: Vector2) -> void:
    if _paint_mode == "": return
    var ci: Vector2i = canvas.world_to_cell(world)
    if _painted_during_stroke.has(ci): return
    var f = _current_floor()
    if f == null: return
    var has_cell: bool = _cell_in_floor(ci, f)
    _apply_cell_paint(ci, has_cell)


func _apply_cell_paint(ci: Vector2i, currently_has: bool) -> void:
    _painted_during_stroke[ci] = true
    var f = _current_floor()
    if f == null: return
    var cells: Array = f.get("cells", [])
    if _paint_mode == "add" and not currently_has:
        var entry: Array = [ci.x, ci.y]
        var has_y: bool = abs(paint_y) > 0.001
        var has_col: bool = paint_color.a > 0.001
        if has_y or has_col:
            entry.append(paint_y if has_y else 0.0)
            if has_col:
                entry.append([paint_color.r, paint_color.g,
                              paint_color.b, paint_color.a])
        cells.append(entry)
        f["cells"] = cells
        canvas.queue_redraw()
    elif _paint_mode == "remove" and currently_has:
        for i in range(cells.size()):
            var c = cells[i]
            var cx: int; var cy: int
            if c is Dictionary:
                cx = int(c.get("i", 0)); cy = int(c.get("j", 0))
            else:
                cx = int(c[0]); cy = int(c[1])
            if cx == ci.x and cy == ci.y:
                cells.remove_at(i)
                break
        f["cells"] = cells
        canvas.queue_redraw()


func _cell_in_floor(ci: Vector2i, f: Dictionary) -> bool:
    for c in f.get("cells", []):
        var cx: int; var cy: int
        if c is Dictionary:
            cx = int(c.get("i", 0)); cy = int(c.get("j", 0))
        else:
            cx = int(c[0]); cy = int(c[1])
        if cx == ci.x and cy == ci.y:
            return true
    return false


# ---- picking + entity placement ---------------------------------------

func _pick(world: Vector2):
    var threshold: float = max(0.6, 28.0 / canvas.pixels_per_meter)
    var best = null
    var best_score: float = INF
    # Load zones — full rect hit-test wins immediately.
    for lz in level.get("load_zones", []):
        var pos: Array = lz.get("pos", [0, 0, 0])
        var sz: Array = lz.get("size", [3, 3, 1])
        var rect := Rect2(
            Vector2(pos[0] - sz[0] / 2.0, pos[2] - sz[2] / 2.0),
            Vector2(sz[0], sz[2]))
        if rect.has_point(world):
            return {"category": "load_zones", "data": lz}
    for cat in ["spawns", "lights", "enemies", "props", "doors"]:
        for d in level.get(cat, []):
            if not d.has("pos") or d.pos.size() < 3: continue
            var p := Vector2(float(d.pos[0]), float(d.pos[2]))
            var dist: float = world.distance_to(p)
            if dist < threshold and dist < best_score:
                best_score = dist
                best = {"category": cat, "data": d}
    return best


func _place_new(world: Vector2, tool: String):
    var d: Dictionary = {}
    var cat: String = ""
    match tool:
        "spawn":
            d = {"id": "spawn_%d" % level.get("spawns", []).size(),
                 "pos": [world.x, current_floor_y(), world.y], "rotation_y": 0.0}
            cat = "spawns"
        "light":
            d = {"pos": [world.x, current_floor_y() + 3.0, world.y],
                 "color": [1.0, 0.85, 0.55, 1.0],
                 "energy": 1.0, "range": 10.0}
            cat = "lights"
        "blob", "bat", "knight":
            d = {"type": tool,
                 "pos": [world.x, current_floor_y() + ENEMY_DEFAULT_Y[tool], world.y]}
            cat = "enemies"
        "sign":
            d = {"type": "sign", "pos": [world.x, current_floor_y(), world.y],
                 "rotation_y": 0.0, "message": "..."}
            cat = "props"
        "chest":
            d = {"type": "chest", "pos": [world.x, current_floor_y(), world.y],
                 "rotation_y": 0.0, "contents": "key",
                 "amount": 1, "item_name": "", "open_message": ""}
            cat = "props"
        "door":
            d = {"pos": [world.x, current_floor_y(), world.y],
                 "rotation_y": 0.0,
                 "type": "locked",
                 "door_width": 2.0,
                 "wall_extension": 0.0,
                 "wall_height": 4.0,
                 "wall_color": [0.45, 0.45, 0.45, 1.0],
                 "locked_message": "Locked. A small key would open this door.",
                 "unlock_message": "The lock turns. The door opens."}
            cat = "doors"
        "load_zone":
            d = {"pos": [world.x, current_floor_y() + 1.0, world.y],
                 "size": [4.0, 3.0, 1.5],
                 "rotation_y": 0.0,
                 "target_scene": "",
                 "target_spawn": "default",
                 "prompt": "[E] Travel"}
            cat = "load_zones"
        _:
            return null
    if not level.has(cat): level[cat] = []
    level[cat].append(d)
    return {"category": cat, "data": d}


func _delete(sel) -> void:
    var arr = level.get(sel.category, [])
    arr.erase(sel.data)


# ---- undo / redo -------------------------------------------------------

func _push_undo() -> void:
    undo_stack.append(level.duplicate(true))
    if undo_stack.size() > MAX_UNDO:
        undo_stack.pop_front()
    redo_stack.clear()


func _on_undo() -> void:
    if undo_stack.is_empty():
        _set_status("nothing to undo"); return
    redo_stack.append(level.duplicate(true))
    level = undo_stack.pop_back()
    selected = null
    _refresh_floor_dropdown()
    canvas.queue_redraw()
    _refresh_inspector()
    _set_status("undid")


func _on_redo() -> void:
    if redo_stack.is_empty():
        _set_status("nothing to redo"); return
    undo_stack.append(level.duplicate(true))
    level = redo_stack.pop_back()
    selected = null
    _refresh_floor_dropdown()
    canvas.queue_redraw()
    _refresh_inspector()
    _set_status("redid")


# ---- inspector ---------------------------------------------------------

func _refresh_inspector() -> void:
    for c in inspector_box.get_children():
        c.queue_free()

    var head := Label.new()
    head.text = "Inspector"
    head.add_theme_font_size_override("font_size", 18)
    inspector_box.add_child(head)

    if level.is_empty():
        return

    # Level metadata.
    _add_field("name", level)
    _add_field("id", level)
    inspector_box.add_child(HSeparator.new())

    # Current floor properties (if grid present).
    if _floors().size() > 0:
        _build_floor_inspector()
        inspector_box.add_child(HSeparator.new())

    if selected == null:
        var hint := Label.new()
        hint.text = "Click an entity to edit. Pick a tool above and click empty canvas to place. Right-click an entity to delete. Middle-drag to pan, wheel to zoom."
        hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        hint.add_theme_color_override("font_color", Color(0.65, 0.70, 0.80))
        inspector_box.add_child(hint)
        return

    var cat_lbl := Label.new()
    cat_lbl.text = "%s entry" % String(selected.category).trim_suffix("s").capitalize()
    cat_lbl.add_theme_font_size_override("font_size", 14)
    cat_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.30))
    inspector_box.add_child(cat_lbl)

    if selected.category == "load_zones":
        _build_load_zone_inspector(selected.data)
    elif selected.category == "doors":
        _build_door_inspector(selected.data)
    elif selected.category == "props" and String(selected.data.get("type", "")) == "chest":
        _build_chest_inspector(selected.data)
    else:
        for key in selected.data.keys():
            _add_field(key, selected.data)

    var del := _make_button("Delete", func() -> void:
        _push_undo(); _delete(selected); selected = null
        _refresh_inspector(); canvas.queue_redraw())
    del.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55))
    inspector_box.add_child(del)


func _build_floor_inspector() -> void:
    var f = _current_floor()
    if f == null: return
    var lbl := Label.new()
    lbl.text = "Floor: %s" % String(f.get("name", ""))
    lbl.add_theme_font_size_override("font_size", 14)
    lbl.add_theme_color_override("font_color", Color(0.85, 0.95, 0.85))
    inspector_box.add_child(lbl)
    var count := Label.new()
    count.text = "%d cells" % f.get("cells", []).size()
    count.add_theme_color_override("font_color", Color(0.65, 0.70, 0.80))
    inspector_box.add_child(count)
    for key in ["name", "y", "wall_height", "wall_material",
                "has_floor", "has_walls", "has_roof",
                "wall_color", "floor_color"]:
        if f.has(key):
            _add_field(key, f)


func _build_load_zone_inspector(d: Dictionary) -> void:
    # pos, size as vector spinboxes
    _add_field("pos", d)
    _add_field("size", d)
    _add_field("rotation_y", d)
    _add_field("prompt", d)

    # Target dungeon dropdown.
    var target_lbl := Label.new()
    target_lbl.text = "target_scene"
    target_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
    inspector_box.add_child(target_lbl)
    var target_drop := OptionButton.new()
    target_drop.custom_minimum_size = Vector2(0, 28)
    var target_files: Array = _list_dungeon_ids()
    var current_target: String = String(d.get("target_scene", ""))
    var found_idx: int = -1
    for i in range(target_files.size()):
        target_drop.add_item(target_files[i])
        if target_files[i] == current_target:
            found_idx = i
    if found_idx >= 0:
        target_drop.select(found_idx)
    target_drop.item_selected.connect(func(idx: int) -> void:
        var name: String = target_drop.get_item_text(idx)
        d["target_scene"] = name
        _refresh_inspector())
    inspector_box.add_child(target_drop)

    # Target spawn dropdown — read spawns from target file if it exists.
    var spawn_lbl := Label.new()
    spawn_lbl.text = "target_spawn"
    spawn_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
    inspector_box.add_child(spawn_lbl)
    var spawn_drop := OptionButton.new()
    spawn_drop.custom_minimum_size = Vector2(0, 28)
    var spawn_ids: Array = _list_spawn_ids_in(String(d.get("target_scene", "")))
    var current_spawn: String = String(d.get("target_spawn", ""))
    var picked: int = -1
    for i in range(spawn_ids.size()):
        spawn_drop.add_item(spawn_ids[i])
        if spawn_ids[i] == current_spawn:
            picked = i
    if spawn_ids.is_empty():
        spawn_drop.add_item("(none — pick target first)")
        spawn_drop.disabled = true
    elif picked >= 0:
        spawn_drop.select(picked)
    spawn_drop.item_selected.connect(func(idx: int) -> void:
        d["target_spawn"] = spawn_drop.get_item_text(idx))
    inspector_box.add_child(spawn_drop)

    # Bidirectional link button.
    var link_btn := _make_button("Make return link", func() -> void:
        _make_bidirectional_link(d))
    link_btn.add_theme_color_override("font_color", Color(0.65, 0.95, 0.85))
    inspector_box.add_child(link_btn)


func _build_door_inspector(d: Dictionary) -> void:
    _add_field("pos", d)
    _add_field("rotation_y", d)

    var type_lbl := Label.new()
    type_lbl.text = "type"
    type_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
    inspector_box.add_child(type_lbl)
    var type_drop := OptionButton.new()
    type_drop.custom_minimum_size = Vector2(0, 28)
    var current_type: String = String(d.get("type", "locked"))
    var picked: int = 0
    for i in range(DOOR_TYPES.size()):
        type_drop.add_item(DOOR_TYPES[i])
        if DOOR_TYPES[i] == current_type:
            picked = i
    type_drop.select(picked)
    type_drop.item_selected.connect(func(idx: int) -> void:
        d["type"] = DOOR_TYPES[idx])
    inspector_box.add_child(type_drop)

    _add_field("door_width", d)
    _add_field("wall_extension", d)
    _add_field("wall_height", d)
    _add_field("locked_message", d)
    _add_field("unlock_message", d)

    var hint := Label.new()
    hint.text = "Tip: wall_extension > 0 emits flanking solid walls automatically — use it when the door isn't already inside a grid-derived wall."
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint.add_theme_color_override("font_color", Color(0.55, 0.65, 0.75))
    hint.add_theme_font_size_override("font_size", 11)
    inspector_box.add_child(hint)


func _build_chest_inspector(d: Dictionary) -> void:
    _add_field("pos", d)
    _add_field("rotation_y", d)

    var c_lbl := Label.new()
    c_lbl.text = "contents"
    c_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
    inspector_box.add_child(c_lbl)
    var c_drop := OptionButton.new()
    c_drop.custom_minimum_size = Vector2(0, 28)
    var current_contents: String = String(d.get("contents", ""))
    var picked: int = 0
    for i in range(CHEST_CONTENTS.size()):
        var label: String = "(empty)" if CHEST_CONTENTS[i] == "" else CHEST_CONTENTS[i]
        c_drop.add_item(label)
        if CHEST_CONTENTS[i] == current_contents:
            picked = i
    c_drop.select(picked)
    c_drop.item_selected.connect(func(idx: int) -> void:
        d["contents"] = CHEST_CONTENTS[idx]
        _refresh_inspector())
    inspector_box.add_child(c_drop)

    if current_contents == "pebble":
        _add_field("amount", d)
    elif current_contents == "item":
        _add_field("item_name", d)

    _add_field("open_message", d)


func _list_dungeon_ids() -> Array:
    var out: Array = []
    var dir := DirAccess.open(dungeons_path)
    if dir == null: return out
    dir.list_dir_begin()
    var fn: String = dir.get_next()
    while fn != "":
        if not dir.current_is_dir() and fn.ends_with(".json"):
            out.append(fn.trim_suffix(".json"))
        fn = dir.get_next()
    out.sort()
    return out


func _list_spawn_ids_in(scene_id: String) -> Array:
    if scene_id == "": return []
    if scene_id == String(level.get("id", "")):
        var out: Array = []
        for sp in level.get("spawns", []):
            out.append(String(sp.get("id", "")))
        return out
    var path: String = dungeons_path.path_join(scene_id + ".json")
    if not FileAccess.file_exists(path): return []
    var f := FileAccess.open(path, FileAccess.READ)
    var text := f.get_as_text()
    f.close()
    var json := JSON.new()
    if json.parse(text) != OK: return []
    var data: Dictionary = json.data
    var ids: Array = []
    for sp in data.get("spawns", []):
        ids.append(String(sp.get("id", "")))
    return ids


func _make_bidirectional_link(lz: Dictionary) -> void:
    var target_scene: String = String(lz.get("target_scene", ""))
    if target_scene == "" or target_scene == String(level.get("id", "")):
        _set_status("set target_scene first", true); return
    var path: String = dungeons_path.path_join(target_scene + ".json")
    if not FileAccess.file_exists(path):
        _set_status("target file not found", true); return

    # Save current first so we don't lose recent edits.
    _on_save()

    var f := FileAccess.open(path, FileAccess.READ)
    var text := f.get_as_text()
    f.close()
    var json := JSON.new()
    if json.parse(text) != OK:
        _set_status("can't parse target", true); return
    var target: Dictionary = json.data

    var return_spawn_id: String = "from_%s" % String(level.get("id", "self"))
    var our_spawn_id: String = String(lz.get("target_spawn", "default"))
    if our_spawn_id == "" or our_spawn_id == "default":
        our_spawn_id = "from_%s" % target_scene
        lz["target_spawn"] = our_spawn_id

    # Add a return spawn point in target if missing.
    var target_spawns: Array = target.get("spawns", [])
    var has_return_spawn: bool = false
    for sp in target_spawns:
        if String(sp.get("id", "")) == return_spawn_id:
            has_return_spawn = true; break
    if not has_return_spawn:
        var lz_pos: Array = lz.get("pos", [0, 0, 0])
        target_spawns.append({
            "id": return_spawn_id,
            "pos": [float(lz_pos[0]) - 4.0, 0.0, float(lz_pos[2])],
            "rotation_y": 0.0,
        })
        target["spawns"] = target_spawns

    # Add a return spawn here named after target's id if missing.
    var here_spawn_id: String = "from_%s" % target_scene
    var here_spawns: Array = level.get("spawns", [])
    var has_here_spawn: bool = false
    for sp in here_spawns:
        if String(sp.get("id", "")) == here_spawn_id:
            has_here_spawn = true; break
    if not has_here_spawn:
        var lz_pos: Array = lz.get("pos", [0, 0, 0])
        here_spawns.append({
            "id": here_spawn_id,
            "pos": [float(lz_pos[0]) + 4.0, current_floor_y(), float(lz_pos[2])],
            "rotation_y": PI,
        })
        level["spawns"] = here_spawns
        lz["target_spawn"] = here_spawn_id

    # Add a return load_zone in target if no zone there already targets us.
    var target_zones: Array = target.get("load_zones", [])
    var have_return_zone: bool = false
    for tz in target_zones:
        if String(tz.get("target_scene", "")) == String(level.get("id", "")):
            have_return_zone = true
            tz["target_spawn"] = return_spawn_id
            break
    if not have_return_zone:
        var lz_pos: Array = lz.get("pos", [0, 0, 0])
        target_zones.append({
            "pos": [float(lz_pos[0]), 1.0, float(lz_pos[2])],
            "size": lz.get("size", [4.0, 3.0, 1.5]).duplicate(),
            "rotation_y": 0.0,
            "target_scene": String(level.get("id", "")),
            "target_spawn": return_spawn_id,
            "prompt": "[E] Travel",
        })
        target["load_zones"] = target_zones

    var wf := FileAccess.open(path, FileAccess.WRITE)
    wf.store_string(JSON.stringify(target, "  "))
    wf.close()
    _on_save()
    _refresh_inspector()
    _set_status("linked: %s ⇄ %s" % [String(level.get("id", "")), target_scene])


# ---- generic field editor ---------------------------------------------

func _add_field(key: String, container) -> void:
    var v = container[key]
    var row := VBoxContainer.new()
    row.add_theme_constant_override("separation", 1)
    inspector_box.add_child(row)
    var label := Label.new()
    label.text = key
    label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
    row.add_child(label)

    if v is String:
        var le := LineEdit.new()
        le.text = v
        le.text_changed.connect(func(t: String) -> void:
            container[key] = t; canvas.queue_redraw())
        row.add_child(le)
    elif v is float or v is int:
        var sb := SpinBox.new()
        sb.min_value = -10000; sb.max_value = 10000; sb.step = 0.1
        sb.value = float(v)
        sb.value_changed.connect(func(val: float) -> void:
            container[key] = val
            if key in ["y", "wall_height"]:
                _refresh_floor_dropdown()
            canvas.queue_redraw())
        row.add_child(sb)
    elif v is bool:
        var cb := CheckBox.new()
        cb.button_pressed = v
        cb.toggled.connect(func(p: bool) -> void:
            container[key] = p; canvas.queue_redraw())
        row.add_child(cb)
    elif v is Array:
        var nested_complex: bool = false
        for item in v:
            if item is Array or item is Dictionary:
                nested_complex = true; break
        if nested_complex:
            var disabled := Label.new()
            disabled.text = "(%d items — JSON only)" % v.size()
            disabled.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
            row.add_child(disabled)
        else:
            var hbox := HBoxContainer.new()
            for i in range(v.size()):
                var sb := SpinBox.new()
                sb.min_value = -10000; sb.max_value = 10000; sb.step = 0.1
                sb.custom_minimum_size = Vector2(70, 0)
                sb.value = float(v[i]) if (v[i] is float or v[i] is int) else 0.0
                var idx := i
                sb.value_changed.connect(func(val: float) -> void:
                    v[idx] = val; canvas.queue_redraw())
                hbox.add_child(sb)
            row.add_child(hbox)
    elif v is Dictionary:
        var disabled := Label.new()
        disabled.text = "(nested object — JSON only)"
        disabled.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
        row.add_child(disabled)
    else:
        var disabled := Label.new()
        disabled.text = "(%s)" % typeof(v)
        row.add_child(disabled)


# ---- status / hotkeys --------------------------------------------------

func _set_status(msg: String, error: bool = false) -> void:
    status_label.text = msg
    var col: Color = Color(1.0, 0.5, 0.5) if error else Color(0.85, 0.85, 0.65)
    status_label.add_theme_color_override("font_color", col)


func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey) or not event.pressed or event.echo: return
    if event.ctrl_pressed and event.keycode == KEY_S:
        _on_save(); get_viewport().set_input_as_handled()
    elif event.ctrl_pressed and event.keycode == KEY_B:
        _on_build(); get_viewport().set_input_as_handled()
    elif event.ctrl_pressed and event.keycode == KEY_Z:
        _on_undo(); get_viewport().set_input_as_handled()
    elif event.ctrl_pressed and event.keycode == KEY_Y:
        _on_redo(); get_viewport().set_input_as_handled()
    elif event.keycode == KEY_DELETE and selected != null:
        _push_undo(); _delete(selected); selected = null
        _refresh_inspector(); canvas.queue_redraw()
        get_viewport().set_input_as_handled()
    elif event.keycode == KEY_ESCAPE:
        selected = null; _refresh_inspector(); canvas.queue_redraw()
    else:
        # Number-key shortcuts for tools.
        for i in range(TOOLS_DEF.size()):
            if event.keycode == KEY_1 + i:
                _set_tool(TOOLS_DEF[i][0])
                break
