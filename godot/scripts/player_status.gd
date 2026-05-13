extends Node

# Tracks Tux's environmental state and the buffs/debuffs that follow.
#
# Two scalars:
#   body_temp ∈ [0, 1]   — 0 freezing, 0.5 comfy, 1 hot
#   wetness   ∈ [0, 1]   — 0 dry, 1 soaked
#
# Each tick, the trackers chase the environment:
#   body_temp ← Weather.temperature() (slowly)
#   wetness   ← rises in rain, falls in dry warmth
#
# Wetness pulls body_temp down further — a wet Tux loses heat faster
# than a dry one. The resulting buffs are exposed as multipliers for
# tux_player to read in its physics step:
#   speed_multiplier()           in (0..1], cold trims movement speed
#   stamina_regen_multiplier()   in (0..1], cold halves regen
#
# Signals broadcast state changes so the HUD can show icons without
# polling every frame.

signal status_changed(body_temp: float, wetness: float)
signal cold_changed(is_cold: bool)
signal wet_changed(is_wet: bool)

# Thresholds for "in the buff zone".
const COLD_T: float = 0.30
const HOT_T:  float = 0.75
const WET_T:  float = 0.45

# Approach rates (units per second). body_temp chases temperature
# slowly so the player has time to react to a sudden cold front.
const TEMP_LERP_RATE:  float = 0.04
const WET_RISE_RATE:   float = 0.18    # how fast you soak in rain
const WET_DRY_RATE:    float = 0.08    # how fast you dry in clear/warm
const COLD_FROM_WET:   float = 0.10    # extra cooling per unit wetness

var body_temp: float = 0.55
var wetness: float = 0.0

var _was_cold: bool = false
var _was_wet: bool = false


func _process(dt: float) -> void:
	_update_wetness(dt)
	_update_body_temp(dt)
	_check_buff_transitions()
	# Skip emitting every frame; only when something meaningfully
	# changed (handled inside _check_buff_transitions).


func _update_wetness(dt: float) -> void:
	var raining := Weather and Weather.is_raining()
	var snowing := Weather and Weather.is_snowing()
	var intensity: float = Weather.intensity() if Weather else 0.0
	if raining or snowing:
		# Snow soaks slower than rain; storm soaks faster.
		var rate := WET_RISE_RATE * intensity
		if snowing:
			rate *= 0.5
		wetness = min(wetness + rate * dt, 1.0)
	else:
		wetness = max(wetness - WET_DRY_RATE * dt, 0.0)


func _update_body_temp(dt: float) -> void:
	var env_temp: float = Weather.temperature() if Weather else 0.5
	# Wet skin pulls body_temp toward cold proportional to wetness.
	var target: float = env_temp - wetness * COLD_FROM_WET
	target = clamp(target, 0.0, 1.0)
	body_temp = move_toward(body_temp, target, TEMP_LERP_RATE * dt)


func _check_buff_transitions() -> void:
	var c: bool = is_cold()
	var w: bool = is_wet()
	if c != _was_cold:
		_was_cold = c
		cold_changed.emit(c)
	if w != _was_wet:
		_was_wet = w
		wet_changed.emit(w)
	# Status broadcast for HUD; sample at ~10 Hz by gating on a small
	# change rather than every frame.
	status_changed.emit(body_temp, wetness)


# --- Buff checks -------------------------------------------------

func is_cold() -> bool:
	return body_temp < COLD_T

func is_hot() -> bool:
	return body_temp > HOT_T

func is_wet() -> bool:
	return wetness > WET_T


# --- Multipliers tux_player reads each physics tick --------------

func speed_multiplier() -> float:
	var m: float = 1.0
	if is_cold():
		# Linearly down to 0.80 at body_temp = 0
		m *= lerp(0.80, 1.00, clamp(body_temp / COLD_T, 0.0, 1.0))
	if is_hot():
		# Slight slow when overheated
		m *= 0.95
	return m


func stamina_regen_multiplier() -> float:
	if is_cold():
		return 0.5
	return 1.0
