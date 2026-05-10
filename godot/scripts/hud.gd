extends CanvasLayer

# In-game HUD: row of "fish" hearts (each fish = 4 HP units, drawn as
# four quarter-segments), a stamina bar, and a pebble counter. Listens
# to GameState signals; draws everything procedurally so we don't need
# any sprite assets for the slice.

@onready var hp_root: HBoxContainer = $Margin/Layout/HPRow
@onready var stamina_bar: ProgressBar = $Margin/Layout/StaminaBar
@onready var keys_label: Label = $Margin/Layout/KeysLabel
@onready var pebble_label: Label = $TopRight/PebbleLabel
@onready var item_label: Label = $TopRight/ItemLabel
@onready var arrow_label: Label = $TopRight/ArrowLabel
@onready var seed_label: Label = $TopRight/SeedLabel
@onready var death_overlay: ColorRect = $DeathOverlay
@onready var death_label: Label = $DeathOverlay/DeathLabel

# Fairy-bottle counter — built in _ready (no .tscn churn) so it sits
# inside the existing TopRight column with the other counters.
var bottle_label: Label = null
# Shield-tier readout. Hidden until Tux owns the Glim Mirror; on swap
# it surfaces as a small "Mirror" tag in the TopRight column so the
# player has a glance-confirmation that the upgrade landed.
var shield_label: Label = null
# Sparkle overlay drawn on revive. We construct both nodes lazily on
# the first revive so a fresh scene never pays for them upfront.
var _sparkle_rect: ColorRect = null
var _sparkle_label: Label = null

const FISH_COLOR_FULL := Color(0.30, 0.55, 0.95, 1.0)
const FISH_COLOR_EMPTY := Color(0.10, 0.18, 0.28, 0.55)


func _ready() -> void:
    GameState.hp_changed.connect(_on_hp_changed)
    GameState.stamina_changed.connect(_on_stamina_changed)
    GameState.pebbles_changed.connect(_on_pebbles_changed)
    GameState.keys_changed.connect(_on_keys_changed)
    GameState.active_item_changed.connect(_on_active_item_changed)
    GameState.item_acquired.connect(_on_item_acquired)
    GameState.arrows_changed.connect(_on_arrows_changed)
    GameState.seeds_changed.connect(_on_seeds_changed)
    GameState.player_died.connect(_on_player_died)
    GameState.fairy_bottles_changed.connect(_on_fairy_bottles_changed)
    GameState.fairy_revive_triggered.connect(_on_fairy_revive_triggered)
    death_overlay.visible = false
    _ensure_bottle_label()
    _ensure_shield_label()
    _refresh_shield_label()
    _refresh_hp(GameState.hp, GameState.max_fish * GameState.HP_PER_FISH)
    _on_stamina_changed(GameState.stamina, GameState.MAX_STAMINA)
    _on_pebbles_changed(GameState.pebbles)
    _on_keys_changed(GameState.current_key_group, GameState.get_keys())
    _on_active_item_changed(GameState.active_b_item)
    _on_arrows_changed(GameState.arrows, GameState.max_arrows)
    _on_seeds_changed(GameState.seeds, GameState.max_seeds)
    _on_fairy_bottles_changed(GameState.fairy_bottles, GameState.max_fairy_bottles)


func _ensure_bottle_label() -> void:
    if bottle_label != null:
        return
    var top_right := get_node_or_null("TopRight")
    if top_right == null:
        return
    bottle_label = Label.new()
    bottle_label.name = "BottleLabel"
    bottle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    bottle_label.text = ""
    bottle_label.visible = false
    top_right.add_child(bottle_label)


func _on_fairy_bottles_changed(current: int, maximum: int) -> void:
    _ensure_bottle_label()
    if bottle_label == null:
        return
    # Stay hidden until the player has at any point owned a bottle —
    # add_fairy() flips inventory["bottle_seen"] on first pickup, so
    # the row appears the moment that first chest opens and lingers
    # at "0 / N" thereafter as a reminder that bottles exist.
    var seen: bool = bool(GameState.inventory.get("bottle_seen", false))
    if current <= 0 and not seen:
        bottle_label.text = ""
        bottle_label.visible = false
    else:
        bottle_label.text = "Btl %d / %d" % [current, maximum]
        bottle_label.visible = true


func _on_hp_changed(current: int, maximum: int) -> void:
    _refresh_hp(current, maximum)


