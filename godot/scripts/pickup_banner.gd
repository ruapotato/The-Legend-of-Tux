extends CanvasLayer

# Item-acquired banner. Autoloaded singleton (`PickupBanner`) — pops a
# floating mid-screen card the moment Tux picks up a notable item, song,
# heart container, fairy bottle, or key. Holds for ~2s with a fade in/out
# (3.5s total wall-clock), pauses the player for 1.5s so the moment lands,
# and is dismissable with the [E] interact key.
#
# Two entry points:
#   PickupBanner.show_item(item_id)      # explicit (called by pickup.gd)
#   GameState.item_acquired / song_learned / heart_pieces_changed /
#   fairy_bottles_changed signals       # implicit (covers items that
#                                       # don't go through pickup.gd —
#                                       # heart container / fairy bottle /
#                                       # songs / keys, etc.)
#
# A short dedupe window suppresses double-fires when both paths trigger
# for the same item in the same frame.
#
# Note: the public method is `show_item`, NOT `show` — CanvasLayer
# already exposes a built-in `show()` and shadowing it triggers a
# parse-time warning-as-error.

const HOLD_TIME: float = 2.0
const FADE_IN: float = 0.4
const FADE_OUT: float = 1.1     # FADE_IN + HOLD + FADE_OUT = 3.5s
const PAUSE_TIME: float = 1.5
const DEDUPE_WINDOW: float = 0.6

# Items that should be treated as "major" (heart_container_get sting).
# Everything else (key, ammo bundle, etc.) gets the lighter pebble_get
# chime.
const MAJOR_IDS: Dictionary = {
    "boomerang": true, "bow": true, "slingshot": true, "hookshot": true,
    "hammer": true, "anchor_boots": true, "glim_sight": true,
    "glim_mirror": true, "bombs": true, "lantern": true,
    "heart_container": true,
    "glim_theme": true, "sun_chord": true, "moon_chord": true,
    "triglyph_chord": true,
}

# Per-item display name + icon swatch. Colors borrow the pause_menu
# palette in spirit — bright golds for songs, item-flavoured tints for
# the toolkit. Anything missing falls back to a generic entry.
const ITEM_TABLE: Dictionary = {
    # B-button items
    "boomerang":     {"name": "Boomerang",        "color": Color(0.42, 0.78, 0.34, 1.0)},
    "bow":           {"name": "Recurve Bow",      "color": Color(0.78, 0.55, 0.30, 1.0)},
    "slingshot":     {"name": "Slingshot",        "color": Color(0.55, 0.75, 0.40, 1.0)},
    "hookshot":      {"name": "Hookshot",         "color": Color(0.70, 0.55, 0.20, 1.0)},
    "hammer":        {"name": "Striker's Maul",   "color": Color(0.82, 0.30, 0.22, 1.0)},
    "bombs":         {"name": "Bomb Bag",         "color": Color(0.30, 0.30, 0.34, 1.0)},
    "lantern":       {"name": "Lantern",          "color": Color(0.95, 0.78, 0.30, 1.0)},
    "glim_sight":    {"name": "Glim Sight",       "color": Color(0.55, 0.85, 0.95, 1.0)},
    # Passives
    "anchor_boots":  {"name": "Anchor Boots",     "color": Color(0.45, 0.45, 0.50, 1.0)},
    "glim_mirror":   {"name": "Glim Mirror",      "color": Color(0.85, 0.95, 1.00, 1.0)},
    # Heart / bottle progression
    "heart_container": {"name": "Heart Container", "color": Color(0.95, 0.30, 0.40, 1.0)},
    "heart_piece":     {"name": "Piece of Heart", "color": Color(0.85, 0.40, 0.50, 1.0)},
    "fairy_bottle":    {"name": "Fairy Bottle",   "color": Color(0.95, 0.55, 0.85, 1.0)},
    # Keys (minor)
    "key":           {"name": "Small Key",        "color": Color(0.95, 0.78, 0.30, 1.0)},
    # Songs — looked up by SongBook.id; colors evoke the chord theme.
    "glim_theme":    {"name": "Glim's Theme",     "color": Color(0.65, 0.95, 0.70, 1.0)},
    "sun_chord":     {"name": "Sun Chord",        "color": Color(0.98, 0.85, 0.30, 1.0)},
    "moon_chord":    {"name": "Moon Chord",       "color": Color(0.55, 0.65, 0.95, 1.0)},
    "triglyph_chord":{"name": "Triglyph Chord",   "color": Color(0.92, 0.55, 0.95, 1.0)},
}

