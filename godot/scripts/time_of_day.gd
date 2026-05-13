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
	"sun_color":      Color(0.40, 0.50, 0.85),   # moonlight tint
	"sun_energy":     0.10,
	"ambient_color":  Color(0.10, 0.15, 0.30),
	"ambient_energy": 0.25,
	"sky_top":        Color(0.02, 0.03, 0.10),
	"sky_horizon":    Color(0.05, 0.07, 0.18),
	"ground_horizon": Color(0.04, 0.05, 0.10),
	"ground_bottom":  Color(0.02, 0.02, 0.05),
}

const DAWN_PALETTE := {
	"sun_color":      Color(1.00, 0.65, 0.50),
	"sun_energy":     0.85,
	"ambient_color":  Color(0.55, 0.40, 0.45),
	"ambient_energy": 0.50,
	"sky_top":        Color(0.30, 0.35, 0.55),
	"sky_horizon":    Color(0.85, 0.55, 0.50),
	"ground_horizon": Color(0.55, 0.40, 0.30),
	"ground_bottom":  Color(0.10, 0.10, 0.15),
}

const DAY_PALETTE := {
	"sun_color":      Color(1.00, 0.96, 0.85),
	"sun_energy":     1.20,
	"ambient_color":  Color(0.85, 0.90, 0.95),
	"ambient_energy": 0.55,
	"sky_top":        Color(0.28, 0.50, 0.85),
	"sky_horizon":    Color(0.65, 0.75, 0.88),
	"ground_horizon": Color(0.40, 0.35, 0.25),
	"ground_bottom":  Color(0.15, 0.13, 0.10),
}

const DUSK_PALETTE := {
	"sun_color":      Color(1.00, 0.55, 0.35),
	"sun_energy":     0.70,
	"ambient_color":  Color(0.65, 0.45, 0.40),
	"ambient_energy": 0.45,
	"sky_top":        Color(0.30, 0.25, 0.40),
	"sky_horizon":    Color(0.90, 0.55, 0.30),
	"ground_horizon": Color(0.45, 0.30, 0.20),
	"ground_bottom":  Color(0.08, 0.07, 0.10),
}

var t: float = 0.30                     # 0..1, normalized day cycle
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
		if _cached_env and _cached_env.environment and _cached_env.environment.sky:
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


# Direction sunlight points (toward the ground).
func sun_dir() -> Vector3:
	var angle: float = t * TAU - PI * 0.5
	return Vector3(0.30, -sin(angle), -cos(angle)).normalized()


func sun_rotation() -> Vector3:
	var angle: float = t * TAU - PI * 0.5
	return Vector3(-angle, 0.0, 0.0)


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