func _on_stamina_changed(current: int, maximum: int) -> void:
    stamina_bar.max_value = maximum
    stamina_bar.value = current


func _on_pebbles_changed(amount: int) -> void:
    pebble_label.text = "Pebbles: %d" % amount


func _on_keys_changed(group: String, amount: int) -> void:
    # Only refresh when the signal is for the dungeon Tux is currently
    # in; other groups' counts are bookkeeping the HUD shouldn't show.
    if group != GameState.current_key_group:
        return
    if not keys_label:
        return
    if amount <= 0:
        keys_label.text = ""
    else:
        keys_label.text = "Keys: %d" % amount


func _on_active_item_changed(item_name: String) -> void:
    if not item_label:
        return
    if item_name == "":
        item_label.text = ""
    else:
        item_label.text = "[F] %s" % item_name.capitalize()


func _on_item_acquired(_item_name: String) -> void:
    SoundBank.play_2d("sword_charge_ready")
    # Refresh ammo rows: picking up the bow/slingshot for the first
    # time should reveal the row even at 0 ammo so the player learns
    # the readout exists.
    _on_arrows_changed(GameState.arrows, GameState.max_arrows)
    _on_seeds_changed(GameState.seeds, GameState.max_seeds)
    _refresh_shield_label()


func _ensure_shield_label() -> void:
    if shield_label != null:
        return
    var top_right := get_node_or_null("TopRight")
    if top_right == null:
        return
    shield_label = Label.new()
    shield_label.name = "ShieldLabel"
    shield_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    shield_label.text = ""
    shield_label.visible = false
    top_right.add_child(shield_label)


func _refresh_shield_label() -> void:
    _ensure_shield_label()
    if shield_label == null:
        return
    if GameState.has_glim_mirror():
        shield_label.text = "Shld: Mirror"
        shield_label.visible = true
    else:
        shield_label.text = ""
        shield_label.visible = false


# Hide ammo readouts when both the count is zero AND the player has
# never acquired the corresponding item — keeps the corner clean for
# anyone who hasn't found a bow/slingshot yet.
func _on_arrows_changed(current: int, maximum: int) -> void:
    if not arrow_label:
        return
    var owns: bool = GameState.has_item("bow")
    if current <= 0 and not owns:
        arrow_label.text = ""
        arrow_label.visible = false
    else:
        arrow_label.text = "Arr %d / %d" % [current, maximum]
        arrow_label.visible = true


func _on_seeds_changed(current: int, maximum: int) -> void:
    if not seed_label:
        return
    var owns: bool = GameState.has_item("slingshot")
    if current <= 0 and not owns:
        seed_label.text = ""
        seed_label.visible = false
    else:
        seed_label.text = "Sd %d / %d" % [current, maximum]
        seed_label.visible = true


func _on_player_died() -> void:
    death_overlay.visible = true
    _ensure_death_buttons()
    # Free the mouse so the player can actually click Continue / Quit —
    # the camera captures the mouse during gameplay and never released
    # it for the death overlay before. New scenes recapture in their
    # own _ready when load_game / reload_current_scene fires.
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ---- Fairy-bottle revive sparkle ---------------------------------------
#
# Fires when GameState.damage() catches a lethal hit and pops a bottle.
# Death overlay should NOT appear (it's only triggered by player_died,
# which damage() suppresses on the revive path) — we just flash a
# half-transparent rect and a centered label for a beat.

func _on_fairy_revive_triggered() -> void:
    _ensure_sparkle_nodes()
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("fairy_revive")
    _sparkle_rect.color = Color(0.85, 0.95, 1.0, 0.85)
    _sparkle_rect.visible = true
    _sparkle_label.visible = true
    # Two independent timers: the wash fades fast (0.4s) but the
    # text lingers (1.5s) so the player has time to read it.
    var rect_tween := create_tween()
    rect_tween.tween_property(_sparkle_rect, "color:a", 0.0, 0.4)
    rect_tween.tween_callback(_hide_sparkle_rect)
    var label_timer := get_tree().create_timer(1.5)
    label_timer.timeout.connect(_hide_sparkle_label)


