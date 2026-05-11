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

# Tab list is built lazily in _build_tab_strip(): the Songs tab only
# appears once Tux has learned at least one song. The static names list
# below is the full possible set, in order; `_visible_tabs` is the
# subset actually rendered this open.
const TAB_NAMES: Array[String] = ["Items", "Equipment", "Songs", "Map", "Save", "Trophies"]
const TABS_ITEMS: int = 0
const TABS_EQUIPMENT: int = 1
const TABS_SONGS: int = 2
const TABS_MAP: int = 3
const TABS_SAVE: int = 4
const TABS_TROPHIES: int = 5

# OoT-parity trophy panel. The boss list is canonical (one entry per
# major boss); names match the GameState.bosses_defeated keys produced
# by the boss death paths (see DESIGN.md). Songs come from SongBook.
# Sword tier names align with sword_tier (0..2).
const TROPHY_BOSSES: Array[Dictionary] = [
    {"id": "wyrdking",       "name": "Wyrdking Bonelord"},
    {"id": "codex_knight",   "name": "Codex Knight"},
    {"id": "gale_roost",     "name": "Gale Roost"},
    {"id": "cinder_tomato",  "name": "Cinder Tomato"},
    {"id": "forge_wyrm",     "name": "Forge Wyrm"},
    {"id": "backwater_maw",  "name": "Backwater Maw"},
    {"id": "censor",         "name": "Censor"},
    {"id": "init",           "name": "Init the Sleeper"},
]
const SWORD_TIER_NAMES: Array[String] = ["Twigblade", "Brightsteel", "Glimblade"]

const SONG_INPUT_SCENE := "res://scenes/song_input.tscn"

const ITEM_TILE_SIZE: Vector2 = Vector2(96, 96)
const ITEMS_PER_ROW: int = 6

# Items the player can ever own (besides Sword which is always granted).
# Anchor Boots and Glim Mirror are passive — they appear in the grid as
# acquired-but-not-equippable tiles (Anchor Boots gets a separate ON/OFF
# toggle row beneath the grid; Glim Mirror is always-on).
const KNOWN_ITEMS: Array[String] = [
    "boomerang", "bombs", "bow", "lantern", "hookshot", "pebbles",
    "hammer", "glim_sight", "anchor_boots", "glim_mirror",
]

# Items in KNOWN_ITEMS that are passive (no B-button slot). Click is a
# no-op for these — they live in the grid for visibility, not equip.
const PASSIVE_ITEMS: Array[String] = ["anchor_boots", "glim_mirror"]

# Permanent equipment slots — Tux starts with all of these. Shown in
# the Items tab "Equipment" section. Boomerang is NOT here — it's a
# B-button selectable item from KNOWN_ITEMS, displayed in the equippable
# grid above. (Earlier it was double-listed and showed "locked" until
# the player picked up the actual boomerang pickup.)
const EQUIPMENT_SLOTS: Array[String] = ["sword", "shield"]
const STARTING_EQUIPMENT: Array[String] = ["sword", "shield"]

var _root: Control
var _backdrop: ColorRect
var _tab_strip: HBoxContainer
var _tab_buttons: Array[Button] = []
var _content_holder: Control
var _current_tab: int = TABS_ITEMS
# Indices (into TAB_NAMES) of the tabs actually shown right now. Songs
# is filtered out until at least one song is known.
var _visible_tabs: Array[int] = []

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
    # Global Z = open the song picker, regardless of pause state. We
    # listen on raw KEY_Z (not via InputMap) to keep the action list in
    # project.godot uncluttered for now; the picker handles its own
    # pause/unpause and dismisses cleanly.
    if event is InputEventKey and event.pressed and not event.echo \
            and (event as InputEventKey).keycode == KEY_Z:
        if not Dialog.is_active():
            get_viewport().set_input_as_handled()
            _open_song_input()
            return
    if not _root.visible:
        return
    if event.is_action_pressed("ui_right"):
        get_viewport().set_input_as_handled()
        _cycle_tab(1)
    elif event.is_action_pressed("ui_left"):
        get_viewport().set_input_as_handled()
        _cycle_tab(-1)


func _cycle_tab(delta: int) -> void:
    if _visible_tabs.is_empty():
        return
    var pos: int = _visible_tabs.find(_current_tab)
    if pos < 0:
        pos = 0
    pos = (pos + delta + _visible_tabs.size()) % _visible_tabs.size()
    _set_tab(_visible_tabs[pos])


