extends Control

# Pause-menu World Map. A flat overview of every level laid out in
# rough cardinal positions; each level is a coloured rectangle whose
# tint reflects whether Tux has actually visited it (bright), heard
# of it through a load_zone connection (faded), or never seen it
# (hidden). Lines connect levels that share a load_zone in the
# currently-loaded scene, so the player can read the local exits at a
# glance.
#
# Below the map sits a list of unlocked owl-statue warps; clicking
# Warp from anywhere fades to that scene and drops the player on the
# warp's spawn marker. The pause menu (which hosts this widget) is
# unpaused before the fade so the new scene comes up without the
# overlay still visible.

const TITLE_COLOR    := Color(0.98, 0.93, 0.55, 1.0)
const LABEL_COLOR    := Color(0.92, 0.90, 0.85, 1.0)
const HINT_COLOR     := Color(0.72, 0.70, 0.65, 1.0)
const VISITED_COLOR  := Color(0.30, 0.70, 0.40, 0.95)
const KNOWN_COLOR    := Color(0.45, 0.45, 0.50, 0.55)
const HERE_BORDER    := Color(1.00, 0.92, 0.30, 1.0)
const TEXT_COLOR     := Color(0.10, 0.10, 0.12, 1.0)
const LINE_COLOR     := Color(0.85, 0.78, 0.55, 0.55)
const PANEL_BG       := Color(0.04, 0.04, 0.07, 0.85)

# col,row layout grid — see world map TODO for canonical positions.
# Cardinal: col→east, row→south. Renderer flips row so that lower row
# numbers (north) draw at the top of the panel.
const LAYOUT: Dictionary = {
    "sourceplain":   {"col":  0, "row":  0},
    "hearthold":     {"col":  0, "row": -1},
    "sigilkeep":     {"col":  0, "row": -2},
    "wyrdwood":      {"col":  0, "row":  1},
    "wyrdkin_glade": {"col":  0, "row":  2},
    "dungeon_first": {"col":  1, "row":  2},
    "brookhold":     {"col":  1, "row":  0},
    "burnt_hollow":  {"col": -1, "row":  0},
    "stoneroost":    {"col":  1, "row": -1},
    "mirelake":      {"col":  1, "row":  1},
}

# Pretty display names for the boxes. Falls back to id capitalised.
const PRETTY: Dictionary = {
    "sourceplain":   "Sourceplain",
    "hearthold":     "Hearthold",
    "sigilkeep":     "Sigilkeep",
    "wyrdwood":      "Wyrdwood",
    "wyrdkin_glade": "Wyrdkin Glade",
    "dungeon_first": "Hollow of the Wyrd",
    "brookhold":     "Brookhold",
    "burnt_hollow":  "Burnt Hollow",
    "stoneroost":    "Stoneroost",
    "mirelake":      "Mirelake",
}

const BOX_SIZE:    Vector2 = Vector2(140, 64)
const CELL_SIZE:   Vector2 = Vector2(180, 110)
const MAP_PADDING: float   = 24.0

var _map_panel:    Control = null
var _warp_list:    VBoxContainer = null
var _connections:  Array = []     # list of (id_a, id_b)


func _ready() -> void:
    anchor_right  = 1.0
    anchor_bottom = 1.0
    mouse_filter  = Control.MOUSE_FILTER_PASS
    _build_ui()
    if GameState.has_signal("warps_changed"):
        GameState.warps_changed.connect(_rebuild_warp_list)
    if GameState.has_signal("visited_changed"):
        GameState.visited_changed.connect(_on_visited)


