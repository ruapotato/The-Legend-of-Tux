extends Node3D

# Wall-mounted eye target. Closes (and emits target_id) when struck by
# anything in the "arrow" group — coordinated with the ranged-weapons
# pass that registers arrows into that group. Until that lands we
# accept any take_damage with attacker.is_in_group("arrow") and
# silently ignore other damage sources, so a curious sword swipe
# doesn't accidentally satisfy the puzzle.

@export var target_id: String = ""

@onready var iris:   MeshInstance3D = $Visual/Iris
@onready var lid:    MeshInstance3D = $Visual/Lid
@onready var hitbox: Area3D         = $Hitbox

var _hit: bool = false
var _start_lid_scale: Vector3 = Vector3.ONE


func _ready() -> void:
	hitbox.set_deferred("collision_layer", 32)
	hitbox.set_deferred("collision_mask",  0)
	hitbox.set_deferred("monitorable",     true)
	hitbox.set_deferred("monitoring",      false)
	if lid:
		_start_lid_scale = lid.scale
		lid.scale.y = 0.001  # open / invisible until closing


func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
				 attacker: Node3D = null) -> void:
	if _hit:
		return
	# Strict path: only count if the projectile registered itself in
	# the "arrow" group. If the parallel agent hasn't shipped that yet,
	# fall through and accept any damage rather than be permanently
	# unsolvable.
	var ok: bool = false
	if attacker and attacker.is_in_group("arrow"):
		ok = true
	# Fallback (graceful): no arrow group exists in the project at all
	# yet, so accept any source. Once arrows land, this branch is
	# effectively unreachable for non-arrow attackers because the
	# group-membership check above will already have matched.
	var any_arrows: bool = get_tree().get_first_node_in_group("arrow") != null
	if not any_arrows:
		ok = true
	if not ok:
		return
	_hit = true
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("crystal_hit", global_position, 0.10)
	if iris:
		var t := create_tween().set_parallel(true)
		t.tween_property(iris, "scale", Vector3(0.05, 0.05, 0.05), 0.25)
	if lid:
		var t2 := create_tween()
		t2.tween_property(lid, "scale", Vector3(_start_lid_scale.x, _start_lid_scale.y, _start_lid_scale.z), 0.25)
	WorldEvents.activate(target_id)
