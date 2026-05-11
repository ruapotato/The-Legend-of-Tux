extends CanvasLayer

# Autoloaded shop overlay. NPCs that sell things end a dialog branch by
# calling Shop.open(speaker_name, ["heart","arrow","bomb"]) — the dialog
# dispatcher (dialog.gd, `opens_shop` choice field) does this for them.
#
# Public API
#   Shop.open(npc_name, wares)   show the panel; pauses the tree
#   Shop.close()                  dismiss; unpauses the tree
#   Shop.is_open() -> bool
#
# `wares` is an Array of either:
#   - String ware-id: looked up in WARES_DEFAULTS for label/price/effect.
#   - Dictionary {"label","price","effect"}: inline override (used by the
#     fairy bottle, which is only sold at one shop and might want a
#     different price than the default).
#
# Built procedurally so we don't have to maintain a .tscn beyond the
# thin one-line scene that registers the script. Autoloaded so dialog.gd
# can dispatch into it without scene loading.

# Visual scheme matches pause_menu.gd so the two overlays feel sibling.
const BACKDROP_COLOR := Color(0.05, 0.04, 0.10, 0.88)
const PANEL_COLOR    := Color(0.10, 0.09, 0.16, 0.98)
const TITLE_COLOR    := Color(0.98, 0.93, 0.55, 1.0)
const LABEL_COLOR    := Color(0.92, 0.90, 0.85, 1.0)
const HINT_COLOR     := Color(0.72, 0.70, 0.65, 1.0)
const TILE_BG_COLOR  := Color(0.16, 0.14, 0.22, 1.0)
const PRICE_OK_COLOR := Color(0.85, 0.92, 0.65, 1.0)
const PRICE_NO_COLOR := Color(0.85, 0.55, 0.55, 1.0)

# Standard wares table. NPCs declare wares as ["heart","arrow",...] and
# the shop looks up label/price/effect here. `effect` is an opaque tag
# the buy handler dispatches on (heart → heal, arrow → add_arrows, etc).
const WARES_DEFAULTS: Dictionary = {
    "heart": {
        "label": "Heart Refill",
        "price": 5,
        "effect": "heart",
        "color": Color(0.92, 0.32, 0.40, 1.0),
    },
    "arrow": {
        "label": "Arrows (5)",
        "price": 8,
        "effect": "arrow",
        "color": Color(0.85, 0.78, 0.55, 1.0),
    },
    "bomb": {
        "label": "Bombs (3)",
        "price": 12,
        "effect": "bomb",
        "color": Color(0.30, 0.30, 0.34, 1.0),
    },
    "seed": {
        "label": "Seeds (10)",
        "price": 6,
        "effect": "seed",
        "color": Color(0.55, 0.78, 0.40, 1.0),
    },
    "fairy_bottle": {
        "label": "Fairy Bottle",
        "price": 40,
        "effect": "fairy_bottle",
        "color": Color(0.85, 0.55, 0.95, 1.0),
    },
    # --- binaries-as-wares -------------------------------------------------
    # Tool-spirit shopkeepers (apt, make, tar) sell executable bits as
    # wares. Effect prefix "binary:<path>" routes to GameState.grant_binary
    # in _apply_effect; "fsck_heal" is a one-shot consumable (heal + scrub).
    "wget": {
        "label": "wget (boomerang)",
        "price": 50,
        "effect": "binary:/usr/bin/wget",
        "color": Color(0.55, 0.78, 0.95, 1.0),
    },
    "man": {
        "label": "man (manual pages)",
        "price": 8,
        "effect": "binary:/usr/bin/man",
        "color": Color(0.85, 0.85, 0.78, 1.0),
    },
    "gcc": {
        "label": "gcc (compiler)",
        "price": 80,
        "effect": "binary:/usr/bin/gcc",
        "color": Color(0.78, 0.55, 0.30, 1.0),
    },
    "fsck": {
        "label": "fsck (heal + scrub)",
        "price": 30,
        "effect": "fsck_heal",
        "color": Color(0.55, 0.92, 0.78, 1.0),
    },
    "unzip": {
        "label": "unzip (loot cache)",
        "price": 40,
        "effect": "binary:/usr/bin/unzip",
        "color": Color(0.92, 0.78, 0.55, 1.0),
    },
}

var _open: bool = false
var _was_mouse_captured: bool = false
var _was_paused: bool = false

var _root: Control = null
var _panel: ColorRect = null
var _heading: Label = null
var _list_box: VBoxContainer = null
var _pebble_label: Label = null
# Per-tile widgets so we can refresh the buy buttons / price colors after
# a purchase without rebuilding the whole list.
var _tiles: Array = []   # array of dicts {"ware","button","price_label"}


func _ready() -> void:
    layer = 90
    process_mode = Node.PROCESS_MODE_ALWAYS
    visible = false


