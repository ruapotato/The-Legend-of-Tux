@tool
extends StaticBody3D

# Editable heightmap terrain. Grid of (grid_size+1)² vertices arranged
# on a regular XZ lattice, per-vertex Y stored in `_heights` (a flat
# PackedFloat32Array), per-cell surface kind in `_surfaces` (a flat
# PackedByteArray of length grid_size²).
#
# Persistence: heights+surfaces+grid_size+cell_size are mirrored into
# node metadata on every change so a PackedScene.pack() roundtrip
# preserves the sculpted terrain. _ready reads metadata back and
# rebuilds the mesh+collision; first-time use seeds a flat patch.
#
# Painting / sculpting is performed externally by editor_sculpt.gd /
# editor_paint.gd. They call apply_heights_delta() / apply_paint() to
# rebuild incrementally. We expose `terrain_changed` so the inspector
# can refresh derived UI (vertex count, area, etc.) if needed.

signal terrain_changed

const MAX_GRID: int = 128
const DEFAULT_GRID: int = 32
const DEFAULT_CELL: float = 2.0

@export var grid_size: int = DEFAULT_GRID:
	set(v):
		grid_size = clamp(v, 2, MAX_GRID)
		set_meta("grid_size", grid_size)
		_reseed_if_needed()
		_rebuild()
@export var cell_size: float = DEFAULT_CELL:
	set(v):
		cell_size = max(0.1, v)
		set_meta("cell_size", cell_size)
		_rebuild()

# Internal buffers — both mirrored to metadata so they survive save+load.
var _heights: PackedFloat32Array = PackedFloat32Array()
var _surfaces: PackedByteArray = PackedByteArray()

var _mesh_inst: MeshInstance3D = null
var _coll: CollisionShape3D = null


func _ready() -> void:
	add_to_group("terrain_patch")
	collision_layer = 1
	collision_mask = 0
	# Restore from metadata if present (post save+load).
	if has_meta("grid_size"):
		grid_size = int(get_meta("grid_size"))
	if has_meta("cell_size"):
		cell_size = float(get_meta("cell_size"))
	if has_meta("heights"):
		_heights = get_meta("heights")
	if has_meta("surfaces"):
		_surfaces = get_meta("surfaces")
	_reseed_if_needed()
	_rebuild()


# Make sure _heights / _surfaces match grid_size; if not, recreate
# flat. Called whenever grid_size changes or on a fresh patch.
func _reseed_if_needed() -> void:
	var vcount: int = (grid_size + 1) * (grid_size + 1)
	var ccount: int = grid_size * grid_size
	if _heights.size() != vcount:
		_heights = PackedFloat32Array()
		_heights.resize(vcount)
		for i in vcount:
			_heights[i] = 0.0
	if _surfaces.size() != ccount:
		_surfaces = PackedByteArray()
		_surfaces.resize(ccount)
		for i in ccount:
			_surfaces[i] = 0
	set_meta("heights", _heights)
	set_meta("surfaces", _surfaces)


# ---- Mesh build ------------------------------------------------------

func _rebuild() -> void:
	if not is_inside_tree():
		return
	# Drop and recreate child mesh/collision.
	for c in get_children():
		c.queue_free()
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "Mesh"
	_mesh_inst.mesh = _build_mesh()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	# Render from both sides — without this the patch is invisible from
	# below, which makes "facing wrong direction" confusion easy.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh_inst.material_override = mat
	add_child(_mesh_inst)
	_coll = CollisionShape3D.new()
	_coll.name = "Shape"
	var shape := ConcavePolygonShape3D.new()
	shape.data = _build_collision_faces()
	# Two-sided collision: raycasts and falling bodies hit the patch
	# from above OR below. Without this the trimesh is one-sided and
	# bodies plunge through the "wrong" face — and click-selection
	# only registers from the side facing the face winding.
	shape.backface_collision = true
	_coll.shape = shape
	add_child(_coll)
	terrain_changed.emit()