func _pause() -> void:
    _root.visible = true
    get_tree().paused = true
    _was_mouse_captured = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    # Rebuild the tab strip so the Songs tab appears the moment a song
    # is learned mid-run (e.g. the player just spoke to Glim and immediately
    # opened the menu). Cheap — five buttons.
    _build_tab_strip()
    if not _visible_tabs.has(_current_tab):
        _current_tab = _visible_tabs[0] if not _visible_tabs.is_empty() \
                                        else TABS_ITEMS
    _set_tab(_current_tab)


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
    _build_tab_strip()

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
    hint.text = "[A]/[D] tabs   [Z] hum a song   [Esc] resume"
    hint.anchor_left = 0.0
    hint.anchor_top = 1.0
    hint.anchor_right = 1.0
    hint.anchor_bottom = 1.0
    hint.offset_top = -36.0
    hint.offset_bottom = -8.0
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.add_theme_color_override("font_color", LABEL_COLOR)
    _root.add_child(hint)

    _build_tab_strip()
    _set_tab(_visible_tabs[0] if not _visible_tabs.is_empty() else TABS_ITEMS)


func _build_tab_strip() -> void:
    # Recompute which tabs to show. Songs is conditional; everything
    # else is always present. Idempotent — wipes the strip first.
    for child in _tab_strip.get_children():
        child.queue_free()
    _tab_buttons.clear()
    _visible_tabs.clear()
    for i in TAB_NAMES.size():
        if i == TABS_SONGS and GameState.songs_known.is_empty():
            continue
        _visible_tabs.append(i)
        var b := Button.new()
        b.text = TAB_NAMES[i]
        b.custom_minimum_size = Vector2(140, 36)
        b.add_theme_font_size_override("font_size", 18)
        b.pressed.connect(_set_tab.bind(i))
        _tab_strip.add_child(b)
        _tab_buttons.append(b)


# ---- Tab switching ------------------------------------------------------

func _set_tab(idx: int) -> void:
    _current_tab = idx
    # Highlight only the currently-active tab. _tab_buttons aligns 1:1
    # with _visible_tabs (they're built together in _build_tab_strip).
    for i in _tab_buttons.size():
        var tab_idx: int = _visible_tabs[i] if i < _visible_tabs.size() else -1
        var btn: Button = _tab_buttons[i]
        var sb := StyleBoxFlat.new()
        sb.bg_color = TAB_ACTIVE_COLOR if tab_idx == idx else TAB_COLOR
        sb.set_corner_radius_all(6)
        btn.add_theme_stylebox_override("normal", sb)
        btn.add_theme_stylebox_override("hover", sb)
        btn.add_theme_stylebox_override("pressed", sb)
    _refresh_current_tab()


func _open_song_input() -> void:
    # Spawn the picker into the active scene so it survives even if the
    # pause-menu CanvasLayer were ever culled (it isn't today, but keep
    # the lifetime decoupled). The picker pauses the tree itself.
    var packed: PackedScene = load(SONG_INPUT_SCENE) as PackedScene
    if packed == null:
        push_warning("PauseMenu: cannot load %s" % SONG_INPUT_SCENE)
        return
    var holder: Node = get_tree().current_scene
    if holder == null:
        holder = self
    holder.add_child(packed.instantiate())


