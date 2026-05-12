extends RefCounted

# Sculpt-tool controller for terrain_patch_edit. Owned by editor_ui:
# - enter(terrain)  → activate, attach cursor preview
# - exit()          → tear down
# - update(...)     → called each frame from _process while active
# - paint_tick(...) → called each frame while LMB held to apply brush
#
# Holds brush radius (0.5–20m) and strength (0.1–1.0). UI presses
# `[`/`]` and `1..9` route through here. Snapshots the heights array
# before a stroke starts so the undo stack can revert.

const MODE_RAISE  := "raise"
const MODE_LOWER  := "lower"
const MODE_SMOOTH := "smooth"
const MODE_FLATTEN := "flatten"

var active: bool = false
var terrain: Node = null            # terrain_patch_edit instance
var radius: float = 4.0
var strength: float = 0.5
var cursor_world: Vector3 = Vector3.ZERO
var painting: bool = false
var mode: String = MODE_RAISE

# Snapshot of heights at stroke start — committed to the undo stack
# when the user releases LMB.
var _stroke_before: PackedFloat32Array = PackedFloat32Array()

# Rebuild throttle — at most every 30ms.
var _last_apply_ms: int = 0
const APPLY_INTERVAL_MS: int = 30


func enter(t: Node) -> void:
	active = true
	terrain = t


func exit() -> void:
	active = false
	terrain = null
	painting = false


func set_radius_delta(delta: float) -> void:
	radius = clamp(radius + delta, 0.5, 20.0)


func set_strength(s: float) -> void:
	strength = clamp(s, 0.1, 1.0)


func begin_stroke(m: String) -> void:
	if terrain == null:
		return
	painting = true
	mode = m
	_stroke_before = terrain.get_heights()


# Called repeatedly while painting=true; dt is delta from last frame.
# We throttle the actual rebuild to APPLY_INTERVAL_MS to keep big
# brushes responsive without thrashing the GPU.
func tick(dt: float) -> void:
	if not painting or terrain == null:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_apply_ms < APPLY_INTERVAL_MS:
		return
	_last_apply_ms = now
	# Strength is "meters per second at full falloff".
	var per_sec: float = strength * 4.0
	terrain.sculpt(cursor_world, radius, per_sec, dt, mode)


func end_stroke() -> Dictionary:
	# Returns an undo action dict the caller pushes onto the stack.
	# Caller is responsible for resolving `target` into a NodePath.
	painting = false
	if terrain == null:
		return {}
	var before: PackedFloat32Array = _stroke_before
	var after: PackedFloat32Array = terrain.get_heights()
	_stroke_before = PackedFloat32Array()
	if before.size() == 0:
		return {}
	return {
		"type": "sculpt",
		"before": before,
		"after": after,
	}