func _build_mesh() -> ArrayMesh:
	var vcount: int = (grid_size + 1) * (grid_size + 1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(vcount)
	normals.resize(vcount)
	colors.resize(vcount)
	# Center the patch on origin: x,z ∈ [-half_extent, +half_extent].
	var half_extent: float = grid_size * cell_size * 0.5
	for z in grid_size + 1:
		for x in grid_size + 1:
			var idx: int = _v_index(x, z)
			var px: float = -half_extent + x * cell_size
			var pz: float = -half_extent + z * cell_size
			var py: float = _heights[idx]
			verts[idx] = Vector3(px, py, pz)
			# Vertex color from neighbouring cells' surface ids — pick
			# the cell to the bottom-right of this vertex (clamped at
			# edges).
			var cx: int = clamp(x, 0, grid_size - 1)
			var cz: int = clamp(z, 0, grid_size - 1)
			var surf_id: int = _surfaces[cz * grid_size + cx]
			colors[idx] = _color_for(surf_id)
	# Indices: two triangles per cell, winding so normals face +Y.
	indices.resize(grid_size * grid_size * 6)
	var k: int = 0
	for z in grid_size:
		for x in grid_size:
			var v00: int = _v_index(x, z)
			var v10: int = _v_index(x + 1, z)
			var v01: int = _v_index(x, z + 1)
			var v11: int = _v_index(x + 1, z + 1)
			indices[k]     = v00
			indices[k + 1] = v01
			indices[k + 2] = v10
			indices[k + 3] = v10
			indices[k + 4] = v01
			indices[k + 5] = v11
			k += 6
	# Compute per-vertex normals (averaged from neighbouring face
	# normals). We do it in one pass.
	for i in vcount:
		normals[i] = Vector3.ZERO
	var tri_count: int = indices.size() / 3
	for t in tri_count:
		var i0: int = indices[t * 3]
		var i1: int = indices[t * 3 + 1]
		var i2: int = indices[t * 3 + 2]
		var n: Vector3 = (verts[i1] - verts[i0]).cross(verts[i2] - verts[i0])
		normals[i0] += n
		normals[i1] += n
		normals[i2] += n
	for i in vcount:
		var nn: Vector3 = normals[i]
		if nn.length_squared() > 0.0:
			normals[i] = nn.normalized()
		else:
			normals[i] = Vector3.UP
	var arrs := []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = verts
	arrs[Mesh.ARRAY_NORMAL] = normals
	arrs[Mesh.ARRAY_COLOR] = colors
	arrs[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	return am


func _build_collision_faces() -> PackedVector3Array:
	# Flat triangle list (3 verts per face) for ConcavePolygonShape3D.
	var faces := PackedVector3Array()
	var half_extent: float = grid_size * cell_size * 0.5
	for z in grid_size:
		for x in grid_size:
			var v00 := Vector3(-half_extent + x * cell_size,
					_heights[_v_index(x, z)],
					-half_extent + z * cell_size)
			var v10 := Vector3(-half_extent + (x + 1) * cell_size,
					_heights[_v_index(x + 1, z)],
					-half_extent + z * cell_size)
			var v01 := Vector3(-half_extent + x * cell_size,
					_heights[_v_index(x, z + 1)],
					-half_extent + (z + 1) * cell_size)
			var v11 := Vector3(-half_extent + (x + 1) * cell_size,
					_heights[_v_index(x + 1, z + 1)],
					-half_extent + (z + 1) * cell_size)
			faces.append(v00); faces.append(v01); faces.append(v10)
			faces.append(v10); faces.append(v01); faces.append(v11)
	return faces


func _v_index(x: int, z: int) -> int:
	return z * (grid_size + 1) + x


func _color_for(surf_id: int) -> Color:
	# Mirrored from editor_materials.gd SURFACE_COLORS.
	match surf_id:
		1: return Color(0.55, 0.40, 0.25, 1)   # path
		2: return Color(0.55, 0.55, 0.58, 1)   # stone
		3: return Color(0.20, 0.55, 0.85, 1)   # water
		4: return Color(0.85, 0.78, 0.55, 1)   # sand
		5: return Color(0.75, 0.90, 1.00, 1)   # ice
		6: return Color(1.00, 0.45, 0.10, 1)   # lava
		_: return Color(0.30, 0.50, 0.26, 1)   # grass default


# ---- Public API for sculpt / paint tools ----------------------------

# World-space → grid vertex coordinate. Returns Vector2i(x, z) (vertex
# coords in [0..grid_size] inclusive), or (-1,-1) if out of bounds.
func world_to_vertex_xz(world_pos: Vector3) -> Vector2i:
	var local: Vector3 = world_pos - global_position
	var half_extent: float = grid_size * cell_size * 0.5
	var fx: float = (local.x + half_extent) / cell_size
	var fz: float = (local.z + half_extent) / cell_size
	if fx < 0 or fz < 0 or fx > grid_size or fz > grid_size:
		return Vector2i(-1, -1)
	return Vector2i(int(round(fx)), int(round(fz)))


# World-space → cell coordinate (cell ∈ [0..grid_size-1]).
func world_to_cell_xz(world_pos: Vector3) -> Vector2i:
	var local: Vector3 = world_pos - global_position
	var half_extent: float = grid_size * cell_size * 0.5
	var fx: float = (local.x + half_extent) / cell_size
	var fz: float = (local.z + half_extent) / cell_size
	if fx < 0 or fz < 0 or fx >= grid_size or fz >= grid_size:
		return Vector2i(-1, -1)
	return Vector2i(int(floor(fx)), int(floor(fz)))


# Grid vertex coord → world position (for cursor preview).
func vertex_to_world(vx: int, vz: int) -> Vector3:
	var half_extent: float = grid_size * cell_size * 0.5
	return global_position + Vector3(-half_extent + vx * cell_size,
			_heights[_v_index(vx, vz)],
			-half_extent + vz * cell_size)


# Pre/post snapshot helpers for the undo stack.
func get_heights() -> PackedFloat32Array:
	return _heights.duplicate()


func set_heights(data: PackedFloat32Array) -> void:
	if data.size() != _heights.size():
		return
	_heights = data.duplicate()
	set_meta("heights", _heights)
	_rebuild()


func get_surfaces() -> PackedByteArray:
	return _surfaces.duplicate()


func set_surfaces(data: PackedByteArray) -> void:
	if data.size() != _surfaces.size():
		return
	_surfaces = data.duplicate()
	set_meta("surfaces", _surfaces)
	_rebuild()


# Sculpt: apply a brush at the given world-space center. mode is
# "raise"/"lower"/"smooth"/"flatten"/"flatten_to". radius_m is in
# meters; strength_per_sec is "units of height per second per full-
# strength tap". dt is the delta time since the last tick (so a held
# LMB ramps continuously).
func sculpt(center_world: Vector3, radius_m: float, strength_per_sec: float,
		dt: float, mode: String) -> void:
	var local: Vector3 = center_world - global_position
	var half_extent: float = grid_size * cell_size * 0.5
	# Bounding box of brush in vertex coords.
	var vmin_x: int = int(floor((local.x - radius_m + half_extent) / cell_size))
	var vmax_x: int = int(ceil((local.x + radius_m + half_extent) / cell_size))
	var vmin_z: int = int(floor((local.z - radius_m + half_extent) / cell_size))
	var vmax_z: int = int(ceil((local.z + radius_m + half_extent) / cell_size))
	vmin_x = clamp(vmin_x, 0, grid_size)
	vmax_x = clamp(vmax_x, 0, grid_size)
	vmin_z = clamp(vmin_z, 0, grid_size)
	vmax_z = clamp(vmax_z, 0, grid_size)
	var r2: float = radius_m * radius_m
	var amount: float = strength_per_sec * dt
	# Flatten_to target = vertex height at brush center.
	var flatten_h: float = 0.0
	if mode == "flatten":
		var cv: Vector2i = world_to_vertex_xz(center_world)
		if cv.x >= 0:
			flatten_h = _heights[_v_index(cv.x, cv.y)]
	# Copy for smooth (read from snapshot, write into _heights).
	var snapshot: PackedFloat32Array = _heights
	if mode == "smooth":
		snapshot = _heights.duplicate()
	for z in range(vmin_z, vmax_z + 1):
		for x in range(vmin_x, vmax_x + 1):
			var px: float = -half_extent + x * cell_size
			var pz: float = -half_extent + z * cell_size
			var d2: float = (px - local.x) * (px - local.x) + (pz - local.z) * (pz - local.z)
			if d2 > r2:
				continue
			var falloff: float = 1.0 - (sqrt(d2) / max(radius_m, 0.0001))
			# Smoothstep for a softer profile.
			falloff = falloff * falloff * (3.0 - 2.0 * falloff)
			var idx: int = _v_index(x, z)
			match mode:
				"raise":
					_heights[idx] += amount * falloff
				"lower":
					_heights[idx] -= amount * falloff
				"flatten":
					_heights[idx] = lerp(_heights[idx], flatten_h, clamp(amount * falloff * 4.0, 0.0, 1.0))
				"smooth":
					var nb: float = snapshot[idx]
					var cnt: int = 1
					if x > 0:
						nb += snapshot[_v_index(x - 1, z)]; cnt += 1
					if x < grid_size:
						nb += snapshot[_v_index(x + 1, z)]; cnt += 1
					if z > 0:
						nb += snapshot[_v_index(x, z - 1)]; cnt += 1
					if z < grid_size:
						nb += snapshot[_v_index(x, z + 1)]; cnt += 1
					var avg: float = nb / float(cnt)
					_heights[idx] = lerp(_heights[idx], avg, clamp(amount * falloff * 4.0, 0.0, 1.0))
	set_meta("heights", _heights)
	_rebuild()


# Paint cells in a radius with the given surface id.
func paint(center_world: Vector3, radius_m: float, surf_id: int) -> void:
	var local: Vector3 = center_world - global_position
	var half_extent: float = grid_size * cell_size * 0.5
	var cmin_x: int = int(floor((local.x - radius_m + half_extent) / cell_size))
	var cmax_x: int = int(ceil((local.x + radius_m + half_extent) / cell_size))
	var cmin_z: int = int(floor((local.z - radius_m + half_extent) / cell_size))
	var cmax_z: int = int(ceil((local.z + radius_m + half_extent) / cell_size))
	cmin_x = clamp(cmin_x, 0, grid_size - 1)
	cmax_x = clamp(cmax_x, 0, grid_size - 1)
	cmin_z = clamp(cmin_z, 0, grid_size - 1)
	cmax_z = clamp(cmax_z, 0, grid_size - 1)
	var r2: float = radius_m * radius_m
	for z in range(cmin_z, cmax_z + 1):
		for x in range(cmin_x, cmax_x + 1):
			var px: float = -half_extent + (x + 0.5) * cell_size
			var pz: float = -half_extent + (z + 0.5) * cell_size
			var d2: float = (px - local.x) * (px - local.x) + (pz - local.z) * (pz - local.z)
			if d2 > r2:
				continue
			_surfaces[z * grid_size + x] = surf_id
	set_meta("surfaces", _surfaces)
	_rebuild()


# Returns the surface id (SURF_*) of the cell directly beneath the
# given world position, or -1 if out of bounds. Future agent uses this
# to drive footsteps / water / damage.
func surface_id_at(world_pos: Vector3) -> int:
	var c: Vector2i = world_to_cell_xz(world_pos)
	if c.x < 0:
		return -1
	return _surfaces[c.y * grid_size + c.x]