func _refresh_current_tab() -> void:
    for child in _content_holder.get_children():
        child.queue_free()
    _item_tiles.clear()
    _map_widget = null
    match _current_tab:
        TABS_ITEMS: _build_items_tab()
        TABS_EQUIPMENT: _build_equipment_tab()
        TABS_SONGS: _build_songs_tab()
        TABS_MAP: _build_map_tab()
        TABS_SAVE: _build_save_tab()
        TABS_TROPHIES: _build_trophies_tab()


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

    # Inventory items. Passive items render as owned-but-not-equippable
    # so the player can see they exist without being able to bind them
    # to the B-button (which would be meaningless for a passive).
    for name in KNOWN_ITEMS:
        var owned: bool = GameState.has_item(name)
        var equipped: bool = (GameState.active_b_item == name)
        var equippable: bool = not PASSIVE_ITEMS.has(name)
        grid.add_child(_make_item_tile(name, owned, equipped, equippable))

    # Anchor Boots toggle row — only appears once Tux owns the boots.
    # Sits below the grid so it's discoverable without crowding the
    # equipment tiles. Toggling fires the metal-step SFX (silent-fallback
    # to step.wav today; see sound_bank.gd).
    if GameState.has_item("anchor_boots"):
        var boots_row := _make_anchor_boots_row()
        # Place it directly below the items grid using anchor offsets;
        # we live alongside the consumables row at offset_top ~ ITEM_TILE+72.
        boots_row.offset_top = 36.0 + ITEM_TILE_SIZE.y * 2 + 56.0
        boots_row.offset_bottom = boots_row.offset_top + 32.0
        boots_row.anchor_left = 0.0
        boots_row.anchor_right = 1.0
        _content_holder.add_child(boots_row)

    # Consumable counts — separate row beneath the equip grid. Pulls
    # straight from GameState so the page reflects what's in the bag
    # the moment you open the menu, including stuff (fairy bottles,
    # ammo) that isn't B-button-equippable.
    var consumables := Label.new()
    consumables.add_theme_font_size_override("font_size", 16)
    consumables.add_theme_color_override("font_color", LABEL_COLOR)
    consumables.offset_top = 36.0 + ITEM_TILE_SIZE.y * 2 + 28.0
    var lines: Array = []
    lines.append("Pebbles: %d" % GameState.pebbles)
    lines.append("Fairy bottles: %d / %d" % [GameState.fairy_bottles,
                                             GameState.max_fairy_bottles])
    if GameState.has_item("bow"):
        lines.append("Arrows: %d / %d" % [GameState.arrows, GameState.max_arrows])
    if GameState.has_item("slingshot"):
        lines.append("Seeds: %d / %d"  % [GameState.seeds,  GameState.max_seeds])
    if GameState.has_item("bombs") or GameState.bombs > 0:
        lines.append("Bombs: %d / %d"  % [GameState.bombs,  GameState.max_bombs])
    if GameState.heart_pieces > 0:
        lines.append("Heart pieces: %d / 4" % GameState.heart_pieces)
    consumables.text = "  ·  ".join(lines)
    _content_holder.add_child(consumables)


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

    # Procedural silhouette icon. ItemIcon draws a recognisable shape
    # per item id; the tile reserves the upper ~70% for the icon and
    # lets the label sit beneath it. Locked / unowned items render the
    # same silhouette dimmed so the player can preview what's coming.
    var icon := Control.new()
    icon.set_script(load("res://scripts/item_icon.gd"))
    icon.set("item_id", name)
    icon.set("dim", 1.0 if owned else 0.35)
    icon.anchor_left = 0.0
    icon.anchor_right = 1.0
    icon.anchor_top = 0.0
    icon.anchor_bottom = 1.0
    icon.offset_left = 12.0
    icon.offset_right = -12.0
    icon.offset_top = 8.0
    icon.offset_bottom = -28.0
    icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    box.add_child(icon)

    var label := Label.new()
    label.text = name.capitalize()
    label.anchor_left = 0.0
    label.anchor_right = 1.0
    label.anchor_top = 1.0
    label.anchor_bottom = 1.0
    label.offset_top = -24.0
    label.offset_bottom = -2.0
    label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    label.add_theme_font_size_override("font_size", 12)
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


# Anchor Boots ON/OFF toggle row. Built procedurally and parented under
# _content_holder so refresh_current_tab() wipes it cleanly along with
# the rest of the items page. Pressing the button flips the GameState
# flag; tux_player.gd reads the flag every physics tick.
func _make_anchor_boots_row() -> Control:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 12)
    var label := Label.new()
    label.text = "Anchor Boots:"
    label.custom_minimum_size = Vector2(180, 0)
    label.add_theme_font_size_override("font_size", 18)
    label.add_theme_color_override("font_color", LABEL_COLOR)
    row.add_child(label)
    var btn := Button.new()
    var on: bool = GameState.anchor_boots_active
    btn.text = ("ON" if on else "OFF")
    btn.custom_minimum_size = Vector2(96, 32)
    btn.add_theme_font_size_override("font_size", 16)
    btn.pressed.connect(_on_anchor_boots_toggled)
    row.add_child(btn)
    var hint := Label.new()
    hint.text = "  Heavy boots — sink in water, walk slow."
    hint.add_theme_color_override("font_color", LABEL_COLOR)
    hint.add_theme_font_size_override("font_size", 14)
    row.add_child(hint)
    return row