var _root: Control = null
var _panel: Panel = null
var _icon: ColorRect = null
var _title: Label = null
var _last_shown_id: String = ""
var _last_shown_at: float = -1000.0
var _active_tween: Tween = null
var _pause_timer: SceneTreeTimer = null


func _ready() -> void:
    layer = 90    # above HUD (default 0/1) but below pause menu (80) and fader (100)
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    _hide_now()
    # Cross-cutting signal hooks so items that don't route through
    # pickup.gd (heart pieces, fairy bottles, songs, dialog-granted
    # items) still get a banner. Dedupe in show() prevents double-fires
    # when pickup.gd ALSO calls us explicitly.
    if Engine.has_singleton("GameState") or get_tree().root.has_node("GameState"):
        GameState.item_acquired.connect(_on_item_acquired)
        GameState.song_learned.connect(_on_song_learned)
        GameState.heart_pieces_changed.connect(_on_heart_pieces_changed)
        GameState.fairy_bottles_changed.connect(_on_fairy_bottles_changed)
        GameState.keys_changed.connect(_on_keys_changed)
    _last_heart_pieces = GameState.heart_pieces if has_node("/root/GameState") else 0
    _last_fairy_bottles = GameState.fairy_bottles if has_node("/root/GameState") else 0
    _last_max_fish = GameState.max_fish if has_node("/root/GameState") else 3


# Track previous values so we can detect "went UP" (a pickup) vs a
# normal in-game decrement (consume / damage).
var _last_heart_pieces: int = 0
var _last_fairy_bottles: int = 0
var _last_max_fish: int = 3
var _last_keys_total: Dictionary = {}    # group → previous count


# ---- Public API ---------------------------------------------------------

func show_item(item_id: String) -> void:
    if item_id == "":
        return
    var now: float = Time.get_ticks_msec() / 1000.0
    if item_id == _last_shown_id and (now - _last_shown_at) < DEDUPE_WINDOW:
        return    # signal + explicit call collided — keep the first
    _last_shown_id = item_id
    _last_shown_at = now
    var entry: Dictionary = ITEM_TABLE.get(item_id, {
        "name": item_id.capitalize(),
        "color": Color(0.85, 0.85, 0.85, 1.0),
    })
    _present(String(entry.get("name", item_id)),
             entry.get("color", Color(0.85, 0.85, 0.85, 1.0)) as Color,
             bool(MAJOR_IDS.get(item_id, false)))


# ---- Internal -----------------------------------------------------------

func _present(display_name: String, swatch: Color, major: bool) -> void:
    _title.text = "You got the %s!" % display_name
    _icon.color = swatch
    _root.modulate = Color(1, 1, 1, 0.0)
    _root.visible = true
    if _active_tween and _active_tween.is_valid():
        _active_tween.kill()
    _active_tween = create_tween()
    _active_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    _active_tween.tween_property(_root, "modulate:a", 1.0, FADE_IN)
    _active_tween.tween_interval(HOLD_TIME)
    _active_tween.tween_property(_root, "modulate:a", 0.0, FADE_OUT)
    _active_tween.tween_callback(_hide_now)
    # Sound sting. Silent-fallback safe if SoundBank lacks the entry.
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("heart_container_get" if major else "pebble_get")
    # Brief pause so the moment registers. Skipped if the tree is
    # already paused (pause menu / dialog / song picker) — we don't
    # want to fight whoever else owns the pause bit.
    if not get_tree().paused:
        get_tree().paused = true
        if _pause_timer != null and _pause_timer.timeout.is_connected(_unpause):
            _pause_timer.timeout.disconnect(_unpause)
        _pause_timer = get_tree().create_timer(PAUSE_TIME, true, false, true)
        _pause_timer.timeout.connect(_unpause)


func _unpause() -> void:
    # Only release the pause bit if WE took it — never override a pause
    # menu that opened in the meantime. The simplest test: only unpause
    # if our banner is still visible (otherwise something dismissed us).
    get_tree().paused = false


func _hide_now() -> void:
    _root.visible = false
    _root.modulate = Color(1, 1, 1, 1)


func _input(event: InputEvent) -> void:
    if not _root.visible:
        return
    if event.is_action_pressed("interact"):
        get_viewport().set_input_as_handled()
        if _active_tween and _active_tween.is_valid():
            _active_tween.kill()
        _hide_now()
        if _pause_timer != null and _pause_timer.timeout.is_connected(_unpause):
            _pause_timer.timeout.disconnect(_unpause)
        _pause_timer = null
        # Drop the pause we may have taken; same caveat as _unpause.
        get_tree().paused = false


