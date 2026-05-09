extends CanvasLayer

# OoT-style pause overlay with four tabs: Items, Equipment, Map, Save.
# Built procedurally — no companion .tscn beyond the script attachment
# from each dungeon scene. Esc toggles pause; ui_left / ui_right cycle
# tabs; clicking a tab also switches.
#
# Visual style is intentionally minimal — pale-yellow titles on a dark
# translucent backdrop, monospace labels — because we have no art
# assets yet.

@export var menu_scene: String = "res://scenes/main_menu.tscn"

const BACKDROP_COLOR := Color(0.05, 0.04, 0.08, 0.85)
const TITLE_COLOR := Color(0.98, 0.93, 0.55, 1.0)
const TAB_COLOR := Color(0.20, 0.18, 0.26, 0.95)
const TAB_ACTIVE_COLOR := Color(0.40, 0.34, 0.18, 1.0)
const LABEL_COLOR := Color(0.92, 0.90, 0.85, 1.0)
const LOCKED_COLOR := Color(0.55, 0.52, 0.48, 1.0)
const EQUIPPED_BORDER := Color(1.00, 0.85, 0.20, 1.0)

const TAB_NAMES: Array[String] = ["Items", "Equipment", "Map", "Save"]
const TABS_ITEMS: int = 0
const TABS_EQUIPMENT: int = 1
const TABS_MAP: int = 2
const TABS_SAVE: int = 3

const ITEM_TILE_SIZE: Vector2 = Vector2(96, 96)
const ITEMS_PER_ROW: int = 6

# Items the player can ever own (besides Sword which is always granted).
const KNOWN_ITEMS: Array[String] = [
    "boomerang", "bombs", "bow", "lantern", "hookshot", "pebbles",
]

const EQUIPMENT_SLOTS: Array[String] = ["sword", "shield", "boomerang"]

var _root: Control
var _backdrop: ColorRect
var _tab_strip: HBoxContainer
var _tab_buttons: Array[Button] = []
var _content_holder: Control
var _current_tab: int = TABS_ITEMS

# Map-tab mini-map (a child Control instance using mini_map.gd).
var _map_widget: Control = null
# Items-tab tile lookup so we can refresh the equipped border without
# rebuilding the grid.
var _item_tiles: Dictionary = {}    # name → ColorRect (border)

var _was_mouse_captured: bool = false


func _ready() -> void:
    layer = 80
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    _root.visible = false
    GameState.item_acquired.connect(_on_inventory_changed)
    GameState.active_item_changed.connect(_on_active_item_changed)


func _input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_cancel"):
        get_viewport().set_input_as_handled()
        if _root.visible:
            _resume()
        else:
            _pause()
        return
    if not _root.visible:
        return
    if event.is_action_pressed("ui_right"):
        get_viewport().set_input_as_handled()
        _set_tab((_current_tab + 1) % TAB_NAMES.size())
    elif event.is_action_pressed("ui_left"):
        get_viewport().set_input_as_handled()
        _set_tab((_current_tab - 1 + TAB_NAMES.size()) % TAB_NAMES.size())


func _pause() -> void:
    _root.visible = true
    get_tree().paused = true
    _was_mouse_captured = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    _refresh_current_tab()


func _resume() -> void:
    _root.visible = false
    get_tree().paused = false
    if _was_mouse_captured:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_quit_to_title() -> void:
    get_tree().paused = false
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().change_scene_to_file(menu_scene)


# ---- UI construction ----------------------------------------------------

func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_right = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_root)

    _backdrop = ColorRect.new()
    _backdrop.color = BACKDROP_COLOR
    _backdrop.anchor_right = 1.0
    _backdrop.anchor_bottom = 1.0
    _root.add_child(_backdrop)

    var title := Label.new()
    title.text = "PAUSED"
    title.anchor_left = 0.5
    title.anchor_right = 0.5
    title.offset_left = -120.0
    title.offset_right = 120.0
    title.offset_top = 12.0
    title.offset_bottom = 56.0
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 32)
    title.add_theme_color_override("font_color", TITLE_COLOR)
    _root.add_child(title)

    _tab_strip = HBoxContainer.new()
    _tab_strip.alignment = BoxContainer.ALIGNMENT_CENTER
    _tab_strip.add_theme_constant_override("separation", 12)
    _tab_strip.anchor_left = 0.0
    _tab_strip.anchor_right = 1.0
    _tab_strip.offset_top = 64.0
    _tab_strip.offset_bottom = 104.0
    _root.add_child(_tab_strip)
    for i in TAB_NAMES.size():
        var b := Button.new()
        b.text = TAB_NAMES[i]
        b.custom_minimum_size = Vector2(140, 36)
        b.add_theme_font_size_override("font_size", 18)
        b.pressed.connect(_set_tab.bind(i))
        _tab_strip.add_child(b)
        _tab_buttons.append(b)

    _content_holder = Control.new()
    _content_holder.anchor_left = 0.0
    _content_holder.anchor_right = 1.0
    _content_holder.anchor_bottom = 1.0
    _content_holder.offset_top = 116.0
    _content_holder.offset_left = 32.0
    _content_holder.offset_right = -32.0
    _content_holder.offset_bottom = -64.0
    _root.add_child(_content_holder)

    var hint := Label.new()
    hint.text = "[A]/[D] tabs   [Esc] resume"
    hint.anchor_left = 0.0
    hint.anchor_top = 1.0
    hint.anchor_right = 1.0
    hint.anchor_bottom = 1.0
    hint.offset_top = -36.0
    hint.offset_bottom = -8.0
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.add_theme_color_override("font_color", LABEL_COLOR)
    _root.add_child(hint)

    _set_tab(TABS_ITEMS)