func _on_anchor_boots_toggled() -> void:
    GameState.anchor_boots_active = not GameState.anchor_boots_active
    # No dedicated metal-step asset yet — use the generic step SFX as
    # the fallback per spec. play_2d is silent-safe if either name is
    # missing so this can't crash a playthrough.
    SoundBank.play_2d("anchor_step")
    SoundBank.play_2d("step")
    _refresh_current_tab()


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
        var owned: bool = STARTING_EQUIPMENT.has(slot) or GameState.has_item(slot)
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


# ---- Songs tab ----------------------------------------------------------

func _build_songs_tab() -> void:
    var heading := Label.new()
    heading.text = "Songs"
    heading.add_theme_color_override("font_color", TITLE_COLOR)
    heading.add_theme_font_size_override("font_size", 20)
    _content_holder.add_child(heading)

    var hum_btn := Button.new()
    hum_btn.text = "Hum a song… [Z]"
    hum_btn.custom_minimum_size = Vector2(220, 36)
    hum_btn.add_theme_font_size_override("font_size", 16)
    hum_btn.anchor_left  = 1.0
    hum_btn.anchor_right = 1.0
    hum_btn.offset_left  = -240.0
    hum_btn.offset_right = -8.0
    hum_btn.offset_top   = 0.0
    hum_btn.offset_bottom = 36.0
    hum_btn.pressed.connect(_on_hum_pressed)
    _content_holder.add_child(hum_btn)

    var list := VBoxContainer.new()
    list.add_theme_constant_override("separation", 10)
    list.anchor_left  = 0.0
    list.anchor_right = 1.0
    list.offset_top    = 48.0
    list.offset_bottom = 0.0
    _content_holder.add_child(list)

    # Iterate the canonical SongBook order so the list reads "Glim,
    # Sun, Moon, Triglyph" instead of in learn order. Unknown songs
    # appear as "[locked]" placeholders so the player can see how many
    # songs the world actually contains.
    for song in SongBook.songs:
        var song_id: String = String(song.get("id", ""))
        var owned: bool = GameState.has_song(song_id)
        var row := HBoxContainer.new()
        row.add_theme_constant_override("separation", 16)
        var name_label := Label.new()
        name_label.custom_minimum_size = Vector2(220, 0)
        name_label.add_theme_font_size_override("font_size", 18)
        var glyph_label := Label.new()
        glyph_label.custom_minimum_size = Vector2(180, 0)
        glyph_label.add_theme_font_size_override("font_size", 22)
        # Force a monospace-ish font name; Godot's default UI font isn't
        # mono but the size override already keeps glyph spacing readable.
        var sum_label := Label.new()
        sum_label.add_theme_font_size_override("font_size", 14)
        if owned:
            name_label.text = String(song.get("name", song_id))
            glyph_label.text = SongBook.format_glyphs(song.get("glyphs", []))
            sum_label.text = String(song.get("summary", ""))
            name_label.add_theme_color_override("font_color", LABEL_COLOR)
            glyph_label.add_theme_color_override("font_color", TITLE_COLOR)
            sum_label.add_theme_color_override("font_color", LABEL_COLOR)
        else:
            name_label.text = "[ ? ? ? ]"
            glyph_label.text = "?  ?  ?  ?  ?"
            sum_label.text = "(unknown — find someone to teach you)"
            name_label.add_theme_color_override("font_color", LOCKED_COLOR)
            glyph_label.add_theme_color_override("font_color", LOCKED_COLOR)
            sum_label.add_theme_color_override("font_color", LOCKED_COLOR)
        row.add_child(name_label)
        row.add_child(glyph_label)
        row.add_child(sum_label)
        list.add_child(row)


func _on_hum_pressed() -> void:
    # Close the pause menu before the picker opens so the picker's own
    # backdrop isn't sandwiched between two dim layers (cleaner visual).
    _resume()
    _open_song_input()


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


# ---- Trophies tab (v2: shell status screen) ----------------------------
#
# Replaces the OoT-style "row of boss trophies + heart count" with a
# literal terminal session: `id`, `ls -l ~/bin`, `ls -l /`. Each binary
# row carries a tiny grant-story parenthetical so the player can see at
# a glance "where did this come from?" (default kit, boss-grant, or
# locked-with-which-boss-unlocks-it).
#
# Tab name stays "Trophies" — pause_menu's tab strip still references it
# verbatim. Only the content rendered here changes.