# ---- public API --------------------------------------------------------

func is_open() -> bool:
    return _open


func open(npc_name: String, wares: Array) -> void:
    if _open:
        # Re-open with new wares — close first so we don't stack.
        close()
    _open = true
    _was_paused = get_tree().paused
    _was_mouse_captured = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().paused = true
    _build_ui(npc_name, wares)
    visible = true
    if Engine.has_singleton("SoundBank") or get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("shop_open")


func close() -> void:
    if not _open:
        return
    _open = false
    visible = false
    if _root != null:
        _root.queue_free()
        _root = null
    _tiles.clear()
    if not _was_paused:
        get_tree().paused = false
    if _was_mouse_captured:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("shop_close")


# ---- input -------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
    if not _open:
        return
    if event.is_action_pressed("ui_cancel") or event.is_action_pressed("interact"):
        get_viewport().set_input_as_handled()
        close()


# ---- UI construction ---------------------------------------------------

func _build_ui(npc_name: String, wares: Array) -> void:
    _root = Control.new()
    _root.anchor_right  = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter  = Control.MOUSE_FILTER_STOP
    add_child(_root)

    var bg := ColorRect.new()
    bg.color = BACKDROP_COLOR
    bg.anchor_right  = 1.0
    bg.anchor_bottom = 1.0
    bg.mouse_filter  = Control.MOUSE_FILTER_STOP
    _root.add_child(bg)

    # Centered 60%-of-screen panel.
    _panel = ColorRect.new()
    _panel.color = PANEL_COLOR
    _panel.anchor_left   = 0.20
    _panel.anchor_right  = 0.80
    _panel.anchor_top    = 0.20
    _panel.anchor_bottom = 0.80
    _root.add_child(_panel)

    var margin := MarginContainer.new()
    margin.anchor_right  = 1.0
    margin.anchor_bottom = 1.0
    margin.add_theme_constant_override("margin_left",   24)
    margin.add_theme_constant_override("margin_right",  24)
    margin.add_theme_constant_override("margin_top",    20)
    margin.add_theme_constant_override("margin_bottom", 20)
    _panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 10)
    margin.add_child(vbox)

    _heading = Label.new()
    _heading.text = "Shop — %s" % (npc_name if npc_name != "" else "Wares")
    _heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _heading.add_theme_font_size_override("font_size", 24)
    _heading.add_theme_color_override("font_color", TITLE_COLOR)
    vbox.add_child(_heading)

    _pebble_label = Label.new()
    _pebble_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _pebble_label.add_theme_font_size_override("font_size", 14)
    _pebble_label.add_theme_color_override("font_color", HINT_COLOR)
    vbox.add_child(_pebble_label)

    var separator := HSeparator.new()
    vbox.add_child(separator)

    _list_box = VBoxContainer.new()
    _list_box.add_theme_constant_override("separation", 8)
    vbox.add_child(_list_box)

    for raw in wares:
        var ware: Dictionary = _resolve_ware(raw)
        if ware.is_empty():
            continue
        _list_box.add_child(_make_tile(ware))

    var spacer := Control.new()
    spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vbox.add_child(spacer)

    var goodbye := Button.new()
    goodbye.text = "Goodbye"
    goodbye.add_theme_font_size_override("font_size", 18)
    goodbye.custom_minimum_size = Vector2(160, 40)
    goodbye.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
    goodbye.pressed.connect(close)
    vbox.add_child(goodbye)

    _refresh_pebble_label()
    _refresh_tiles()


func _resolve_ware(raw: Variant) -> Dictionary:
    # Accept either a String id (looked up in WARES_DEFAULTS) or an
    # inline {"label","price","effect"} dict.
    if typeof(raw) == TYPE_STRING:
        var key := String(raw)
        if not WARES_DEFAULTS.has(key):
            push_warning("Shop: unknown ware id '%s'" % key)
            return {}
        var d: Dictionary = (WARES_DEFAULTS[key] as Dictionary).duplicate()
        d["id"] = key
        return d
    if typeof(raw) == TYPE_DICTIONARY:
        var inline: Dictionary = (raw as Dictionary).duplicate()
        if not inline.has("effect"):
            push_warning("Shop: inline ware missing 'effect' field")
            return {}
        if not inline.has("label"):
            inline["label"] = String(inline["effect"]).capitalize()
        if not inline.has("price"):
            inline["price"] = 0
        if not inline.has("color"):
            inline["color"] = LABEL_COLOR
        if not inline.has("id"):
            inline["id"] = String(inline["effect"])
        return inline
    return {}


