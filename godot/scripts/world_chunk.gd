extends StaticBody3D

# One square of the procedural world. Split into:
#   generate_data(cc, seed) — pure compute, called from worker threads.
#                             Builds vertex/index/normal/color arrays
#                             plus a list of foliage specs. No scene
#                             tree access.
#   apply_data(cc, data)    — instance method, main thread only.
#                             Turns the precomputed arrays into actual
#                             MeshInstance3D + CollisionShape3D + foliage
#                             child nodes.
#
# Splitting lets WorldStreamer queue heavy compute on WorkerThreadPool
# so chunk loads don't hitch the main thread.

const CHUNK_SIZE: float = 64.0
const VERTS_PER_SIDE: int = 33                       # 32 quads/side
const VERTEX_SPACING: float = CHUNK_SIZE / float(VERTS_PER_SIDE - 1)

var chunk_coord: Vector2i = Vector2i.ZERO

var _mesh_inst: MeshInstance3D
var _coll_shape: CollisionShape3D


# ---- Thread-safe data generation ----------------------------------------

static func generate_data(cc: Vector2i, world_seed: int) -> Dictionary:
	var vcount: int = VERTS_PER_SIDE * VERTS_PER_SIDE
	var verts := PackedVector3Array(); verts.resize(vcount)
	var normals := PackedVector3Array(); normals.resize(vcount)
	var colors := PackedColorArray(); colors.resize(vcount)

	var origin_x: float = cc.x * CHUNK_SIZE
	var origin_z: float = cc.y * CHUNK_SIZE

	for z in VERTS_PER_SIDE:
		for x in VERTS_PER_SIDE:
			var i: int = z * VERTS_PER_SIDE + x
			var wx: float = origin_x + x * VERTEX_SPACING
			var wz: float = origin_z + z * VERTEX_SPACING
			verts[i] = Vector3(x * VERTEX_SPACING,
					WorldGen.height_at(wx, wz),
					z * VERTEX_SPACING)
			colors[i] = WorldGen.biome_color_at(wx, wz)

	# Indices — two triangles per quad. Winding chosen so the
	# cross-product normal points +Y on flat ground (paired with
	# CULL_DISABLED on the material so we're not fighting Godot's
	# winding convention).
	var qcount: int = (VERTS_PER_SIDE - 1) * (VERTS_PER_SIDE - 1)
	var indices := PackedInt32Array(); indices.resize(qcount * 6)
	var k: int = 0
	for z in VERTS_PER_SIDE - 1:
		for x in VERTS_PER_SIDE - 1:
			var v00: int = z * VERTS_PER_SIDE + x
			var v10: int = z * VERTS_PER_SIDE + (x + 1)
			var v01: int = (z + 1) * VERTS_PER_SIDE + x
			var v11: int = (z + 1) * VERTS_PER_SIDE + (x + 1)
			indices[k]     = v00; indices[k + 1] = v01; indices[k + 2] = v10
			indices[k + 3] = v10; indices[k + 4] = v01; indices[k + 5] = v11
			k += 6

	# Smooth normals via accumulated face cross products.
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
		normals[i] = nn.normalized() if nn.length_squared() > 0 else Vector3.UP

	# Collision faces — same triangles laid out flat for ConcavePolygonShape3D.
	var faces := PackedVector3Array(); faces.resize(tri_count * 3)
	for t in tri_count:
		faces[t * 3]     = verts[indices[t * 3]]
		faces[t * 3 + 1] = verts[indices[t * 3 + 1]]
		faces[t * 3 + 2] = verts[indices[t * 3 + 2]]

	var foliage: Array = _gen_foliage_specs(cc, world_seed, origin_x, origin_z)

	return {
		"verts": verts, "normals": normals, "colors": colors,
		"indices": indices, "faces": faces, "foliage": foliage,
	}


