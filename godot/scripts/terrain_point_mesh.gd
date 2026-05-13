@tool
extends StaticBody3D

# Point-based terrain. Child Node3Ds in group `terrain_point` are
# control points whose local positions define a 2D Delaunay
# triangulation over (x, z); each triangle is lifted to 3D using the
# point's y. The mesh + a ConcavePolygonShape3D collider are rebuilt
# whenever the point set changes, so the user can fly around, drop
# points, and watch a complex landscape form between them. Use this
# for OoT-style hills/valleys/ramps that don't fit a square grid.
#
# Points stay in the scene at runtime (they're how the mesh rebuilds
# on _ready), but their yellow editor sphere is hidden in play via
# the "terrain_point_vis" group, which editor_mode toggles.

const POINT_GROUP := "terrain_point"
const POINT_VIS_GROUP := "terrain_point_vis"
const DEFAULT_COLOR := Color(0.40, 0.55, 0.30, 1)   # grass green

# Each TerrainPointMesh has one solid colour applied to every triangle.
# Mix colours by placing multiple meshes side by side. Changing the
# colour triggers a rebuild so the swap is live.
@export var terrain_color: Color = DEFAULT_COLOR:
	set(v):
		terrain_color = v
		if is_inside_tree():
			rebuild()

# Lighting / shading mode. Default UNSHADED — every triangle reads as
# the exact `terrain_color` regardless of slope. This stops the
# "patchwork of slightly-different greens" effect that smooth-shaded
# slopes produce. Set `shaded = true` if you want real lighting and
# shadows on a piece of terrain (e.g. a hillside you want sculpted
# definition on).
@export var shaded: bool = false:
	set(v):
		shaded = v
		if is_inside_tree():
			rebuild()

var _mesh_inst: MeshInstance3D = null
var _coll: CollisionShape3D = null
var _cached_positions: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	add_to_group("terrain_point_mesh")
	collision_layer = 1
	collision_mask = 0
	set_process(true)
	# Legacy saves: scenes saved by an older version of this script had
	# child Points as plain Node3D (no group, no meta) and a baked
	# Mesh + Shape sibling. Without migration those points are invisible
	# to _gather_positions, so a freshly-added Point4 looks like it's
	# floating in a brand new mesh. Promote any Point* children to the
	# group + meta, and drop the stale Mesh/Shape so rebuild re-makes
	# them with the correct vertex set.
	_migrate_legacy_children()
	# Defer so newly-instantiated child points settle first.
	call_deferred("rebuild")


func _migrate_legacy_children() -> void:
	for c in get_children():
		var nm: String = c.name
		if c is Node3D and nm.begins_with("Point"):
			if not c.is_in_group(POINT_GROUP):
				c.add_to_group(POINT_GROUP)
			c.set_meta("is_terrain_point", true)
		elif (c is MeshInstance3D and nm == "Mesh") \
				or (c is CollisionShape3D and nm == "Shape"):
			c.queue_free()


func _process(_delta: float) -> void:
	var positions: PackedVector3Array = _gather_positions()
	if positions != _cached_positions:
		_cached_positions = positions
		rebuild()


func _gather_positions() -> PackedVector3Array:
	# Match either the group OR a meta flag — groups set at runtime via
	# add_to_group don't always survive a PackedScene → instantiate
	# round-trip (which is exactly the undo-redo path). The meta flag
	# does survive because it's a Variant on the node.
	var out := PackedVector3Array()
	for c in get_children():
		if c is Node3D and ((c as Node3D).is_in_group(POINT_GROUP)
				or c.has_meta("is_terrain_point")):
			out.append((c as Node3D).position)
	return out