# ---- Tab switching ------------------------------------------------------

func _set_tab(idx: int) -> void:
    _current_tab = idx
    for i in _tab_buttons.size():
        var btn: Button = _tab_buttons[i]
        var sb := StyleBoxFlat.new()
        sb.bg_color = TAB_ACTIVE_COLOR if i == idx else TAB_COLOR
        sb.set_corner_radius_all(6)
        btn.add_theme_stylebox_override("normal", sb)
        btn.add_theme_stylebox_override("hover", sb)
        btn.add_theme_stylebox_override("pressed", sb)
    _refresh_current_tab()


func _refresh_current_tab() -> void:
    for child in _content_holder.get_children():
        child.queue_free()
    _item_tiles.clear()
    _map_widget = null
    match _current_tab:
        TABS_ITEMS: _build_items_tab()
        TABS_EQUIPMENT: _build_equipment_tab()
        TABS_MAP: _build_map_tab()
        TABS_SAVE: _build_save_tab()


# ---- Items tab ----------------------------------------------------------

func _build_items_tab() -> void:
    var heading := Label.new()
    heading.text = "Items — click to set as B-button"
    heading.add_theme_color_override("font_color", TITLE_COLOR)
    heading.add_theme_font_size_override("font_size", 20)
    _content_holder.add_child(heading)

    var grid := GridContainer.new()
    grid.columns = ITEMS_PER_ROW
    grid.anchor_left = 0.0
    grid.anchor_right = 1.0
    grid.offset_top = 36.0
    grid.add_theme_constant_override("h_separation", 12)
    grid.add_theme_constant_override("v_separation", 12)
    _content_holder.add_child(grid)

    # Sword: always known, always selected, can't unequip.
    grid.add_child(_make_item_tile("sword", true, true, false))

    # Inventory items.
    for name in KNOWN_ITEMS:
        var owned: bool = GameState.has_item(name)
        var equipped: bool = (GameState.active_b_item == name)
        grid.add_child(_make_item_tile(name, owned, equipped, true))


func _make_item_tile(name: String, owned: bool, equipped: bool,
                     equippable: bool) -> Control:
    var box := Control.new()
    box.custom_minimum_size = ITEM_TILE_SIZE

    var bg := ColorRect.new()
    bg.color = (Color(0.18, 0.16, 0.22, 1) if owned
                else Color(0.10, 0.09, 0.13, 1))
    bg.anchor_right = 1.0
    bg.anchor_bottom = 1.0
    box.add_child(bg)

    var border := ColorRect.new()
    border.color = (EQUIPPED_BORDER if equipped
                    else Color(0.30, 0.28, 0.34, 1))
    border.anchor_right = 1.0
    border.anchor_bottom = 1.0
    border.mouse_filter = Control.MOUSE_FILTER_IGNORE
    # Hollow border via a thinner inner ColorRect.
    box.add_child(border)
    var inner := ColorRect.new()
    inner.color = bg.color
    inner.anchor_left = 0.0
    inner.anchor_top = 0.0
    inner.anchor_right = 1.0
    inner.anchor_bottom = 1.0
    inner.offset_left = 3.0
    inner.offset_top = 3.0
    inner.offset_right = -3.0
    inner.offset_bottom = -3.0
    inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
    box.add_child(inner)
    _item_tiles[name] = border

    var label := Label.new()
    label.text = name.capitalize()
    label.anchor_right = 1.0
    label.anchor_bottom = 1.0
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.add_theme_font_size_override("font_size", 14)
    if owned:
        label.add_theme_color_override("font_color", LABEL_COLOR)
    else:
        label.add_theme_color_override("font_color", LOCKED_COLOR)
        label.text = "[%s]" % name.capitalize()
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    box.add_child(label)

    if owned and equippable:
        var btn := Button.new()
        btn.flat = true
        btn.anchor_right = 1.0
        btn.anchor_bottom = 1.0
        btn.tooltip_text = "Equip %s" % name
        btn.pressed.connect(_on_item_clicked.bind(name))
        box.add_child(btn)
    return box


