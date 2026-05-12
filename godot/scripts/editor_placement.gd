extends Node

# Helpers for raycasting from the editor camera into the 3D world and
# building palette entries on-the-fly. Used by editor_ui.gd; this is a
# plain helper script (not autoloaded) instantiated by the UI.

const SPAWN_MARKER_SCENE := "res://scenes/spawn_marker.tscn"
const GROUND_PATCH_SCENE := "res://scenes/ground_patch.tscn"
const TERRAIN_PATCH_SCENE := "res://scenes/terrain_patch_edit.tscn"
const WALL_SEGMENT_SCENE := "res://scenes/wall_segment.tscn"
const WATER_VOLUME_SCENE := "res://scenes/water_volume.tscn"
const LOAD_ZONE_SCENE    := "res://scenes/load_zone.tscn"

const PROP_OFFSET_Y: float = 0.0           # most props are ground-aligned


# ---- Raycast --------------------------------------------------------

# Returns {hit, position, normal, collider}. If nothing hit, returns
# {hit=false, position=cam_pos + 5m forward}.
static func raycast_from_mouse(camera: Camera3D, mouse_pos: Vector2) -> Dictionary:
	var out := {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP, "collider": null}
	if camera == null or not is_instance_valid(camera):
		return out
	var space := camera.get_world_3d().direct_space_state
	if space == null:
		return out
	var origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = origin + dir * 500.0
	var params := PhysicsRayQueryParameters3D.create(origin, to)
	params.collide_with_areas = true
	params.collide_with_bodies = true
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		out["position"] = origin + dir * 5.0
		return out
	out["hit"] = true
	out["position"] = hit["position"]
	out["normal"] = hit.get("normal", Vector3.UP)
	out["collider"] = hit.get("collider", null)
	return out


static func snap_to_grid(p: Vector3, step: float) -> Vector3:
	if step <= 0.0:
		return p
	return Vector3(
		round(p.x / step) * step,
		p.y,
		round(p.z / step) * step
	)


# ---- Build palette catalog -----------------------------------------
#
# Each entry: {category, label, kind, scene_path, meta}. `kind` is one
# of "instance" (load + instantiate a .tscn), "primitive" (instantiate
# a primitive scene like ground_patch), "light_dir", "light_omni",
# "spawn", "mesh_placeholder".

static func build_catalog() -> Array:
	var entries: Array = []

	# ---- Geometry tab
	entries.append({"category": "Geometry", "label": "Ground Patch",
			"kind": "primitive", "scene_path": GROUND_PATCH_SCENE,
			"snap": 1.0})
	entries.append({"category": "Geometry", "label": "Terrain Patch",
			"kind": "primitive", "scene_path": TERRAIN_PATCH_SCENE,
			"snap": 2.0})
	entries.append({"category": "Geometry", "label": "Wall Segment",
			"kind": "primitive", "scene_path": WALL_SEGMENT_SCENE,
			"snap": 0.5})
	entries.append({"category": "Geometry", "label": "Stair",
			"kind": "stair", "scene_path": "", "snap": 0.5})
	entries.append({"category": "Geometry", "label": "Water Volume",
			"kind": "primitive", "scene_path": WATER_VOLUME_SCENE,
			"snap": 0.5})
	entries.append({"category": "Geometry", "label": "Ramp",
			"kind": "ramp", "scene_path": "", "snap": 0.5})
	entries.append({"category": "Geometry", "label": "Sun Light",
			"kind": "light_dir", "scene_path": "", "snap": 0.5})
	entries.append({"category": "Geometry", "label": "Point Light",
			"kind": "light_omni", "scene_path": "", "snap": 0.5})

	# ---- Props tab
	var props := [
		["Tree",            "res://scenes/tree_prop.tscn"],
		["Rock",            "res://scenes/rock.tscn"],
		["Bush",            "res://scenes/bush.tscn"],
		["Sign",            "res://scenes/sign_post.tscn"],
		["Torch",           "res://scenes/torch.tscn"],
		["Chest",           "res://scenes/treasure_chest.tscn"],
		["Owl Statue",      "res://scenes/owl_statue.tscn"],
		["Hookshot Target", "res://scenes/hookshot_target.tscn"],
		["Bomb Flower",     "res://scenes/bomb_flower.tscn"],
		["Crystal Switch",  "res://scenes/crystal_switch.tscn"],
		["Pressure Plate",  "res://scenes/pressure_plate.tscn"],
		["Destruct. Wall",  "res://scenes/destructible_wall.tscn"],
		["Door",            "res://scenes/door.tscn"],
		["Triggered Gate",  "res://scenes/triggered_gate.tscn"],
		["Time Gate",       "res://scenes/time_gate.tscn"],
		["Movable Block",   "res://scenes/movable_block.tscn"],
		["NPC",             "res://scenes/npc.tscn"],
	]
	for p in props:
		if ResourceLoader.exists(p[1]):
			entries.append({"category": "Props", "label": p[0],
					"kind": "instance", "scene_path": p[1], "snap": 0.5})

	# ---- Enemies tab — discover all enemy_*.tscn
	var enemies := _discover_enemy_scenes()
	for e in enemies:
		entries.append({"category": "Enemies", "label": e["label"],
				"kind": "instance", "scene_path": e["path"], "snap": 0.5})

	# ---- Triggers tab
	entries.append({"category": "Triggers", "label": "Spawn Marker",
			"kind": "spawn", "scene_path": SPAWN_MARKER_SCENE, "snap": 0.5})
	if ResourceLoader.exists(LOAD_ZONE_SCENE):
		entries.append({"category": "Triggers", "label": "Load Zone",
				"kind": "load_zone", "scene_path": LOAD_ZONE_SCENE, "snap": 0.5})
	if ResourceLoader.exists("res://scenes/boss_arena.tscn"):
		entries.append({"category": "Triggers", "label": "Boss Arena",
				"kind": "instance", "scene_path": "res://scenes/boss_arena.tscn",
				"snap": 0.5})

	# ---- Mesh tab — placeholder for Phase 2 GLB pipeline.
	entries.append({"category": "Mesh", "label": "(drop .glb in assets/meshes)",
			"kind": "mesh_placeholder", "scene_path": "", "snap": 0.5})

	return entries


