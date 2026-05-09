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
    death_overlay.visible = false
    _refresh_hp(GameState.hp, GameState.max_fish * GameState.HP_PER_FISH)
    _on_stamina_changed(GameState.stamina, GameState.MAX_STAMINA)
    _on_pebbles_changed(GameState.pebbles)
    _on_keys_changed(GameState.current_key_group, GameState.get_keys())
    _on_active_item_changed(GameState.active_b_item)
    _on_arrows_changed(GameState.arrows, GameState.max_arrows)
    _on_seeds_changed(GameState.seeds, GameState.max_seeds)


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