func _on_item_clicked(name: String) -> void:
    if name == "sword":
        return    # always selected, can't unequip
    GameState.set_active_b_item(name)


func _on_active_item_changed(_name: String) -> void:
    if _current_tab == TABS_ITEMS and _root.visible:
        _refresh_current_tab()


func _on_inventory_changed(_name: String) -> void:
    if _current_tab == TABS_ITEMS and _root.visible:
        _refresh_current_tab()


# ---- Equipment tab ------------------------------------------------------

func _build_equipment_tab() -> void:
    var heading := Label.new()
    heading.text = "Equipment"
    heading.add_theme_color_override("font_color", TITLE_COLOR)
    heading.add_theme_font_size_override("font_size", 20)
    _content_holder.add_child(heading)

    var list := VBoxContainer.new()
    list.add_theme_constant_override("separation", 8)
    list.offset_top = 36.0
    list.anchor_right = 1.0
    list.anchor_bottom = 1.0
    list.offset_top = 36.0
    _content_holder.add_child(list)

    for slot in EQUIPMENT_SLOTS:
        var row := HBoxContainer.new()
        row.add_theme_constant_override("separation", 12)
        var name_label := Label.new()
        name_label.text = slot.capitalize()
        name_label.custom_minimum_size = Vector2(180, 0)
        name_label.add_theme_font_size_override("font_size", 18)
        var status_label := Label.new()
        var owned: bool = (slot == "sword") or GameState.has_item(slot)
        if owned:
            status_label.text = "acquired"
            name_label.add_theme_color_override("font_color", LABEL_COLOR)
            status_label.add_theme_color_override("font_color", TITLE_COLOR)
        else:
            status_label.text = "locked"
            name_label.add_theme_color_override("font_color", LOCKED_COLOR)
            status_label.add_theme_color_override("font_color", LOCKED_COLOR)
        status_label.add_theme_font_size_override("font_size", 18)
        row.add_child(name_label)
        row.add_child(status_label)
        list.add_child(row)


# ---- Map tab ------------------------------------------------------------

func _build_map_tab() -> void:
    var heading := Label.new()
    heading.text = "Map"
    heading.add_theme_color_override("font_color", TITLE_COLOR)
    heading.add_theme_font_size_override("font_size", 20)
    _content_holder.add_child(heading)

    # World-map sub-button: opens the cross-level overview + warp list
    # in place of the level mini-map. Sits to the right of the heading
    # so the local mini-map is the default at-a-glance view.
    var world_btn := Button.new()
    world_btn.text = "World"
    world_btn.custom_minimum_size = Vector2(110, 28)
    world_btn.add_theme_font_size_override("font_size", 14)
    world_btn.anchor_left  = 1.0
    world_btn.anchor_right = 1.0
    world_btn.offset_left  = -120.0
    world_btn.offset_right = -8.0
    world_btn.offset_top   = 0.0
    world_btn.offset_bottom = 28.0
    world_btn.pressed.connect(_show_world_map)
    _content_holder.add_child(world_btn)

    var map_packed: PackedScene = load("res://scenes/mini_map.tscn")
    if map_packed == null:
        var err := Label.new()
        err.text = "(map widget unavailable)"
        err.offset_top = 36.0
        _content_holder.add_child(err)
        return
    var map: Control = map_packed.instantiate()
    # Big — takes up most of the content area, centred horizontally.
    var size_px: Vector2 = Vector2(640, 640)
    map.custom_minimum_size = size_px
    map.size = size_px
    map.anchor_left = 0.5
    map.anchor_right = 0.5
    map.offset_left = -size_px.x * 0.5
    map.offset_right = size_px.x * 0.5
    map.offset_top = 40.0
    map.offset_bottom = 40.0 + size_px.y
    # Centre on level bbox; render every cell at 200% zoom relative to
    # the mini-map's default radius.
    map.set("centered_on_player", false)
    map.set("view_radius_meters", 30.0)
    map.set("render_radius_meters", 9999.0)
    _content_holder.add_child(map)
    _map_widget = map

    # Show neighbouring level names at the borders if the scene has any
    # LoadZones — small text labels along the bottom of the map.
    var zones: Array = _find_load_zones()
    if not zones.is_empty():
        var zone_box := VBoxContainer.new()
        zone_box.anchor_left = 0.0
        zone_box.anchor_right = 1.0
        zone_box.anchor_top = 1.0
        zone_box.anchor_bottom = 1.0
        zone_box.offset_top = -100.0
        zone_box.offset_bottom = -8.0
        zone_box.offset_left = 16.0
        zone_box.offset_right = -16.0
        zone_box.add_theme_constant_override("separation", 2)
        var z_title := Label.new()
        z_title.text = "Exits:"
        z_title.add_theme_color_override("font_color", TITLE_COLOR)
        zone_box.add_child(z_title)
        for z in zones:
            var lbl := Label.new()
            var target: String = String(z.get("target_scene"))
            target = target.get_file().get_basename()
            lbl.text = "  -> %s" % target
            lbl.add_theme_color_override("font_color", LABEL_COLOR)
            zone_box.add_child(lbl)
        _content_holder.add_child(zone_box)