func _ensure_sparkle_nodes() -> void:
    if _sparkle_rect != null:
        return
    _sparkle_rect = ColorRect.new()
    _sparkle_rect.name = "FairySparkle"
    _sparkle_rect.anchor_right = 1.0
    _sparkle_rect.anchor_bottom = 1.0
    _sparkle_rect.color = Color(0.85, 0.95, 1.0, 0.0)
    _sparkle_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _sparkle_rect.visible = false
    add_child(_sparkle_rect)
    _sparkle_label = Label.new()
    _sparkle_label.name = "FairySparkleLabel"
    _sparkle_label.anchor_left = 0.5
    _sparkle_label.anchor_top = 0.5
    _sparkle_label.anchor_right = 0.5
    _sparkle_label.anchor_bottom = 0.5
    _sparkle_label.offset_left = -200
    _sparkle_label.offset_top = -24
    _sparkle_label.offset_right = 200
    _sparkle_label.offset_bottom = 24
    _sparkle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _sparkle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _sparkle_label.text = "A fairy revives you!"
    _sparkle_label.visible = false
    _sparkle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_sparkle_label)


func _hide_sparkle_rect() -> void:
    if _sparkle_rect != null:
        _sparkle_rect.visible = false


func _hide_sparkle_label() -> void:
    if _sparkle_label != null:
        _sparkle_label.visible = false


# Death overlay buttons. Built once on demand instead of authored in
# the .tscn so changing the choices doesn't require touching scene
# files. CONTINUE re-loads the bound save slot if one's set, otherwise
# falls back to a scene reload. QUIT bails to the title.
var _death_continue_btn: Button = null
var _death_quit_btn: Button = null

func _ensure_death_buttons() -> void:
    if _death_continue_btn != null:
        return
    var box := VBoxContainer.new()
    box.add_theme_constant_override("separation", 8)
    box.set_anchors_preset(Control.PRESET_CENTER)
    box.position = Vector2(-110, 60)
    box.custom_minimum_size = Vector2(220, 0)
    death_overlay.add_child(box)
    _death_continue_btn = Button.new()
    _death_continue_btn.text = (
        "Continue from save" if GameState.last_slot >= 0
        else "Try again (R)")
    _death_continue_btn.custom_minimum_size = Vector2(220, 36)
    _death_continue_btn.pressed.connect(_on_death_continue)
    box.add_child(_death_continue_btn)
    _death_quit_btn = Button.new()
    _death_quit_btn.text = "Quit to title"
    _death_quit_btn.custom_minimum_size = Vector2(220, 36)
    _death_quit_btn.pressed.connect(_on_death_quit)
    box.add_child(_death_quit_btn)


func _on_death_continue() -> void:
    if GameState.last_slot >= 0 and GameState.has_method("load_game"):
        if GameState.load_game(GameState.last_slot):
            return
    get_tree().reload_current_scene()


func _on_death_quit() -> void:
    GameState.last_slot = -1
    get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
    death_label.text = "Tux fell.\nPress R to retry."


func _refresh_hp(current: int, _maximum: int) -> void:
    var per: int = GameState.HP_PER_FISH
    var max_fish: int = GameState.max_fish
    while hp_root.get_child_count() < max_fish:
        hp_root.add_child(_make_fish())
    while hp_root.get_child_count() > max_fish:
        var n := hp_root.get_child(hp_root.get_child_count() - 1)
        hp_root.remove_child(n)
        n.queue_free()
    for i in max_fish:
        var fish: Control = hp_root.get_child(i) as Control
        var fill: int = clampi(current - i * per, 0, per)
        _set_fish_fill(fish, float(fill) / per)


func _make_fish() -> Control:
    # A "fish" is a 32x24 ColorRect with a small triangular tail to the
    # right; we stack 4 quarter-segments inside it via children to show
    # partial damage.
    var c := Control.new()
    c.custom_minimum_size = Vector2(36, 26)
    var body := ColorRect.new()
    body.name = "Body"
    body.color = FISH_COLOR_FULL
    body.size = Vector2(28, 22)
    body.position = Vector2(0, 2)
    c.add_child(body)
    var tail := ColorRect.new()
    tail.name = "Tail"
    tail.color = FISH_COLOR_FULL
    tail.size = Vector2(8, 14)
    tail.position = Vector2(28, 6)
    c.add_child(tail)
    return c


func _set_fish_fill(fish: Control, fill: float) -> void:
    var body := fish.get_node("Body") as ColorRect
    var tail := fish.get_node("Tail") as ColorRect
    var col := FISH_COLOR_FULL.lerp(FISH_COLOR_EMPTY, 1.0 - fill)
    body.color = col
    tail.color = col


func _input(event: InputEvent) -> void:
    if death_overlay.visible and event is InputEventKey and event.pressed and event.keycode == KEY_R:
        get_tree().reload_current_scene()