# ---- Signal-driven sources ---------------------------------------------

func _on_item_acquired(item_name: String) -> void:
    show_item(item_name)


func _on_song_learned(song_id: String) -> void:
    show_item(song_id)


func _on_heart_pieces_changed(amount: int) -> void:
    # The 4th piece promotes to a heart container — GameState clears the
    # piece count back to 0 in the same call. Detect both transitions:
    # 0..3..0 is a piece pickup; max_fish bumping is the container.
    var max_now: int = GameState.max_fish
    if max_now > _last_max_fish:
        show_item("heart_container")
    elif amount > _last_heart_pieces:
        show_item("heart_piece")
    _last_heart_pieces = amount
    _last_max_fish = max_now


func _on_fairy_bottles_changed(current: int, _maximum: int) -> void:
    if current > _last_fairy_bottles:
        show_item("fairy_bottle")
    _last_fairy_bottles = current


func _on_keys_changed(group: String, amount: int) -> void:
    var prev: int = int(_last_keys_total.get(group, 0))
    if amount > prev:
        show_item("key")
    _last_keys_total[group] = amount


# ---- UI construction ----------------------------------------------------

func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_left = 0.0
    _root.anchor_top = 0.0
    _root.anchor_right = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    # Center-aligned panel, ~520x96, sitting at roughly 38% screen height
    # so it doesn't compete with HP / dialog box space.
    _panel = Panel.new()
    _panel.anchor_left = 0.5
    _panel.anchor_top = 0.5
    _panel.anchor_right = 0.5
    _panel.anchor_bottom = 0.5
    _panel.offset_left = -260.0
    _panel.offset_top = -120.0
    _panel.offset_right = 260.0
    _panel.offset_bottom = -24.0
    _panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var sb := StyleBoxFlat.new()
    sb.bg_color = Color(0.08, 0.07, 0.12, 0.92)
    sb.border_color = Color(0.98, 0.93, 0.55, 1.0)
    sb.border_width_left = 2
    sb.border_width_top = 2
    sb.border_width_right = 2
    sb.border_width_bottom = 2
    sb.corner_radius_top_left = 8
    sb.corner_radius_top_right = 8
    sb.corner_radius_bottom_left = 8
    sb.corner_radius_bottom_right = 8
    sb.shadow_color = Color(0, 0, 0, 0.55)
    sb.shadow_size = 8
    _panel.add_theme_stylebox_override("panel", sb)
    _root.add_child(_panel)

    # Icon swatch on the left (64x64 colored rect with a thin border).
    _icon = ColorRect.new()
    _icon.color = Color(0.85, 0.85, 0.85, 1.0)
    _icon.anchor_left = 0.0
    _icon.anchor_top = 0.5
    _icon.anchor_right = 0.0
    _icon.anchor_bottom = 0.5
    _icon.offset_left = 16.0
    _icon.offset_top = -32.0
    _icon.offset_right = 80.0
    _icon.offset_bottom = 32.0
    _icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.add_child(_icon)

    # Title text on the right of the icon.
    _title = Label.new()
    _title.anchor_left = 0.0
    _title.anchor_top = 0.0
    _title.anchor_right = 1.0
    _title.anchor_bottom = 1.0
    _title.offset_left = 96.0
    _title.offset_top = 0.0
    _title.offset_right = -16.0
    _title.offset_bottom = 0.0
    _title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
    _title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _title.add_theme_font_size_override("font_size", 24)
    _title.add_theme_color_override("font_color", Color(0.98, 0.93, 0.55, 1.0))
    _title.text = ""
    _title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.add_child(_title)

    # "Press [E] to skip" hint along the bottom of the panel.
    var hint := Label.new()
    hint.anchor_left = 0.0
    hint.anchor_top = 1.0
    hint.anchor_right = 1.0
    hint.anchor_bottom = 1.0
    hint.offset_left = 0.0
    hint.offset_top = -22.0
    hint.offset_right = -8.0
    hint.offset_bottom = -2.0
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    hint.add_theme_font_size_override("font_size", 11)
    hint.add_theme_color_override("font_color", Color(0.70, 0.68, 0.60, 0.85))
    hint.text = "[E] skip"
    hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.add_child(hint)
