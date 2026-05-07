extends Node

# Autoloaded singleton for run-global player stats: HP (fish), stamina,
# pebble currency. Per-scene state lives in scenes, not here.

signal hp_changed(current: int, maximum: int)
signal stamina_changed(current: int, maximum: int)
signal pebbles_changed(amount: int)
signal player_died()

# Each "fish" = 4 HP units; matches the half-fish damage granularity we
# expect from low-tier enemies. Start with 3 fish (12 HP).
const HP_PER_FISH: int = 4
const MAX_STAMINA: int = 100

var max_fish: int = 3
var hp: int = 12

# Stamina is an integer; the player controller drains/regens it through
# the helpers below. Floats for sub-integer regen are tracked internally.
var stamina: int = MAX_STAMINA
var _stamina_remainder: float = 0.0

var pebbles: int = 0


func reset() -> void:
    max_fish = 3
    hp = max_fish * HP_PER_FISH
    stamina = MAX_STAMINA
    _stamina_remainder = 0.0
    pebbles = 0
    hp_changed.emit(hp, max_fish * HP_PER_FISH)
    stamina_changed.emit(stamina, MAX_STAMINA)
    pebbles_changed.emit(pebbles)


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
