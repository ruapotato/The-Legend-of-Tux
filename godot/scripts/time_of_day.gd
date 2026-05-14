extends Node

# Global time-of-day clock. Advances `t` (0..1, where 0 = midnight,
# 0.5 = noon) on a configurable real-time period.
#
# v2: four anchor palettes (NIGHT / DAWN / DAY / DUSK) that the cycle
# lerps between as `t` advances, driving sun colour + energy + rotation,
# ambient colour + energy, AND the WorldEnvironment's
# ProceduralSkyMaterial top / horizon / ground colours so the sky reads
# correctly through dawn, blue daylight, sunset, and a deep moonlit
# night. Architecture inspired by /home/david/hamberg/shared/
# day_night_cycle.gd (user's own AGPL project).
#
# Public API preserved from v1: set_t, advance_to, pause, resume,
# is_night, sun_dir, sun_rotation, sun_color, sun_energy,
# ambient_color, ambient_energy, hour_passed signal.

signal hour_passed(t: float)
signal period_changed(period: String)   # "dawn" | "day" | "dusk" | "night"

const DAY_LENGTH_SEC: float = 600.0    # real-time seconds per game day

# Anchor positions on the 0..1 cycle.
const T_MIDNIGHT: float = 0.0
const T_DAWN:     float = 0.25
const T_NOON:     float = 0.50
const T_DUSK:     float = 0.75

# --- Anchor palettes -----------------------------------------------------
# Each palette: {sun_color, sun_energy, ambient_color, ambient_energy,
#                sky_top, sky_horizon, ground_horizon, ground_bottom}.
# Forest-realm tuning: cool blue-purple night, soft amber dawn, clear
# blue daylight, warm rose dusk. Adjacent palettes lerp smoothly.

const NIGHT_PALETTE := {
	"sun_color":      Color(0.30, 0.42, 0.78),   # cool moonlight tint
	"sun_energy":     0.04,                       # deep night — no sun
	"ambient_color":  Color(0.06, 0.08, 0.22),
	"ambient_energy": 0.12,                       # very dark ambient
	"sky_top":        Color(0.005, 0.008, 0.040),  # near-black navy at zenith
	"sky_horizon":    Color(0.025, 0.040, 0.110),  # deep blue band
	"ground_horizon": Color(0.020, 0.025, 0.060),
	"ground_bottom":  Color(0.005, 0.005, 0.020),
}

const DAWN_PALETTE := {
	"sun_color":      Color(1.00, 0.62, 0.42),
	"sun_energy":     0.85,
	"ambient_color":  Color(0.55, 0.42, 0.48),
	"ambient_energy": 0.50,
	"sky_top":        Color(0.18, 0.22, 0.50),    # still dim aloft during dawn
	"sky_horizon":    Color(0.92, 0.55, 0.48),    # warm pink-amber band rolling in from east
	"ground_horizon": Color(0.55, 0.38, 0.28),
	"ground_bottom":  Color(0.08, 0.08, 0.14),
}

const DAY_PALETTE := {
	"sun_color":      Color(1.00, 0.96, 0.86),
	"sun_energy":     1.50,
	"ambient_color":  Color(0.62, 0.78, 1.00),
	"ambient_energy": 0.80,
	"sky_top":        Color(0.05, 0.28, 0.92),    # deep vibrant blue zenith
	"sky_horizon":    Color(0.48, 0.72, 0.98),    # bright pale-blue horizon
	"ground_horizon": Color(0.40, 0.36, 0.26),
	"ground_bottom":  Color(0.12, 0.11, 0.09),
}

const DUSK_PALETTE := {
	"sun_color":      Color(1.00, 0.50, 0.28),
	"sun_energy":     0.70,
	"ambient_color":  Color(0.62, 0.42, 0.42),
	"ambient_energy": 0.42,
	"sky_top":        Color(0.20, 0.18, 0.42),    # dusky violet aloft
	"sky_horizon":    Color(0.95, 0.50, 0.26),    # warm orange-rose band over horizon
	"ground_horizon": Color(0.42, 0.28, 0.18),
	"ground_bottom":  Color(0.06, 0.06, 0.10),
}

var t: float = 0.42                     # 0..1, normalized day cycle (mid-morning so the sky is properly blue on first boot)
var paused: bool = false
var _last_hour_idx: int = -1
var _current_period: String = "day"