func _make_tile(ware: Dictionary) -> Control:
    var tile := PanelContainer.new()
    tile.custom_minimum_size = Vector2(0, 56)
    var sb := StyleBoxFlat.new()
    sb.bg_color = TILE_BG_COLOR
    sb.set_corner_radius_all(6)
    sb.content_margin_left = 8
    sb.content_margin_right = 8
    sb.content_margin_top = 6
    sb.content_margin_bottom = 6
    tile.add_theme_stylebox_override("panel", sb)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 12)
    tile.add_child(row)

    # Icon: a 32x32 colored rect (no art assets yet).
    var icon_holder := Control.new()
    icon_holder.custom_minimum_size = Vector2(32, 32)
    row.add_child(icon_holder)
    var icon := ColorRect.new()
    icon.color = ware.get("color", LABEL_COLOR)
    icon.anchor_right  = 1.0
    icon.anchor_bottom = 1.0
    icon.mouse_filter  = Control.MOUSE_FILTER_IGNORE
    icon_holder.add_child(icon)

    var label := Label.new()
    label.text = String(ware.get("label", "?"))
    label.add_theme_font_size_override("font_size", 18)
    label.add_theme_color_override("font_color", LABEL_COLOR)
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(label)

    var price_label := Label.new()
    price_label.text = "%d pb" % int(ware.get("price", 0))
    price_label.add_theme_font_size_override("font_size", 18)
    price_label.add_theme_color_override("font_color", PRICE_OK_COLOR)
    price_label.custom_minimum_size = Vector2(80, 0)
    price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    row.add_child(price_label)

    var buy := Button.new()
    buy.text = "Buy"
    buy.custom_minimum_size = Vector2(80, 36)
    buy.add_theme_font_size_override("font_size", 16)
    buy.focus_mode = Control.FOCUS_NONE
    buy.pressed.connect(_on_buy.bind(ware))
    row.add_child(buy)

    _tiles.append({"ware": ware, "button": buy, "price_label": price_label})
    return tile


func _refresh_pebble_label() -> void:
    if _pebble_label == null:
        return
    _pebble_label.text = "You have %d pebbles" % GameState.pebbles


func _refresh_tiles() -> void:
    for entry in _tiles:
        var ware: Dictionary = entry["ware"]
        var btn: Button = entry["button"]
        var pl:  Label  = entry["price_label"]
        var price: int = int(ware.get("price", 0))
        var can_afford: bool = GameState.pebbles >= price
        if can_afford:
            btn.text = "Buy"
            btn.disabled = false
            pl.add_theme_color_override("font_color", PRICE_OK_COLOR)
        else:
            btn.text = "—"
            btn.disabled = true
            pl.add_theme_color_override("font_color", PRICE_NO_COLOR)


# ---- buy handler -------------------------------------------------------

func _on_buy(ware: Dictionary) -> void:
    var price: int = int(ware.get("price", 0))
    if GameState.pebbles < price:
        SoundBank.play_2d("shop_no_money")
        return
    GameState.pebbles -= price
    GameState.pebbles_changed.emit(GameState.pebbles)
    _apply_effect(String(ware.get("effect", "")))
    SoundBank.play_2d("shop_buy")
    _refresh_pebble_label()
    _refresh_tiles()


func _apply_effect(effect: String) -> void:
    # binaries-as-wares: tool-spirit shops sell executable bits. We dispatch
    # the "binary:<path>" prefix to GameState.grant_binary (idempotent —
    # double-grant is a no-op) and echo a faux apt-install line into the
    # terminal corner so the purchase reads as a package transaction.
    if effect.begins_with("binary:"):
        var path: String = effect.substr("binary:".length())
        GameState.grant_binary(path, "--x")
        var pkg: String = path.get_file()
        if get_tree().root.has_node("TerminalLog"):
            TerminalLog.cmd("apt install %s" % pkg)
            TerminalLog.output("[ok] %s installed" % path)
        return
    match effect:
        "heart":
            # Refill to full. heal() clamps at max_fish * HP_PER_FISH.
            GameState.heal(GameState.max_fish * GameState.HP_PER_FISH)
        "arrow":
            GameState.add_arrows(5)
        "bomb":
            GameState.add_bombs(3)
        "seed":
            GameState.add_seeds(10)
        "fairy_bottle":
            # add_fairy() also flips the inventory's `bottle_seen` marker
            # so the HUD's bottle row stays visible after the bottle's
            # used. Capacity-clamped inside the call.
            GameState.add_fairy(1)
        "fsck_heal":
            # `fsck` from `make`: heal to full and (conceptually) clear any
            # state debuff. We don't track named debuffs yet, so the heal
            # is the only mechanical effect for now.
            GameState.heal(GameState.max_fish * GameState.HP_PER_FISH)
            if get_tree().root.has_node("TerminalLog"):
                TerminalLog.cmd("fsck -y /dev/tux")
                TerminalLog.output("[ok] filesystem clean")
        _:
            push_warning("Shop: unknown effect '%s'" % effect)