# Boss → (binary path, display name, grant-story snippet). The status
# screen walks this in canonical order to render the binary list. Order
# matches DESIGN.md §2's dungeon order so the player reads progression
# top-to-bottom. Default tools (kill, cd, etc.) are inserted explicitly
# above this list.
const BOSS_GRANTS: Array[Dictionary] = [
    {"boss": "wyrdking",       "boss_name": "Wyrdking",
     "binary": "~/bin/grep",          "tool": "grep",   "perm": "--x"},
    {"boss": "codex_knight",   "boss_name": "Codex Knight",
     "binary": "~/bin/find",          "tool": "find",   "perm": "--x"},
    {"boss": "gale_roost",     "boss_name": "Gale Roost",
     "binary": "~/bin/cd",            "tool": "cd",     "perm": "--x"},
    {"boss": "cinder_tomato",  "boss_name": "Cinder Tomato",
     "binary": "~/bin/rm",            "tool": "rm",     "perm": "--x"},
    {"boss": "forge_wyrm",     "boss_name": "Forge Wyrm",
     "binary": "~/bin/sort",          "tool": "sort",   "perm": "--x"},
    {"boss": "backwater_maw",  "boss_name": "Backwater Maw",
     "binary": "/usr/bin/chroot",     "tool": "chroot", "perm": "--x"},
    {"boss": "censor",         "boss_name": "Censor",
     "binary": "/usr/bin/find",       "tool": "find",   "perm": "--x"},
    {"boss": "init",           "boss_name": "Init the Sleeper",
     "binary": "/usr/bin/sudo",       "tool": "sudo",   "perm": "--s"},
]

# Default kit Tux always carries — these are listed above the boss-grant
# binaries in `ls -l ~/bin` order. Shown with "(default)" as the
# grant-story so the player understands they're not boss-locked.
const DEFAULT_BINARIES: Array[Dictionary] = [
    {"binary": "~/bin/kill",   "tool": "kill"},
    {"binary": "~/bin/cd",     "tool": "cd"},
    {"binary": "~/bin/cat",    "tool": "cat"},
    {"binary": "~/bin/chmod",  "tool": "chmod"},
    {"binary": "~/bin/ls",     "tool": "ls"},
]

# Directory grant-stories — boss → (path, label). Used to annotate the
# `ls -l /` rows that change as bosses fall. Paths NOT in this map render
# with a static "(read+exec)" / "(locked)" label depending on the perm.
const DIR_GRANTS: Array[Dictionary] = [
    {"boss": "codex_knight",   "boss_name": "Codex Knight",
     "path": "/etc",  "story": "write granted by Codex Knight"},
    {"boss": "forge_wyrm",     "boss_name": "Forge Wyrm",
     "path": "/dev",  "story": "Forge Wyrm grants rwx"},
]

const STATUS_FONT_SIZE: int = 18
const STATUS_HEADING_SIZE: int = 20

func _build_trophies_tab() -> void:
    # Use a ScrollContainer + VBox so a deep status screen (16 dirs +
    # 13 binaries + headings) doesn't run off the bottom of the pane.
    var scroll := ScrollContainer.new()
    scroll.anchor_left = 0.0
    scroll.anchor_right = 1.0
    scroll.anchor_top = 0.0
    scroll.anchor_bottom = 1.0
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _content_holder.add_child(scroll)

    var col := VBoxContainer.new()
    col.add_theme_constant_override("separation", 10)
    col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(col)

    # `$ id`
    col.add_child(_make_status_heading("$ id"))
    col.add_child(_make_mono_label(GameState.id_string(), LABEL_COLOR))

    # Spacer.
    col.add_child(_make_spacer(8))

    # `$ ls -l ~/bin`
    col.add_child(_make_status_heading("$ ls -l ~/bin"))
    for entry in DEFAULT_BINARIES:
        col.add_child(_make_binary_row(entry, "default", true))
    for entry in BOSS_GRANTS:
        var bid: String = String(entry.get("boss", ""))
        var owned: bool = GameState.has_binary(String(entry.get("binary", "")))
        var story: String
        if owned:
            story = "%s ✓" % String(entry.get("boss_name", bid))
        else:
            story = "locked: defeat %s" % String(entry.get("boss_name", bid))
        col.add_child(_make_binary_row(entry, story, owned))

    col.add_child(_make_spacer(8))

    # `$ ls -l /`
    col.add_child(_make_status_heading("$ ls -l /"))
    var root_lines: Array = _gather_root_lines()
    for line_data in root_lines:
        col.add_child(_make_dir_row(line_data))


