extends Node3D

# Wall-mounted dungeon crystal. Sword hits flip its activation; while
# active it emits a target_id over the WorldEvents bus so any door /
# bridge listening for that id can react. The hit-area parents the
# crystal mesh and reuses the same `take_damage` dispatch the sword
# already drives for bushes / practice targets / hit_switches.
#
# stays_on=true is the OoT default for permanent puzzle crystals; the
# untoggled variant is mostly useful for combo puzzles where one
# switch's state has to be held inactive while another is hit.

@export var target_id: String = ""
@export var stays_on: bool = false
@export var idle_color:   Color = Color(0.30, 0.55, 0.95, 1.0)
@export var active_color: Color = Color(1.00, 0.55, 0.15, 1.0)

@onready var mesh:   MeshInstance3D = $Visual/Crystal
@onready var hitbox: Area3D         = $Hitbox

var _active: bool = false
var _mat: StandardMaterial3D
var _bob_t: float = 0.0


func _ready() -> void:
	# Sit on layer 32 (Hittable) so the player's sword hitbox picks us
	# up via its existing collision_mask. Deferred so first-tick scene
	# wiring doesn't fight the engine's "in/out signal" guard.
	hitbox.set_deferred("collision_layer", 32)
	hitbox.set_deferred("collision_mask",  0)
	hitbox.set_deferred("monitoring",      false)
	hitbox.set_deferred("monitorable",     true)
	if mesh:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = idle_color
		_mat.emission_enabled = true
		_mat.emission = idle_color
		_mat.emission_energy_multiplier = 0.5
		_mat.metallic = 0.2
		_mat.roughness = 0.25
		mesh.material_override = _mat


func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
				 _attacker: Node3D = null) -> void:
	if _active and stays_on:
		return
	_active = not _active
	_refresh_color()
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("crystal_hit", global_position)
	if target_id == "":
		return
	if _active:
		WorldEvents.activate(target_id)
	else:
		WorldEvents.deactivate(target_id)


func _process(delta: float) -> void:
	# Gentle floaty bob so the crystal reads as "magic" rather than a
	# rock embedded in the stand.
	if not mesh:
		return
	_bob_t += delta
	mesh.position.y = 1.1 + sin(_bob_t * 2.0) * 0.08
	mesh.rotation.y += delta * 0.6


func _refresh_color() -> void:
	if not _mat:
		return
	var c: Color = active_color if _active else idle_color
	_mat.albedo_color = c
	_mat.emission = c
	_mat.emission_energy_multiplier = 1.8 if _active else 0.5