func rebuild() -> void:
	if _mesh_inst and is_instance_valid(_mesh_inst):
		_mesh_inst.queue_free()
	if _coll and is_instance_valid(_coll):
		_coll.queue_free()
	_mesh_inst = null
	_coll = null
	# Belt-and-braces: any orphan Mesh/Shape we didn't track (e.g. from
	# a legacy save) gets dropped here so we don't end up with duplicate
	# visuals layered on top of each other.
	for c in get_children():
		if (c is MeshInstance3D and c.name == "Mesh") \
				or (c is CollisionShape3D and c.name == "Shape"):
			c.queue_free()
	var positions: PackedVector3Array = _gather_positions()
	print("[TPM rebuild] points=%d positions=%s" % [positions.size(), str(positions)])
	if positions.size() < 3:
		print("[TPM rebuild] < 3 points, no mesh")
		return
	var pts2 := PackedVector2Array()
	for p in positions:
		pts2.append(Vector2(p.x, p.z))
	var idx: PackedInt32Array = Geometry2D.triangulate_delaunay(pts2)
	print("[TPM rebuild] triangulation produced %d indices" % idx.size())
	if idx.is_empty():
		print("[TPM rebuild] triangulation EMPTY (collinear/duplicate points?)")
		return
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(positions.size())
	normals.resize(positions.size())
	colors.resize(positions.size())
	for i in positions.size():
		verts[i] = positions[i]
		normals[i] = Vector3.ZERO
		colors[i] = terrain_color
	var tri_count: int = idx.size() / 3
	for t in tri_count:
		var i0: int = idx[t * 3]
		var i1: int = idx[t * 3 + 1]
		var i2: int = idx[t * 3 + 2]
		var n: Vector3 = (verts[i1] - verts[i0]).cross(verts[i2] - verts[i0])
		normals[i0] += n
		normals[i1] += n
		normals[i2] += n
	for i in normals.size():
		var nn: Vector3 = normals[i]
		if nn.length_squared() > 0:
			normals[i] = nn.normalized()
			if normals[i].y < 0.0:
				normals[i] = -normals[i]
		else:
			normals[i] = Vector3.UP
	var arrs := []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = verts
	arrs[Mesh.ARRAY_NORMAL] = normals
	arrs[Mesh.ARRAY_COLOR] = colors
	arrs[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "Mesh"
	_mesh_inst.mesh = am
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if not shaded:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh_inst.material_override = mat
	add_child(_mesh_inst)
	var faces := PackedVector3Array()
	for t in tri_count:
		faces.append(verts[idx[t * 3]])
		faces.append(verts[idx[t * 3 + 1]])
		faces.append(verts[idx[t * 3 + 2]])
	var shape := ConcavePolygonShape3D.new()
	shape.data = faces
	# Two-sided so click-pick + falling bodies work regardless of which
	# way the Delaunay output happened to wind each triangle.
	shape.backface_collision = true
	_coll = CollisionShape3D.new()
	_coll.name = "Shape"
	_coll.shape = shape
	add_child(_coll)


# Public — called by editor_ui when P is pressed with a Terrain Mesh
# (or one of its child points) selected. local_pos is in this node's
# local frame. Returns a StaticBody3D so the editor's center-raycast
# can click-pick the point and the user can drag/delete it like any
# other selectable. Layer 7 (Interactable, bit 6 = 64) keeps it out
# of the player's physics mask in play mode (mask 5 = layers 1+3).
func add_point(local_pos: Vector3) -> Node3D:
	var idx: int = _point_count() + 1
	var p := StaticBody3D.new()
	p.position = local_pos
	p.collision_layer = 64
	p.collision_mask = 0
	p.add_to_group(POINT_GROUP)
	p.set_meta("is_terrain_point", true)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var sp := SphereShape3D.new()
	sp.radius = 0.4
	cs.shape = sp
	p.add_child(cs)
	var vis := MeshInstance3D.new()
	vis.name = "Vis"
	var sm := SphereMesh.new()
	sm.radius = 0.3
	sm.height = 0.6
	vis.mesh = sm
	var vmat := StandardMaterial3D.new()
	vmat.albedo_color = Color(1.0, 0.85, 0.20, 1)
	vmat.flags_unshaded = true
	vis.material_override = vmat
	vis.add_to_group(POINT_VIS_GROUP)
	p.add_child(vis)
	add_child(p)
	# Set name AFTER add_child — Godot auto-generates a node name during
	# add_child for unnamed nodes, and we want our human-readable name to
	# win regardless of internal naming order. This also keeps the path
	# stable when get_path() is taken for undo.
	p.name = "Point%d" % idx
	print("[TPM] add_point idx=%d final_name=%s path=%s" % [idx, p.name, str(p.get_path())])
	return p


func _point_count() -> int:
	var n := 0
	for c in get_children():
		if c is Node3D and (c as Node3D).is_in_group(POINT_GROUP):
			n += 1
	return n