func _make_status_heading(text: String) -> Label:
    # Bold gold heading — the "$ <command>" cue between status sections.
    # Mono-ish via the size override; Godot's default UI font isn't a
    # true monospace but the column lines up well enough at 20pt.
    var lbl := Label.new()
    lbl.text = text
    lbl.add_theme_color_override("font_color", TITLE_COLOR)
    lbl.add_theme_font_size_override("font_size", STATUS_HEADING_SIZE)
    return lbl


func _make_mono_label(text: String, color: Color) -> Label:
    # 18pt body row. We don't have a packaged monospace font asset;
    # Godot's default UI font holds column alignment well enough for the
    # short, padded strings the status screen produces.
    var lbl := Label.new()
    lbl.text = text
    lbl.add_theme_color_override("font_color", color)
    lbl.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
    return lbl


func _make_spacer(h: int) -> Control:
    var c := Control.new()
    c.custom_minimum_size = Vector2(0, h)
    return c


# Render one `ls -l ~/bin`-style row. `entry` is a dict from
# DEFAULT_BINARIES / BOSS_GRANTS; `story` is the parenthetical to show
# after the tool name; `owned` controls colour (granted = bright,
# locked = dim).
func _make_binary_row(entry: Dictionary, story: String, owned: bool) -> Label:
    var tool: String = String(entry.get("tool", "?"))
    var binary: String = String(entry.get("binary", ""))
    # Use the actual perm if Tux owns it; fall back to the canonical
    # default for default-kit rows; locked rows render "---".
    var perm: String = ""
    if owned:
        perm = String(GameState.binaries.get(binary, String(entry.get("perm", "--x"))))
    else:
        perm = "---"
    # Pad the binary owner-bits out to 9 chars so the column lines up
    # with `ls -l /`'s output. Group + world stay "------" — these are
    # personal tools, not shared.
    var full_perm: String = "%s------" % perm
    var line: String = "-%s %-10s (%s)" % [full_perm, tool, story]
    var color: Color = LABEL_COLOR if owned else LOCKED_COLOR
    return _make_mono_label(line, color)


# Build the row data array for `$ ls -l /`. Each entry: {perm, name,
# story, owned}. Stories come from DIR_GRANTS first; anything not in
# that map gets a static label based on the perm string.
func _gather_root_lines() -> Array:
    var paths: Array[String] = []
    for p in GameState.permissions.keys():
        var sp: String = String(p)
        # Top-level only — `/foo`, not `/foo/bar`. We deliberately skip
        # `/opt/wyrdmark` and `/home/wyrdkin` from the `/` listing
        # because `ls -l /` shouldn't recurse.
        if sp.begins_with("/") and not sp.substr(1).contains("/"):
            paths.append(sp)
    paths.sort()
    var grant_by_path: Dictionary = {}
    for g in DIR_GRANTS:
        grant_by_path[String(g.get("path", ""))] = g
    var out: Array = []
    for p in paths:
        var perm: String = String(GameState.permissions.get(p, "---------"))
        var name: String = p.substr(1)
        var story: String
        var owned: bool = perm.find("r") != -1 or perm.find("w") != -1 or perm.find("x") != -1
        if grant_by_path.has(p):
            var g: Dictionary = grant_by_path[p]
            var bid: String = String(g.get("boss", ""))
            if GameState.has_defeated_boss(bid):
                story = String(g.get("story", ""))
            else:
                story = "locked: defeat %s" % String(g.get("boss_name", bid))
        else:
            # Static label: describe the owner-bit slice. r-x = read+exec,
            # rwx = full, anything starting with --- = locked.
            var owner: String = perm.substr(0, 3)
            if owner == "rwx":
                story = "full"
            elif owner == "r-x":
                story = "read+exec — you can enter"
            elif owner.begins_with("---"):
                story = "no entry"
            else:
                story = owner
        out.append({"perm": perm, "name": name, "story": story, "owned": owned})
    return out


func _make_dir_row(data: Dictionary) -> Label:
    var perm: String = String(data.get("perm", "---------"))
    var name: String = String(data.get("name", "?"))
    var story: String = String(data.get("story", ""))
    var owned: bool = bool(data.get("owned", false))
    var line: String = "d%s %-10s (%s)" % [perm, "%s/" % name, story]
    var color: Color = LABEL_COLOR if owned else LOCKED_COLOR
    return _make_mono_label(line, color)