# Cached scene-level nodes — we don't walk the tree every frame.
var _cached_scene: Node = null
var _cached_sun: DirectionalLight3D = null
var _cached_env: WorldEnvironment = null
var _cached_sky_mat: ProceduralSkyMaterial = null


# --- Tick -------------------------------------------------------------

func _process(delta: float) -> void:
	if not paused:
		t = fposmod(t + delta / DAY_LENGTH_SEC, 1.0)
		var hour_idx: int = int(t * 24.0)
		if hour_idx != _last_hour_idx:
			_last_hour_idx = hour_idx
			hour_passed.emit(t)
		var p: String = _period_for(t)
		if p != _current_period:
			_current_period = p
			period_changed.emit(p)
	_apply_to_scene()


func _apply_to_scene() -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return
	if scene != _cached_scene:
		_cached_scene = scene
		_cached_sun = _find(scene, "DirectionalLight3D") as DirectionalLight3D
		_cached_env = _find(scene, "WorldEnvironment") as WorldEnvironment
		_cached_sky_mat = null
	# Re-fetch the sky material lazily — the env may exist but its sky
	# resource may not be ready on the first cache pass (sub-resource
	# load timing). Once cached, this branch becomes a single null check.
	if _cached_sky_mat == null and _cached_env and _cached_env.environment \
			and _cached_env.environment.sky:
		var sm = _cached_env.environment.sky.sky_material
		if sm is ProceduralSkyMaterial:
			_cached_sky_mat = sm
	var pal: Dictionary = current_palette()
	if _cached_sun and is_instance_valid(_cached_sun):
		_cached_sun.rotation = sun_rotation()
		_cached_sun.light_color = pal["sun_color"]
		_cached_sun.light_energy = pal["sun_energy"]
	if _cached_env and is_instance_valid(_cached_env) and _cached_env.environment:
		_cached_env.environment.ambient_light_color = pal["ambient_color"]
		_cached_env.environment.ambient_light_energy = pal["ambient_energy"]
	if _cached_sky_mat:
		_cached_sky_mat.sky_top_color       = pal["sky_top"]
		_cached_sky_mat.sky_horizon_color   = pal["sky_horizon"]
		_cached_sky_mat.ground_horizon_color = pal["ground_horizon"]
		_cached_sky_mat.ground_bottom_color  = pal["ground_bottom"]


func _find(root: Node, type_name: String) -> Node:
	if root.get_class() == type_name:
		return root
	for child in root.get_children():
		var hit: Node = _find(child, type_name)
		if hit != null:
			return hit
	return null


# --- Period blending -------------------------------------------------

# Returns the palette interpolated between the two adjacent anchors
# bracketing the current `t`. Each anchor sits at a quarter-day point;
# the in-between palette is a per-key lerp.
func current_palette() -> Dictionary:
	# Find which quarter we're in and where between its endpoints.
	# Anchors in order: midnight, dawn, noon, dusk, midnight (wrap).
	var anchors := [
		[T_MIDNIGHT, NIGHT_PALETTE],
		[T_DAWN,     DAWN_PALETTE],
		[T_NOON,     DAY_PALETTE],
		[T_DUSK,     DUSK_PALETTE],
		[1.0,        NIGHT_PALETTE],
	]
	for i in 4:
		var a_t: float = anchors[i][0]
		var b_t: float = anchors[i + 1][0]
		if t >= a_t and t <= b_t:
			var phase: float = (t - a_t) / max(b_t - a_t, 0.0001)
			# smoothstep softens the crossings so noon doesn't snap to dusk.
			phase = phase * phase * (3.0 - 2.0 * phase)
			return _lerp_palette(anchors[i][1], anchors[i + 1][1], phase)
	return DAY_PALETTE


