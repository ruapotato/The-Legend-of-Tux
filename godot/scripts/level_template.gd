extends RefCounted
class_name LevelTemplate

# Creates blank-level .tscn files for the editor's +NEW LEVEL workflow.
#
# The new level gets:
#   - Root Node3D titled like "ForgeBasement"
#   - A 30x30 ground patch under it
#   - A `default` spawn marker at origin
#   - A `from_<current>` spawn marker on the north edge (matches the
#     load-zone back-link)
#   - A back-link load_zone on the south edge that returns to current
#   - WorldEnvironment + DirectionalLight3D
#   - Tux + Glim + HUD + free-orbit Camera so play mode works
#
# Returns the absolute res:// path on success, "" on any failure.

const GROUND_PATCH_SCENE := "res://scenes/ground_patch.tscn"
const SPAWN_MARKER_SCENE := "res://scenes/spawn_marker.tscn"
const LOAD_ZONE_SCENE    := "res://scenes/load_zone.tscn"
const TUX_SCENE          := "res://scenes/tux.tscn"
const GLIM_SCENE         := "res://scenes/glim.tscn"
const HUD_SCENE          := "res://scenes/hud.tscn"

const FREE_ORBIT_CAMERA_SCRIPT := "res://scripts/free_orbit_camera.gd"


static func to_title_case(id: String) -> String:
	# "forge_basement" → "ForgeBasement". Used for the root node's name.
	var parts: PackedStringArray = id.split("_", false)
	var out: String = ""
	for p in parts:
		if p.length() == 0:
			continue
		out += p.substr(0, 1).to_upper() + p.substr(1).to_lower()
	return out


static func valid_level_id(id: String) -> bool:
	# Alphanumeric + underscore, must start with a letter, no empty.
	if id.length() == 0:
		return false
	var first := id.substr(0, 1)
	if not first.is_valid_identifier():
		return false
	for i in id.length():
		var ch := id.substr(i, 1)
		if not (ch.is_valid_identifier() or ch == "_" or ch >= "0" and ch <= "9"):
			return false
	return true


# Build the level scene tree in-memory, pack, and save. Returns the
# saved path, or "" on failure. Caller is responsible for any UI.
static func create_level(level_id: String, source_level_id: String = "") -> String:
	if not valid_level_id(level_id):
		return ""
	var out_path: String = "res://scenes/%s.tscn" % level_id
	if ResourceLoader.exists(out_path):
		# Don't clobber an existing scene.
		return ""

	var root := Node3D.new()
	root.name = to_title_case(level_id)
	root.add_to_group("level_root")

	# Environment.
	var env := WorldEnvironment.new()
	env.name = "Environment"
	var environment := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.45, 0.62, 0.86, 1)
	sky_mat.sky_horizon_color = Color(0.86, 0.85, 0.78, 1)
	sky_mat.ground_horizon_color = Color(0.55, 0.46, 0.32, 1)
	sky_mat.ground_bottom_color = Color(0.20, 0.16, 0.10, 1)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color = Color(0.40, 0.50, 0.65, 1)
	environment.ambient_light_energy = 0.5
	env.environment = environment
	root.add_child(env)

	# Sun.
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.transform = Transform3D(
		Basis(Vector3(1, 0, 0), deg_to_rad(-50)) * Basis(Vector3(0, 1, 0), deg_to_rad(35)),
		Vector3(0, 12, 0)
	)
	sun.light_color = Color(1, 0.97, 0.86, 1)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	root.add_child(sun)

	# 30x30 ground patch.
	var gp_scene: PackedScene = load(GROUND_PATCH_SCENE)
	if gp_scene:
		var gp = gp_scene.instantiate()
		gp.name = "GroundPatch"
		root.add_child(gp)
		gp.position = Vector3.ZERO

	# Spawns.
	var spawns := Node3D.new()
	spawns.name = "Spawns"
	root.add_child(spawns)

	var sm_scene: PackedScene = load(SPAWN_MARKER_SCENE)
	if sm_scene:
		var sp_default = sm_scene.instantiate()
		sp_default.name = "default"
		spawns.add_child(sp_default)
		sp_default.position = Vector3(0, 0.5, 0)
		if sp_default.has_method("set"):
			sp_default.spawn_id = "default"

		if source_level_id != "":
			var sp_back = sm_scene.instantiate()
			sp_back.name = "from_%s" % source_level_id
			spawns.add_child(sp_back)
			sp_back.position = Vector3(0, 0.5, -13)     # north edge
			if sp_back.has_method("set"):
				sp_back.spawn_id = "from_%s" % source_level_id

	# Back-link load zone — only when we have a source level to return to.
	if source_level_id != "":
		var lz_scene: PackedScene = load(LOAD_ZONE_SCENE)
		if lz_scene:
			var lz = lz_scene.instantiate()
			lz.name = "BackTo%s" % to_title_case(source_level_id)
			root.add_child(lz)
			lz.position = Vector3(0, 0, 13)             # south edge
			# `target_scene` / `target_spawn` are exports on load_zone.gd.
			if lz.has_method("set"):
				lz.target_scene = "res://scenes/%s.tscn" % source_level_id
				lz.target_spawn = "from_%s" % level_id
				lz.prompt = "Back"

	# Camera (free-orbit).
	var cam_root := Node3D.new()
	cam_root.name = "Camera"
	var cam_script: Script = load(FREE_ORBIT_CAMERA_SCRIPT) as Script
	if cam_script:
		cam_root.set_script(cam_script)
	root.add_child(cam_root)
	var spring := SpringArm3D.new()
	spring.name = "SpringArm"
	spring.spring_length = 4.5
	spring.margin = 0.05
	cam_root.add_child(spring)
	var cam3d := Camera3D.new()
	cam3d.name = "Camera"
	cam3d.fov = 70.0
	spring.add_child(cam3d)

	# Player + Glim.
	var tux_scene: PackedScene = load(TUX_SCENE)
	if tux_scene:
		var tux = tux_scene.instantiate()
		tux.name = "Tux"
		root.add_child(tux)
		tux.position = Vector3(0, 0.5, 0)
		# Wire the camera_path export so play mode works immediately.
		if "camera_path" in tux:
			tux.camera_path = NodePath("../Camera")

	var glim_scene: PackedScene = load(GLIM_SCENE)
	if glim_scene:
		var glim = glim_scene.instantiate()
		glim.name = "Glim"
		root.add_child(glim)
		glim.position = Vector3(-0.6, 1.4, 0)

	# HUD.
	var hud_scene: PackedScene = load(HUD_SCENE)
	if hud_scene:
		var hud = hud_scene.instantiate()
		hud.name = "HUD"
		root.add_child(hud)

	# Set owners so the pack walk pulls everything in.
	_set_owners(root, root)

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		root.queue_free()
		return ""
	err = ResourceSaver.save(packed, out_path)
	root.queue_free()
	if err != OK:
		return ""
	return out_path


static func _set_owners(node: Node, owner: Node) -> void:
	for c in node.get_children():
		if c.owner == null:
			c.owner = owner
		_set_owners(c, owner)