func _build_ui() -> void:
    var bg := ColorRect.new()
    bg.color = PANEL_BG
    bg.anchor_right = 1.0
    bg.anchor_bottom = 1.0
    add_child(bg)

    var title := Label.new()
    title.text = "World Map"
    title.add_theme_font_size_override("font_size", 22)
    title.add_theme_color_override("font_color", TITLE_COLOR)
    title.offset_left = 16.0
    title.offset_top  = 8.0
    title.offset_right  = 600.0
    title.offset_bottom = 40.0
    add_child(title)

    # Map panel — left half of the widget.
    _map_panel = Control.new()
    _map_panel.anchor_left  = 0.0
    _map_panel.anchor_right = 0.65
    _map_panel.anchor_top    = 0.0
    _map_panel.anchor_bottom = 1.0
    _map_panel.offset_left   = 16.0
    _map_panel.offset_right  = -8.0
    _map_panel.offset_top    = 48.0
    _map_panel.offset_bottom = -16.0
    _map_panel.mouse_filter  = Control.MOUSE_FILTER_PASS
    _map_panel.draw.connect(_draw_map)
    add_child(_map_panel)

    # Warp side-panel — right portion.
    var side := Control.new()
    side.anchor_left   = 0.65
    side.anchor_right  = 1.0
    side.anchor_top    = 0.0
    side.anchor_bottom = 1.0
    side.offset_left   = 8.0
    side.offset_right  = -16.0
    side.offset_top    = 48.0
    side.offset_bottom = -16.0
    add_child(side)

    var warp_title := Label.new()
    warp_title.text = "Owl Statue Warps"
    warp_title.add_theme_font_size_override("font_size", 18)
    warp_title.add_theme_color_override("font_color", TITLE_COLOR)
    warp_title.offset_left = 0.0
    warp_title.offset_top  = 0.0
    warp_title.offset_right  = 320.0
    warp_title.offset_bottom = 28.0
    side.add_child(warp_title)

    var scroll := ScrollContainer.new()
    scroll.anchor_left  = 0.0
    scroll.anchor_right = 1.0
    scroll.anchor_top    = 0.0
    scroll.anchor_bottom = 1.0
    scroll.offset_top    = 36.0
    side.add_child(scroll)

    _warp_list = VBoxContainer.new()
    _warp_list.add_theme_constant_override("separation", 6)
    _warp_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(_warp_list)

    _gather_connections()
    _rebuild_warp_list()
    _map_panel.queue_redraw()


# ---- Map drawing --------------------------------------------------------

