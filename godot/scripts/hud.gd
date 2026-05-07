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
    GameState.player_died.connect(_on_player_died)
    death_overlay.visible = false
    _refresh_hp(GameState.hp, GameState.max_fish * GameState.HP_PER_FISH)
    _on_stamina_changed(GameState.stamina, GameState.MAX_STAMINA)
    _on_pebbles_changed(GameState.pebbles)
    _on_keys_changed(GameState.keys)
    _on_active_item_changed(GameState.active_b_item)


func _on_hp_changed(current: int, maximum: int) -> void:
    _refresh_hp(current, maximum)


func _on_stamina_changed(current: int, maximum: int) -> void:
    stamina_bar.max_value = maximum
    stamina_bar.value = current


func _on_pebbles_changed(amount: int) -> void:
    pebble_label.text = "Pebbles: %d" % amount


func _on_keys_changed(amount: int) -> void:
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


func _on_player_died() -> void:
    death_overlay.visible = true
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
