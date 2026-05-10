extends Node3D

# Stone torch column. For now any take_damage hit lights it; once lit
# it stays lit forever and emits target_id on the WorldEvents bus. The
# eventual fire-source rules (sword + torch_lit_sword flag, fire_arrow
# group, neighbour proximity) are stubbed below — the test path just
# checks that *something* hit the basin.
#
# Visuals while lit: spawn a flicker child holding a flame cone mesh
# and an OmniLight3D. Flicker == sub-frame jitter on light energy and
# a tiny sinusoidal scale on the flame.

@export var target_id: String = ""
@export var lit_on_spawn: bool = false

@onready var hitbox: Area3D = $Hitbox
@onready var basin:  Node3D = $Basin
@onready var flame_holder: Node3D = $Basin/Flame

var _lit: bool = false
var _flame_mesh: MeshInstance3D = null
var _light: OmniLight3D = null
var _t: float = 0.0


func _ready() -> void:
	add_to_group("ground_snap")
	add_to_group("torch")
	hitbox.set_deferred("collision_layer", 32)
	hitbox.set_deferred("collision_mask",  0)
	hitbox.set_deferred("monitorable",     true)
	hitbox.set_deferred("monitoring",      false)
	if flame_holder:
		flame_holder.visible = false
	if lit_on_spawn:
		call_deferred("_light_up")


func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
				 attacker: Node3D = null) -> void:
	if _lit:
		return
	# Simplest test path — any hit lights it. The richer rules below
	# can be enabled by gating on these flags once the related items
	# land. Today they all fall through to "true".
	var has_torch_sword: bool = false
	if attacker and attacker.has_method("has_item_flag"):
		has_torch_sword = attacker.has_item_flag("torch_lit_sword")
	var is_fire_arrow: bool = attacker != null and attacker.is_in_group("fire_arrow")
	var _ok: bool = has_torch_sword or is_fire_arrow or true
	_light_up()


func _light_up() -> void:
	if _lit:
		return
	_lit = true
	if flame_holder:
		flame_holder.visible = true
		# Fish out the existing flame mesh + light from the prebuilt
		# basin children if present; lazily synthesize otherwise.
		_flame_mesh = flame_holder.get_node_or_null("FlameMesh") as MeshInstance3D
		_light      = flame_holder.get_node_or_null("Light") as OmniLight3D
	if get_tree().root.has_node("SoundBank"):
		SoundBank.play_3d("crystal_hit", global_position, 0.20)
	WorldEvents.activate(target_id)


func _process(delta: float) -> void:
	if not _lit:
		return
	_t += delta
	if _flame_mesh:
		var s: float = 1.0 + sin(_t * 14.0) * 0.07 + sin(_t * 5.3) * 0.04
		_flame_mesh.scale = Vector3(s, 1.0 + sin(_t * 11.0) * 0.10, s)
	if _light:
		_light.light_energy = 1.6 + sin(_t * 17.0) * 0.25 + (randf() - 0.5) * 0.15
