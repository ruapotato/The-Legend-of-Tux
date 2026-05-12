@tool
extends Area3D

# A semi-transparent blue volume the player can swim through. Stores
# `surface_y` (top of the water) as a meta field so anchor-boots logic
# / future swim controllers can find it. No collision — the shape on
# this Area3D is monitoring-only.

@export var size: Vector3 = Vector3(10, 4, 10):
	set(v):
		size = v
		_rebuild()
@export var surface_y: float = 0.0:
	set(v):
		surface_y = v
		set_meta("surface_y", surface_y)


func _ready() -> void:
	add_to_group("water_volume")
	set_meta("kind", "water")
	set_meta("surface_y", surface_y)
	monitoring = false       # informational volume, not a trigger by default
	monitorable = false
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in get_children():
		c.queue_free()
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.42, 0.78, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.25
	mat.metallic_specular = 0.85
	mesh.material_override = mat
	mesh.position = Vector3(0, size.y * 0.5, 0)
	add_child(mesh)
	# Trigger shape (kept here in case future code wants to detect entry)
	var col := CollisionShape3D.new()
	col.name = "Shape"
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = Vector3(0, size.y * 0.5, 0)
	add_child(col)
