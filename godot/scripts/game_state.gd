extends Node

# Autoloaded singleton for run-global player stats: HP (fish), stamina,
# pebble currency, small keys, owned items, and the B-button slot.
# Per-scene state lives in scenes, not here.

signal hp_changed(current: int, maximum: int)
signal stamina_changed(current: int, maximum: int)
signal pebbles_changed(amount: int)
signal keys_changed(amount: int)
signal item_acquired(item_name: String)
signal active_item_changed(item_name: String)
signal player_died()

const HP_PER_FISH: int = 4
const MAX_STAMINA: int = 100

var max_fish: int = 3
var hp: int = 12

var stamina: int = MAX_STAMINA
var _stamina_remainder: float = 0.0

var pebbles: int = 0
var keys: int = 0    # small keys for the current dungeon

# Inventory: name → true (owned). Active item is the one bound to the
# B-button (item_use input).
var inventory: Dictionary = {}
var active_b_item: String = ""


func reset() -> void:
    max_fish = 3
    hp = max_fish * HP_PER_FISH
    stamina = MAX_STAMINA
    _stamina_remainder = 0.0
    pebbles = 0
    keys = 0
    inventory.clear()
    active_b_item = ""
    hp_changed.emit(hp, max_fish * HP_PER_FISH)
    stamina_changed.emit(stamina, MAX_STAMINA)
    pebbles_changed.emit(pebbles)
    keys_changed.emit(keys)
    active_item_changed.emit(active_b_item)


# ---- HP -----------------------------------------------------------------

func damage(amount: int) -> void:
    if hp <= 0:
        return
    hp = max(hp - amount, 0)
    hp_changed.emit(hp, max_fish * HP_PER_FISH)
    if hp == 0:
        player_died.emit()


func heal(amount: int) -> void:
    hp = min(hp + amount, max_fish * HP_PER_FISH)
    hp_changed.emit(hp, max_fish * HP_PER_FISH)


# ---- Stamina ------------------------------------------------------------

func spend_stamina(amount: int) -> void:
    stamina = max(stamina - amount, 0)
    stamina_changed.emit(stamina, MAX_STAMINA)


# Per-tick regen. `rate_per_sec` may be 0 (e.g. while blocking).
func regen_stamina(rate_per_sec: float, delta: float) -> void:
    if stamina >= MAX_STAMINA or rate_per_sec <= 0.0:
        _stamina_remainder = 0.0
        return
    _stamina_remainder += rate_per_sec * delta
    var whole := int(_stamina_remainder)
    if whole > 0:
        _stamina_remainder -= whole
        stamina = min(stamina + whole, MAX_STAMINA)
        stamina_changed.emit(stamina, MAX_STAMINA)


# ---- Currency -----------------------------------------------------------

func add_pebbles(amount: int) -> void:
    pebbles += amount
    pebbles_changed.emit(pebbles)
    SoundBank.play_2d("pebble_get")


# ---- Keys ---------------------------------------------------------------

func add_key() -> void:
    keys += 1
    keys_changed.emit(keys)


func consume_key() -> bool:
    if keys <= 0:
        return false
    keys -= 1
    keys_changed.emit(keys)
    return true


# ---- Inventory ----------------------------------------------------------

func acquire_item(item_name: String) -> void:
    if inventory.get(item_name, false):
        return
    inventory[item_name] = true
    item_acquired.emit(item_name)
    # Auto-equip the first item Tux ever picks up so the player has
    # something on the B-button without an inventory menu yet.
    if active_b_item == "":
        active_b_item = item_name
        active_item_changed.emit(active_b_item)


func has_item(item_name: String) -> bool:
    return inventory.get(item_name, false)


func set_active_b_item(item_name: String) -> void:
    if item_name != "" and not has_item(item_name):
        return
    active_b_item = item_name
    active_item_changed.emit(active_b_item)
