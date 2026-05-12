@tool
extends StaticBody3D

# A 30x30m static ground patch — flat plane mesh + matching box
# collider, grass-coloured by default. Editor-placed via the palette;
# also used as the starter slab in level_00.tscn.

@export var size: Vector2 = Vector2(30, 30):
	set(v):
		size = v
		_rebuild()
@export var color: Color = Color(0.30, 0.42, 0.26, 1):
	set(v):
		color = v
		_rebuild()


func _ready() -> void:
	add_to_group("ground_patch")
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
	var pm := PlaneMesh.new()
	pm.size = size
	mesh.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mesh.material_override = mat
	add_child(mesh)
	var col := CollisionShape3D.new()
	col.name = "Shape"
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, 0.4, size.y)
	col.shape = shape
	col.position = Vector3(0, -0.2, 0)
	add_child(col)