static func _gen_foliage_specs(cc: Vector2i, world_seed: int,
		origin_x: float, origin_z: float) -> Array:
	# Rejection sampling: oversample at the densest possible rate
	# (MAX_DENSITY) and accept each candidate with probability
	# local_density / MAX_DENSITY. This naturally handles per-position
	# variation from the density modulator AND biome boundaries
	# without needing to know the chunk's mix upfront.
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ (cc.x * 73856093) ^ (cc.y * 19349663)
	var max_d: float = WorldGen.MAX_DENSITY
	var candidates: int = int(round(max_d * CHUNK_SIZE * CHUNK_SIZE))
	var out: Array = []
	for _i in candidates:
		var lx: float = rng.randf() * CHUNK_SIZE
		var lz: float = rng.randf() * CHUNK_SIZE
		var wx: float = origin_x + lx
		var wz: float = origin_z + lz
		var h: float = WorldGen.height_at(wx, wz)
		if h < WorldGen.SEA_LEVEL + 0.5:
			continue
		var biome: Dictionary = WorldGen.biome_at(wx, wz)
		var base_dens: float = float(biome.get("density", 0.0))
		if base_dens <= 0.0:
			continue
		var modulator: float = WorldGen.density_modulator_at(wx, wz)
		# Cluster factor multiplied in — gives trees the patchy
		# clumping of a real forest instead of uniform random scatter.
		var cluster: float = WorldGen.cluster_factor_at(wx, wz)
		var eff_dens: float = base_dens * modulator * cluster
		if rng.randf() > eff_dens / max_d:
			continue
		var pool: Array = biome.get("foliage", [])
		if pool.is_empty():
			continue
		var path: String = _pick_weighted(pool, rng)
		if path == "":
			continue
		out.append({
			"scene": path,
			"pos": Vector3(lx, h, lz),
			"rot": rng.randf() * TAU,
			"scale": _scale_for(path, rng),
		})
	return out


# Per-instance size variation. Trees scale up to forest size (a base
# tree_prop is ~5m tall; ×2.5 = ~12m), with enough range that no two
# trees look identical. Bushes and rocks get tighter ranges so they
# still read as small.
static func _scale_for(scene_path: String, rng: RandomNumberGenerator) -> float:
	if scene_path.ends_with("tree_prop.tscn"):
		return rng.randf_range(1.4, 2.6)
	if scene_path.ends_with("bush.tscn"):
		return rng.randf_range(0.7, 1.4)
	if scene_path.ends_with("rock.tscn"):
		return rng.randf_range(0.6, 1.7)
	return rng.randf_range(0.9, 1.2)


static func _pick_weighted(pool: Array, rng: RandomNumberGenerator) -> String:
	var total: float = 0.0
	for entry in pool:
		total += float(entry.get("weight", 1.0))
	if total <= 0.0:
		return ""
	var r: float = rng.randf() * total
	for entry in pool:
		r -= float(entry.get("weight", 1.0))
		if r <= 0.0:
			return String(entry.get("scene", ""))
	return String(pool[pool.size() - 1].get("scene", ""))


# ---- Main-thread apply -------------------------------------------------

func apply_data(cc: Vector2i, data: Dictionary) -> void:
	chunk_coord = cc
	name = "Chunk_%d_%d" % [cc.x, cc.y]
	collision_layer = 1
	collision_mask = 0
	position = Vector3(cc.x * CHUNK_SIZE, 0.0, cc.y * CHUNK_SIZE)

	var arrs := []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = data["verts"]
	arrs[Mesh.ARRAY_NORMAL] = data["normals"]
	arrs[Mesh.ARRAY_COLOR]  = data["colors"]
	arrs[Mesh.ARRAY_INDEX]  = data["indices"]
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)

	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "Mesh"
	_mesh_inst.mesh = am
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh_inst.material_override = mat
	add_child(_mesh_inst)

	var shape := ConcavePolygonShape3D.new()
	shape.data = data["faces"]
	shape.backface_collision = true
	_coll_shape = CollisionShape3D.new()
	_coll_shape.name = "Shape"
	_coll_shape.shape = shape
	add_child(_coll_shape)

	for spec in data["foliage"]:
		var scn: PackedScene = WorldGen.get_scene(spec["scene"])
		if scn == null:
			continue
		var inst: Node = scn.instantiate()
		if inst == null:
			continue
		add_child(inst)
		if inst is Node3D:
			var n3d: Node3D = inst
			n3d.position = spec["pos"]
			n3d.rotation.y = spec["rot"]
			var s: float = float(spec.get("scale", 1.0))
			n3d.scale = Vector3(s, s, s)
