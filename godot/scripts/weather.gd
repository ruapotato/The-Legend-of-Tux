extends Node

# Global weather state machine. Picks a new weather every 4–10 game
# minutes, biased by the current temperature (cold → snow, mild →
# rain). Intensity ramps up/down over 30 s on transitions so changes
# read on-screen.
#
# v1: state + intensity only. Particle effects, sky darkening, and
# fog will hook in by reading from this autoload in their own scripts.
# Player status reads is_raining() / is_snowing() + intensity() to
# accumulate wetness + cold.

signal weather_changed(state: String)
signal intensity_changed(value: float)

enum State { CLEAR, RAIN, SNOW, STORM }

const STATE_NAMES := {
	State.CLEAR: "clear",
	State.RAIN:  "rain",
	State.SNOW:  "snow",
	State.STORM: "storm",
}

const MIN_DURATION: float = 240.0    # 4 minutes
const MAX_DURATION: float = 600.0    # 10 minutes
const STORM_MIN: float = 90.0
const STORM_MAX: float = 240.0

const TRANSITION_SEC: float = 30.0   # ramp in/out

# Temperature thresholds for what's reasonable in this climate.
const FREEZING: float = 0.35          # below this, snow not rain
const STORM_CEILING: float = 0.55     # storms only when warm-ish

var _state: int = State.CLEAR
var _target_intensity: float = 0.0
var _intensity: float = 0.0
var _state_time_remaining: float = 60.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func _process(dt: float) -> void:
	_state_time_remaining -= dt
	if _state_time_remaining <= 0.0:
		_pick_next()
	# Smoothly ease the intensity toward the target.
	var step: float = dt / TRANSITION_SEC
	var prev: float = _intensity
	_intensity = move_toward(_intensity, _target_intensity, step)
	if not is_equal_approx(prev, _intensity):
		intensity_changed.emit(_intensity)


func _pick_next() -> void:
	var temp: float = temperature()
	var rolls: Array[int] = []
	# Always allow clear.
	rolls.append(State.CLEAR)
	rolls.append(State.CLEAR)
	# Rain when warm-ish, snow when cold.
	if temp >= FREEZING:
		rolls.append(State.RAIN)
		rolls.append(State.RAIN)
	else:
		rolls.append(State.SNOW)
		rolls.append(State.SNOW)
	# Storms only in warmer + already-rainy regimes.
	if temp >= STORM_CEILING and _state == State.RAIN:
		rolls.append(State.STORM)
	var next: int = rolls[_rng.randi() % rolls.size()]
	_enter(next)


func _enter(s: int) -> void:
	_state = s
	if s == State.STORM:
		_state_time_remaining = _rng.randf_range(STORM_MIN, STORM_MAX)
		_target_intensity = 1.0
	elif s == State.CLEAR:
		_state_time_remaining = _rng.randf_range(MIN_DURATION, MAX_DURATION)
		_target_intensity = 0.0
	else:
		_state_time_remaining = _rng.randf_range(MIN_DURATION, MAX_DURATION)
		_target_intensity = _rng.randf_range(0.4, 0.85)
	weather_changed.emit(STATE_NAMES[_state])


# --- Public API -----------------------------------------------------

func is_clear() -> bool:
	return _state == State.CLEAR

func is_raining() -> bool:
	return _state == State.RAIN or _state == State.STORM

func is_snowing() -> bool:
	return _state == State.SNOW

func is_storming() -> bool:
	return _state == State.STORM

# Lerps from clear toward target as state stabilizes. 0 in clear,
# up to 1 in a full storm.
func intensity() -> float:
	return _intensity

# Coarse temperature in [0, 1] driven by TimeOfDay. Used to pick
# rain vs snow + as the input to the player's cold-buff tracker.
# 0 = freezing, 0.5 = mild, 1 = hot. No seasons yet — only diurnal.
func temperature() -> float:
	var t: float = TimeOfDay.t if TimeOfDay else 0.5
	# Hottest at noon (t=0.5), coldest at midnight (t=0.0 or 1.0).
	var s: float = sin(t * TAU - PI * 0.5)         # -1 at midnight, +1 at noon
	return lerp(0.25, 0.70, (s + 1.0) * 0.5)


func get_state_name() -> String:
	return STATE_NAMES[_state]


# Force a particular state. For debug or scripted events.
func force_state(name: String) -> void:
	for k in STATE_NAMES.keys():
		if STATE_NAMES[k] == name:
			_enter(k)
			return
