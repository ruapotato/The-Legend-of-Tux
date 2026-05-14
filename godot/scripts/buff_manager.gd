extends Node

# Active timed buffs from consumed food. Re-applying the same id
# refreshes the timer; different ids stack their multipliers, which
# compose multiplicatively on top of PlayerStatus's environmental
# multipliers (cold/wet). HP regen ticks accumulate fractional health
# until a whole point is ready, then dispatch to GameState.heal.

signal buff_applied(id: String, duration: float)
signal buff_expired(id: String)

const BUFF_DEFS: Dictionary = {
	"fast":     {"duration": 30.0, "speed_mult": 1.20, "regen_mult": 1.0, "hp_per_sec": 0.0, "label": "Energized"},
	"regen":    {"duration": 30.0, "speed_mult": 1.0,  "regen_mult": 1.0, "hp_per_sec": 0.5, "label": "Healing"},
	"satiated": {"duration": 60.0, "speed_mult": 1.0,  "regen_mult": 1.5, "hp_per_sec": 0.0, "label": "Satiated"},
}

# Food id → buff id. Only listed resources are edible; cooking is what
# turns raw meat into satiated stamina-regen food, so meat_raw isn't here.
const FOOD_BUFFS: Dictionary = {
	"raspberry":   "fast",
	"mushroom":    "regen",
	"cooked_meat": "satiated",
}

var active: Dictionary = {}        # id -> remaining seconds
var _hp_remainder: float = 0.0


func _process(delta: float) -> void:
	if active.is_empty():
		_hp_remainder = 0.0
		return
	var to_expire: Array = []
	for id in active.keys():
		var remaining: float = active[id] - delta
		if remaining <= 0.0:
			to_expire.append(id)
		else:
			active[id] = remaining
	for id in to_expire:
		active.erase(id)
		buff_expired.emit(id)
	_tick_hp_regen(delta)


func _tick_hp_regen(delta: float) -> void:
	var rate: float = 0.0
	for id in active.keys():
		rate += float(BUFF_DEFS.get(id, {}).get("hp_per_sec", 0.0))
	if rate <= 0.0:
		_hp_remainder = 0.0
		return
	_hp_remainder += rate * delta
	var whole: int = int(_hp_remainder)
	if whole > 0:
		_hp_remainder -= whole
		if GameState:
			GameState.heal(whole)


# Consume one of `food_id` from GameState.resources and apply the
# matching buff. Returns true if a buff was applied.
func eat(food_id: String) -> bool:
	if not FOOD_BUFFS.has(food_id):
		return false
	if not GameState.consume_resource(food_id, 1):
		return false
	apply_buff(String(FOOD_BUFFS[food_id]))
	return true


func apply_buff(id: String) -> void:
	if not BUFF_DEFS.has(id):
		return
	var dur: float = float(BUFF_DEFS[id].get("duration", 0.0))
	active[id] = dur
	buff_applied.emit(id, dur)


func speed_multiplier() -> float:
	var m: float = 1.0
	for id in active.keys():
		m *= float(BUFF_DEFS.get(id, {}).get("speed_mult", 1.0))
	return m


func stamina_regen_multiplier() -> float:
	var m: float = 1.0
	for id in active.keys():
		m *= float(BUFF_DEFS.get(id, {}).get("regen_mult", 1.0))
	return m


func has_buff(id: String) -> bool:
	return active.has(id)


func remaining(id: String) -> float:
	return float(active.get(id, 0.0))


func is_edible(food_id: String) -> bool:
	return FOOD_BUFFS.has(food_id)
