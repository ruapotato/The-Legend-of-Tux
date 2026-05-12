@tool
extends Node3D

# A named place the dungeon_root can drop Tux at on scene-load. The
# spawn id is read from the node's `spawn_id` meta when present, else
# from the node's name (so default markers can just be named "default"
# or "from_glade" etc.).
#
# Visible as a small green sphere in edit mode; hidden in play.

@export var spawn_id: String = "default":
	set(v):
		spawn_id = v
		set_meta("spawn_id", spawn_id)


func _ready() -> void:
	add_to_group("spawn_marker")
	set_meta("spawn_id", spawn_id if spawn_id != "" else name)
	# Editor-only visual.
	if get_child_count() == 0:
		_build_marker()


func _build_marker() -> void:
	var m := MeshInstance3D.new()
	m.name = "EditorVisual"
	var sm := SphereMesh.new()
	sm.radius = 0.25
	sm.height = 0.5
	m.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.95, 0.45, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.30, 0.95, 0.45)
	mat.emission_energy_multiplier = 0.6
	m.material_override = mat
	m.position = Vector3(0, 0.5, 0)
	add_child(m)