static func _discover_enemy_scenes() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://scenes")
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.begins_with("enemy_") \
				and name.ends_with(".tscn"):
			var path := "res://scenes/" + name
			var label := name.substr("enemy_".length())
			label = label.substr(0, label.length() - ".tscn".length())
			label = label.replace("_", " ").capitalize()
			out.append({"label": label, "path": path})
		name = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return a["label"] < b["label"])
	return out


# ---- Spawn one entry --------------------------------------------------
#
# Returns the new Node3D parented under `parent`. Position is the raw
# hit point — caller applies offset/snap as needed.

static func spawn_entry(entry: Dictionary, parent: Node) -> Node3D:
	var kind: String = entry.get("kind", "instance")
	var path: String = entry.get("scene_path", "")
	var node: Node3D = null
	match kind:
		"instance", "primitive", "spawn", "load_zone":
			if path == "" or not ResourceLoader.exists(path):
				return null
			var scn: PackedScene = load(path) as PackedScene
			if scn == null:
				return null
			node = scn.instantiate() as Node3D
		"stair":
			node = _make_stair()
		"ramp":
			node = _make_ramp()
		"light_dir":
			var dl := DirectionalLight3D.new()
			dl.name = "DirLight"
			dl.shadow_enabled = true
			node = dl
		"light_omni":
			var ol := OmniLight3D.new()
			ol.name = "OmniLight"
			ol.omni_range = 8.0
			node = ol
		"mesh_placeholder":
			# Phase 2 — leave as null so the palette can show the hint
			# but not actually place anything. Caller treats null as no-op.
			return null
		_:
			return null
	if node == null:
		return null
	parent.add_child(node)
	return node


static func _make_stair() -> Node3D:
	# 5×5×3 procedural stair — six steps of 0.5m rise, 0.83m run.
	var root := StaticBody3D.new()
	root.name = "Stair"
	root.collision_layer = 1
	var steps := 6
	var rise: float = 0.5
	var run_each: float = 5.0 / steps
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.58, 1)
	mat.roughness = 0.85
	for i in steps:
		var bm := BoxMesh.new()
		bm.size = Vector3(5, rise, run_each * (steps - i))
		var mi := MeshInstance3D.new()
		mi.name = "Step%d" % i
		mi.mesh = bm
		mi.material_override = mat
		var z_center: float = -run_each * (steps - i) * 0.5 + (run_each * i)
		mi.position = Vector3(0, rise * (i + 0.5), z_center)
		root.add_child(mi)
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = bm.size
		cs.shape = bs
		cs.position = mi.position
		root.add_child(cs)
	return root


static func _make_ramp() -> Node3D:
	# 10×6 sloped quad with collision (simple sloped box).
	var root := StaticBody3D.new()
	root.name = "Ramp"
	root.collision_layer = 1
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(10, 0.2, 6)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.50, 0.45, 0.38, 1)
	mat.roughness = 0.85
	mi.material_override = mat
	root.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = bm.size
	cs.shape = bs
	root.add_child(cs)
	# Tilt the whole assembly forward 20°.
	root.rotation = Vector3(deg_to_rad(-20), 0, 0)
	return root