func _show_world_map() -> void:
    # Replace the Map tab's contents with the WorldMap widget. We
    # don't change tabs; the user came here through Map, and the World
    # view is conceptually a Map sub-mode. _refresh_current_tab() rebuilds
    # the local view if they leave and return.
    for child in _content_holder.get_children():
        child.queue_free()
    _map_widget = null

    var heading := Label.new()
    heading.text = "World Map"
    heading.add_theme_color_override("font_color", TITLE_COLOR)
    heading.add_theme_font_size_override("font_size", 20)
    _content_holder.add_child(heading)

    var back_btn := Button.new()
    back_btn.text = "Back"
    back_btn.custom_minimum_size = Vector2(110, 28)
    back_btn.add_theme_font_size_override("font_size", 14)
    back_btn.anchor_left  = 1.0
    back_btn.anchor_right = 1.0
    back_btn.offset_left  = -120.0
    back_btn.offset_right = -8.0
    back_btn.offset_top   = 0.0
    back_btn.offset_bottom = 28.0
    back_btn.pressed.connect(_refresh_current_tab)
    _content_holder.add_child(back_btn)

    var packed: PackedScene = load("res://scenes/world_map.tscn")
    if packed == null:
        var err := Label.new()
        err.text = "(world map unavailable)"
        err.offset_top = 36.0
        _content_holder.add_child(err)
        return
    var widget: Control = packed.instantiate()
    widget.anchor_left  = 0.0
    widget.anchor_right = 1.0
    widget.anchor_top    = 0.0
    widget.anchor_bottom = 1.0
    widget.offset_left   = 0.0
    widget.offset_right  = 0.0
    widget.offset_top    = 36.0
    widget.offset_bottom = 0.0
    _content_holder.add_child(widget)


func _find_load_zones() -> Array:
    var out: Array = []
    var root: Node = get_tree().current_scene
    if root == null:
        return out
    var stack: Array = [root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n == null:
            continue
        # Duck-type: the LoadZone script exposes `target_scene`.
        var script_path: String = ""
        var s: Script = n.get_script()
        if s != null:
            script_path = s.resource_path
        if script_path.ends_with("load_zone.gd"):
            out.append(n)
        for c in n.get_children():
            stack.append(c)
    return out


# ---- Save tab -----------------------------------------------------------

func _build_save_tab() -> void:
    var heading := Label.new()
    heading.text = "Save"
    heading.add_theme_color_override("font_color", TITLE_COLOR)
    heading.add_theme_font_size_override("font_size", 20)
    _content_holder.add_child(heading)

    var btn := Button.new()
    btn.text = "Save Game"
    btn.custom_minimum_size = Vector2(220, 40)
    btn.add_theme_font_size_override("font_size", 18)
    btn.offset_top = 56.0
    btn.offset_left = 0.0
    btn.offset_right = 220.0
    btn.offset_bottom = 96.0
    btn.pressed.connect(_on_save_pressed)
    _content_holder.add_child(btn)

    var status := Label.new()
    status.name = "SaveStatus"
    status.text = ""
    status.offset_top = 108.0
    status.add_theme_color_override("font_color", LABEL_COLOR)
    _content_holder.add_child(status)

    var quit_btn := Button.new()
    quit_btn.text = "Quit to Title"
    quit_btn.custom_minimum_size = Vector2(220, 40)
    quit_btn.add_theme_font_size_override("font_size", 18)
    quit_btn.offset_top = 152.0
    quit_btn.offset_left = 0.0
    quit_btn.offset_right = 220.0
    quit_btn.offset_bottom = 192.0
    quit_btn.pressed.connect(_on_quit_to_title)
    _content_holder.add_child(quit_btn)


func _on_save_pressed() -> void:
    var status: Label = _content_holder.get_node_or_null("SaveStatus") as Label
    if GameState.last_slot < 0:
        if status:
            status.text = "No save slot bound."
        return
    if GameState.save_game(GameState.last_slot):
        if status:
            status.text = "Saved to slot %d." % (GameState.last_slot + 1)
    else:
        if status:
            status.text = "Save failed."