static func _lerp_palette(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	return {
		"sun_color":      (a["sun_color"] as Color).lerp(b["sun_color"], w),
		"sun_energy":     lerp(float(a["sun_energy"]), float(b["sun_energy"]), w),
		"ambient_color":  (a["ambient_color"] as Color).lerp(b["ambient_color"], w),
		"ambient_energy": lerp(float(a["ambient_energy"]), float(b["ambient_energy"]), w),
		"sky_top":        (a["sky_top"] as Color).lerp(b["sky_top"], w),
		"sky_horizon":    (a["sky_horizon"] as Color).lerp(b["sky_horizon"], w),
		"ground_horizon": (a["ground_horizon"] as Color).lerp(b["ground_horizon"], w),
		"ground_bottom":  (a["ground_bottom"] as Color).lerp(b["ground_bottom"], w),
	}


static func _period_for(time_t: float) -> String:
	if time_t < 0.20:
		return "night"
	if time_t < 0.32:
		return "dawn"
	if time_t < 0.68:
		return "day"
	if time_t < 0.82:
		return "dusk"
	return "night"


# --- Public API (preserved from v1) ----------------------------------

func set_t(new_t: float) -> void:
	t = clamp(new_t, 0.0, 1.0)


# Dev-console alias. Same semantics as set_t — clamp to [0, 1] and write
# directly without disturbing pause/tween state. Provided so callers that
# look up a `set_time` setter (the dev console; future cutscene scripts)
# don't have to know the legacy field name.
func set_time(new_t: float) -> void:
	set_t(new_t)


func pause() -> void:
	paused = true


func resume() -> void:
	paused = false


const ADVANCE_TWEEN_SEC: float = 1.5

func advance_to(target_t: float) -> void:
	var clamped: float = clamp(target_t, 0.0, 1.0)
	var delta: float = clamped - t
	if delta > 0.5:
		delta -= 1.0
	elif delta < -0.5:
		delta += 1.0
	var dest: float = t + delta
	paused = true
	var tw := create_tween()
	tw.tween_property(self, "t", dest, ADVANCE_TWEEN_SEC)
	tw.tween_callback(Callable(self, "_on_advance_tween_done").bind(clamped))


func _on_advance_tween_done(target_t: float) -> void:
	t = fposmod(target_t, 1.0)
	paused = false


# Sun orbits the world over 24 in-game hours on a plane tilted ~30° off
# vertical so the arc rises in the east, climbs through a southerly
# zenith, and sets in the west — the hamberg pattern. Midnight = nadir,
# noon = zenith.
const SUN_ORBIT_TILT: float = 0.5236   # 30° in radians

# World-space vector pointing TOWARD the sun (above horizon when y > 0).
# This is the opposite of "sun_dir" which historically means the direction
# light TRAVELS — we keep the old semantics for `sun_dir()` below.
func _sun_world_pos_dir() -> Vector3:
	var hour_angle: float = t * TAU                  # 0 at midnight, PI at noon
	var sun_height: float = -cos(hour_angle)         # -1 midnight, +1 noon
	var sun_horizontal: float = sin(hour_angle)      # +1 at dawn (east), -1 at dusk (west)
	var x: float = sun_horizontal
	var y: float = sun_height * cos(SUN_ORBIT_TILT)
	var z: float = -sun_height * sin(SUN_ORBIT_TILT) # tilt arc toward south
	return Vector3(x, y, z).normalized()


# Direction sunlight points (toward the ground / downward) — preserved
# semantics from v1. Equals -sun_world_pos_dir().
func sun_dir() -> Vector3:
	return -_sun_world_pos_dir()


# Euler rotation for the DirectionalLight3D so its local -Z aligns with
# sun_dir(). We build a Basis via looking_at and return its Euler.
func sun_rotation() -> Vector3:
	var dir: Vector3 = sun_dir()
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	# Avoid degenerate up-vector when the sun is straight overhead/below.
	var up: Vector3 = Vector3.UP
	if absf(dir.normalized().y) > 0.99:
		up = Vector3.FORWARD
	var basis: Basis = Basis.looking_at(dir, up)
	return basis.get_euler()


# Back-compat accessors that older callers (song_book, time_gate, etc.)
# expect — pull from the current palette so behaviour stays consistent.
func sun_color() -> Color:
	return current_palette()["sun_color"]


func sun_energy() -> float:
	return float(current_palette()["sun_energy"])


func ambient_color() -> Color:
	return current_palette()["ambient_color"]


func ambient_energy() -> float:
	return float(current_palette()["ambient_energy"])


func is_night() -> bool:
	return _current_period == "night"


func current_period() -> String:
	return _current_period
