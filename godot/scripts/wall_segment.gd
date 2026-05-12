@tool
extends StaticBody3D

# A 10m wide × 4m tall × 0.5m thick stone wall, palette-placeable.
# Self-contained — mesh + collider are built in _ready so the .tscn
# stays tiny and resizing happens via the @export.

@export var size: Vector3 = Vector3(10, 4, 0.5):
	set(v):
		size = v
		_rebuild()
@export var color: Color = Color(0.55, 0.55, 0.58, 1):
	set(v):
		color = v
		_rebuild()


func _ready() -> void:
	add_to_group("wall_segment")
	collision_layer = 1
	collision_mask = 0
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
	mat.albedo_color = color
	mat.roughness = 0.85
	mesh.material_override = mat
	mesh.position = Vector3(0, size.y * 0.5, 0)
	add_child(mesh)
	var col := CollisionShape3D.new()
	col.name = "Shape"
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = Vector3(0, size.y * 0.5, 0)
	add_child(col)