func _draw_map() -> void:
    var here := _current_scene_id()
    var rect_size: Vector2 = _map_panel.size
    if rect_size.x <= 0 or rect_size.y <= 0:
        return

    # Compute the integer extents of the layout so we can centre it
    # inside _map_panel regardless of which positions are populated.
    var min_col: int =  9999
    var max_col: int = -9999
    var min_row: int =  9999
    var max_row: int = -9999
    for sid in LAYOUT.keys():
        var c: int = int(LAYOUT[sid].col)
        var r: int = int(LAYOUT[sid].row)
        min_col = min(min_col, c); max_col = max(max_col, c)
        min_row = min(min_row, r); max_row = max(max_row, r)
    var grid_w: float = (max_col - min_col + 1) * CELL_SIZE.x
    var grid_h: float = (max_row - min_row + 1) * CELL_SIZE.y
    var origin := Vector2(
        (rect_size.x - grid_w) * 0.5,
        (rect_size.y - grid_h) * 0.5)

    # Resolve each scene's screen rectangle once so connection lines
    # land on box centres without re-derivation.
    var rects: Dictionary = {}
    for sid in LAYOUT.keys():
        var c2: int = int(LAYOUT[sid].col)
        var r2: int = int(LAYOUT[sid].row)
        var cell_pos := Vector2(
            origin.x + (c2 - min_col) * CELL_SIZE.x + (CELL_SIZE.x - BOX_SIZE.x) * 0.5,
            origin.y + (r2 - min_row) * CELL_SIZE.y + (CELL_SIZE.y - BOX_SIZE.y) * 0.5)
        rects[sid] = Rect2(cell_pos, BOX_SIZE)

    # Connection lines first so boxes overdraw the endpoints cleanly.
    for pair in _connections:
        var a: String = String(pair[0])
        var b: String = String(pair[1])
        if not rects.has(a) or not rects.has(b):
            continue
        var ca: Vector2 = (rects[a] as Rect2).get_center()
        var cb: Vector2 = (rects[b] as Rect2).get_center()
        _map_panel.draw_line(ca, cb, LINE_COLOR, 2.0, true)

    # Boxes.
    for sid in LAYOUT.keys():
        var rec: Rect2 = rects[sid]
        var visited: bool = GameState.is_visited(sid) if GameState.has_method("is_visited") \
                            else bool(GameState.visited_scenes.get(sid, false))
        var color: Color = VISITED_COLOR if visited else KNOWN_COLOR
        # Adjacent to current scene? Always considered "known" so even
        # an undiscovered neighbour shows up faintly. The LAYOUT itself
        # already enumerates every known level, so we just always draw
        # them. (If we ever want truly-hidden levels, gate them here.)
        _map_panel.draw_rect(rec, color, true)
        if sid == here:
            _map_panel.draw_rect(rec, HERE_BORDER, false, 3.0)
        else:
            _map_panel.draw_rect(rec, Color(0, 0, 0, 1), false, 1.0)

        var label_text: String = String(PRETTY.get(sid, sid.capitalize()))
        var fnt: Font = ThemeDB.fallback_font
        var fs: int   = 14
        var tsize: Vector2 = fnt.get_string_size(label_text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
        var text_pos := rec.position + Vector2(
            (rec.size.x - tsize.x) * 0.5,
            (rec.size.y + fs) * 0.5 - 6.0)
        _map_panel.draw_string(fnt, text_pos, label_text,
                               HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT_COLOR)
        if sid == here:
            var tag := "YOU ARE HERE"
            var tsize2: Vector2 = fnt.get_string_size(tag, HORIZONTAL_ALIGNMENT_CENTER, -1, 11)
            var tag_pos := rec.position + Vector2(
                (rec.size.x - tsize2.x) * 0.5,
                rec.size.y + 14.0)
            _map_panel.draw_string(fnt, tag_pos, tag,
                                   HORIZONTAL_ALIGNMENT_LEFT, -1, 11, HERE_BORDER)


# ---- Connections --------------------------------------------------------

func _gather_connections() -> void:
    # Only the current scene has its load_zones resident in the scene
    # tree. We walk those once at build time so the map can show local
    # exits as lines. Cross-scene connections will accumulate naturally
    # as the player roams (each scene contributes its own exits when
    # the world map is opened from there).
    _connections.clear()
    var here: String = _current_scene_id()
    if here == "":
        return
    var root: Node = get_tree().current_scene
    if root == null:
        return
    var seen: Dictionary = {}
    var stack: Array = [root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n == null:
            continue
        var s: Script = n.get_script()
        var sp: String = s.resource_path if s != null else ""
        if sp.ends_with("load_zone.gd"):
            var tgt: String = String(n.get("target_scene"))
            tgt = tgt.get_file().get_basename()
            if tgt != "" and tgt != here:
                var key := "%s|%s" % [here, tgt] if here < tgt else "%s|%s" % [tgt, here]
                if not seen.has(key):
                    seen[key] = true
                    _connections.append([here, tgt])
        for c in n.get_children():
            stack.append(c)


# ---- Warp list ----------------------------------------------------------

func _rebuild_warp_list() -> void:
    if _warp_list == null:
        return
    for child in _warp_list.get_children():
        child.queue_free()
    var warps: Array = GameState.get_unlocked_warps()
    if warps.is_empty():
        var none := Label.new()
        none.text = "No owls awakened yet."
        none.add_theme_color_override("font_color", HINT_COLOR)
        _warp_list.add_child(none)
        return
    for w in warps:
        var row := HBoxContainer.new()
        row.add_theme_constant_override("separation", 8)
        var lbl := Label.new()
        lbl.text = String(w.get("name", w.get("id", "?")))
        lbl.add_theme_color_override("font_color", LABEL_COLOR)
        lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        row.add_child(lbl)
        var btn := Button.new()
        btn.text = "Warp"
        btn.custom_minimum_size = Vector2(80, 28)
        var captured: Dictionary = w.duplicate(true)
        btn.pressed.connect(func(): _warp_to(captured))
        row.add_child(btn)
        _warp_list.add_child(row)


func _warp_to(w: Dictionary) -> void:
    var scene_id: String = String(w.get("scene", ""))
    if scene_id == "":
        return
    var spawn_id: String = String(w.get("spawn", "default"))
    GameState.next_spawn_id = spawn_id
    var scene_path: String = scene_id
    if not scene_path.begins_with("res://"):
        scene_path = "res://scenes/%s.tscn" % scene_id
    # Unpause + restore mouse so the destination scene comes up cleanly.
    get_tree().paused = false
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    SceneFader.change_scene(scene_path)


# ---- Plumbing -----------------------------------------------------------

func _on_visited(_sid: String) -> void:
    if _map_panel:
        _map_panel.queue_redraw()


func _current_scene_id() -> String:
    var root: Node = get_tree().current_scene
    if root == null:
        return ""
    var p: String = root.scene_file_path
    if p.begins_with("res://scenes/"):
        p = p.substr("res://scenes/".length())
    if p.ends_with(".tscn"):
        p = p.substr(0, p.length() - ".tscn".length())
    return p
