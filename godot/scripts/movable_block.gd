extends StaticBody3D

# Push-able stone block. Player walks into a face; if they keep
# walking into it for `push_threshold_time` seconds with non-trivial
# velocity into the face normal, the block slides one cell along that
# face's outward axis (snapped to grid) provided the destination cell
# is clear (cheap raycast ahead).
#
# Sliding uses a tween — during the slide the block is "locked" so a
# second push direction can't queue up mid-animation. We don't bother
# with rigidbody physics because a sliding cube would require frictional
# tuning on every floor; static + tween is more predictable for puzzles.

@export var cell_size: float = 1.5
@export var push_threshold_time: float = 0.6
@export var push_threshold_speed: float = 1.2
@export var slide_time: float = 0.30
@export var pushable_layer: int = 1

# Detection volume (slightly larger than the block) catches the player
# pressed up against any of the four faces. The contact normal is then
# inferred from the player's relative position.
@onready var contact_area: Area3D = $ContactArea
@onready var grind_player: Node3D = self

var _push_t: float = 0.0
var _push_dir: Vector3 = Vector3.ZERO
var _sliding: bool = false


func _ready() -> void:
	add_to_group("ground_snap")
	add_to_group("pushable")
	# Snap to grid on spawn so author-positioned blocks always sit
	# on cell centers even if the JSON left them slightly off.
	var sx := cell_size
	global_position = Vector3(
		round(global_position.x / sx) * sx,
		global_position.y,
		round(global_position.z / sx) * sx,
	)


func _physics_process(delta: float) -> void:
	if _sliding:
		return
	# Look at every player CharacterBody3D currently overlapping the
	# contact area. There's normally exactly one; tolerate zero/many.
	var pushers: Array = []
	for b in contact_area.get_overlapping_bodies():
		if b.is_in_group("player"):
			pushers.append(b)
	if pushers.is_empty():
		_push_t = 0.0
		_push_dir = Vector3.ZERO
		return
	var pl: CharacterBody3D = pushers[0]
	# Discrete face: pick the cardinal axis the player is closest to.
	var rel: Vector3 = global_position - pl.global_position
	rel.y = 0.0
	if rel.length_squared() < 1e-4:
		return
	var dir: Vector3
	if abs(rel.x) > abs(rel.z):
		dir = Vector3(sign(rel.x), 0, 0)
	else:
		dir = Vector3(0, 0, sign(rel.z))
	# Player's planar velocity into the block face must be substantial.
	var v: Vector3 = pl.velocity
	v.y = 0.0
	var into: float = v.dot(dir)
	if into < push_threshold_speed:
		_push_t = 0.0
		_push_dir = Vector3.ZERO
		return
	if dir != _push_dir:
		_push_dir = dir
		_push_t = 0.0
	_push_t += delta
	if _push_t >= push_threshold_time:
		_try_slide(dir)
		_push_t = 0.0
		_push_dir = Vector3.ZERO


func _try_slide(dir: Vector3) -> void:
	var dest: Vector3 = global_position + dir * cell_size
	# Cheap occupancy check: a short ray from the block center toward
	# the destination cell along the world layer (1). Ignore self.
	var space := get_world_3d().direct_space_state
	var from: Vector3 = global_position + Vector3(0, 0.6, 0)
	var to: Vector3 = dest + Vector3(0, 0.6, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = pushable_layer
	q.exclude = [self.get_rid()]
	var hit := space.intersect_ray(q)
	if hit:
		return
	_sliding = true
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("gate_open", global_position, 0.10)
	var t := create_tween()
	t.tween_property(self, "global_position", dest, slide_time)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_callback(func(): _sliding = false)


# Plates / receivers can call this to confirm the block is "settled" on
# them; right now this is purely a marker — the plate's body_entered
# does the work via the "pushable" group.
func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
				 _attacker: Node3D = null) -> void:
	pass
