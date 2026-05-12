extends RefCounted

# Paint-tool controller for terrain_patch_edit cells. Mirrors the
# sculpt tool: radius, strength (unused — paint is binary per cell),
# cursor, stroke snapshot, throttle.

var active: bool = false
var terrain: Node = null
var radius: float = 3.0
var surf_id: int = 1                # default to "path" so a fresh tool paints something visible
var cursor_world: Vector3 = Vector3.ZERO
var painting: bool = false

var _stroke_before: PackedByteArray = PackedByteArray()

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


func set_surface(id: int) -> void:
	surf_id = clamp(id, 0, 6)


func begin_stroke() -> void:
	if terrain == null:
		return
	painting = true
	_stroke_before = terrain.get_surfaces()


func tick() -> void:
	if not painting or terrain == null:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_apply_ms < APPLY_INTERVAL_MS:
		return
	_last_apply_ms = now
	terrain.paint(cursor_world, radius, surf_id)


func end_stroke() -> Dictionary:
	painting = false
	if terrain == null:
		return {}
	var before: PackedByteArray = _stroke_before
	var after: PackedByteArray = terrain.get_surfaces()
	_stroke_before = PackedByteArray()
	if before.size() == 0:
		return {}
	return {
		"type": "paint",
		"before": before,
		"after": after,
	}
