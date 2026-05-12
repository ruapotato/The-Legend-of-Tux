extends Node

# Autoload singleton that toggles between PLAY and EDIT modes.
#
# Single source of truth for the integrated editor. Tab key toggles. On
# every flip we walk the scene tree once and pause/resume gameplay
# subsystems (player physics, enemies, load zones, pickups, HUD) and
# swap the active camera (free-fly editor camera vs. orbit camera).
#
# Other systems listen to `mode_changed(is_edit)` so they can react —
# the HUD hides, the player stops processing, the editor UI overlay
# appears, etc. We also fire ourselves on first entry so the wired-up
# listeners get a consistent initial state.
#
# Dirty tracking: editor scripts set `dirty = true` when they mutate the
# scene tree. The UI title shows "EDIT *" when dirty; Ctrl+S clears it.
# Auto-save on Tab-to-Play: if dirty when leaving edit mode, save first.

signal mode_changed(is_edit: bool)
signal dirty_changed(is_dirty: bool)

const EDITOR_CAMERA_SCENE := "res://scenes/editor_camera.tscn"
const EDITOR_UI_SCENE     := "res://scenes/editor_ui.tscn"

var is_edit: bool = false
# Set externally (e.g. by main_menu.gd) to ask EditorMode to flip into
# edit on the next scene-ready cycle. One-shot.
var _pending_edit_on_load: bool = false
var dirty: bool = false:
	set(v):
		if dirty == v:
			return
		dirty = v
		dirty_changed.emit(v)

# Cached references re-resolved on each scene change (since the scene
# tree is rebuilt on change_scene_to_file).
var _editor_camera: Camera3D = null
var _editor_ui: CanvasLayer = null
var _ephemeral_spawn: Node3D = null

# Toggles for whether we should be active in the current scene at all.
# Main menu, intro cutscene, credits, etc. don't have a level root —
# we skip wiring there.
var _scene_supports_editor: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().tree_changed.connect(_on_tree_changed)
	# Defer the initial sweep so any scene we boot directly into (level_00,
	# combat_arena, etc.) has finished _ready before we touch it.
	call_deferred("_on_scene_ready")


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if ke.keycode == KEY_TAB:
		if not _scene_supports_editor:
			return
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	set_mode(not is_edit)


func set_mode(edit: bool) -> void:
	if edit == is_edit:
		return
	# Auto-save dirty levels before playtest.
	if is_edit and not edit and dirty:
		_save_current_level()
	is_edit = edit
	_apply_mode()
	mode_changed.emit(is_edit)


func _on_tree_changed() -> void:
	# `tree_changed` fires *very* often AND can be raised before this
	# node is inside the tree (during autoload init). Guard both.
	if not is_inside_tree():
		return
	var tree := get_tree()
	if tree == null:
		return
	var sc := tree.current_scene
	if sc == _last_scene:
		return
	_last_scene = sc
	# Defer one frame so the new scene's _ready can finish.
	call_deferred("_on_scene_ready")


var _last_scene: Node = null


func _on_scene_ready() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		_scene_supports_editor = false
		_editor_camera = null
		_editor_ui = null
		return
	# Heuristic: only enable the editor on scenes that have a Tux player
	# (i.e. proper levels). Skips main menu, credits, intro, world map.
	_scene_supports_editor = sc.find_child("Tux", true, false) != null \
			or sc.is_in_group("level_root")
	if not _scene_supports_editor:
		_editor_camera = null
		_editor_ui = null
		return
	# Reset to play-mode on every fresh scene load so a save+reload from
	# inside the editor lands the player in play mode (the spec is "the
	# level IS the .tscn" — the saved tree describes a playable world).
	if is_edit:
		is_edit = false
		mode_changed.emit(is_edit)
	_ensure_editor_camera()
	_ensure_editor_ui()
	# Honor a deferred "open this level in edit mode" request from the
	# main menu's Level Editor button.
	if _pending_edit_on_load:
		_pending_edit_on_load = false
		is_edit = true
		mode_changed.emit(is_edit)
	_apply_mode()


func _ensure_editor_camera() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	if _editor_camera and is_instance_valid(_editor_camera):
		return
	# Look for an existing one (e.g. spawned by a previous toggle).
	var existing := sc.find_child("EditorCamera", true, false)
	if existing and existing is Camera3D:
		_editor_camera = existing as Camera3D
		return
	# Instantiate from scene.
	var scn: PackedScene = load(EDITOR_CAMERA_SCENE) as PackedScene
	if scn == null:
		push_warning("EditorMode: cannot load %s" % EDITOR_CAMERA_SCENE)
		return
	var cam = scn.instantiate()
	cam.name = "EditorCamera"
	sc.add_child(cam)
	cam.owner = null     # don't pack into level on save
	_editor_camera = cam as Camera3D


func _ensure_editor_ui() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	if _editor_ui and is_instance_valid(_editor_ui):
		return
	var existing := sc.find_child("EditorUI", true, false)
	if existing and existing is CanvasLayer:
		_editor_ui = existing as CanvasLayer
		return
	var scn: PackedScene = load(EDITOR_UI_SCENE) as PackedScene
	if scn == null:
		push_warning("EditorMode: cannot load %s" % EDITOR_UI_SCENE)
		return
	var ui = scn.instantiate()
	ui.name = "EditorUI"
	sc.add_child(ui)
	ui.owner = null
	_editor_ui = ui as CanvasLayer


func _apply_mode() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return

	# Player.
	var players := get_tree().get_nodes_in_group("player")
	for p in players:
		if p is Node3D:
			(p as Node3D).visible = not is_edit
		if p is Node:
			(p as Node).process_mode = (
				Node.PROCESS_MODE_DISABLED if is_edit else Node.PROCESS_MODE_INHERIT
			)

	# Enemies + bosses.
	for grp in ["enemy", "boss"]:
		for n in get_tree().get_nodes_in_group(grp):
			if n is Node:
				(n as Node).process_mode = (
					Node.PROCESS_MODE_DISABLED if is_edit else Node.PROCESS_MODE_INHERIT
				)

	# Load zones + pickups (Area3D groups).
	for grp in ["load_zone", "pickup"]:
		for n in get_tree().get_nodes_in_group(grp):
			if n is Area3D:
				(n as Area3D).monitoring = not is_edit

	# Also catch load_zone scripts that aren't in the group: any Area3D
	# whose script is load_zone.gd (most scenes attach the script
	# directly without explicit add_to_group).
	_toggle_load_zones_by_script(sc, not is_edit)

	# HUD.
	for hud in _find_huds(sc):
		hud.visible = not is_edit

	# Editor UI.
	if _editor_ui and is_instance_valid(_editor_ui):
		_editor_ui.visible = is_edit

	# Camera priority.
	_set_camera_priority()

	# Spawn-marker visibility — hidden in play, visible in edit.
	_toggle_spawn_marker_visibility()

	# Editor-only visual aids on load_zones.
	_toggle_load_zone_visuals()

	# When entering edit mode, drop the editor camera somewhere useful
	# (~8m up, looking down) so the user has an overview. Only do this
	# on first entry per scene; subsequent toggles preserve camera pose.
	if is_edit and _editor_camera and is_instance_valid(_editor_camera):
		if _editor_camera.has_meta("_positioned"):
			pass
		else:
			_editor_camera.set_meta("_positioned", true)
			_editor_camera.position = Vector3(0, 8, 8)
			_editor_camera.rotation = Vector3(deg_to_rad(-30), 0, 0)
		# Editor camera's process is gated on is_edit too.
	if _editor_camera and is_instance_valid(_editor_camera):
		_editor_camera.set_process(is_edit)
		_editor_camera.set_process_input(is_edit)
		_editor_camera.set_process_unhandled_input(is_edit)
		_editor_camera.visible = is_edit


func _toggle_load_zones_by_script(root: Node, enabled: bool) -> void:
	# Catch every Area3D whose attached script's resource path ends in
	# `load_zone.gd` — that's the load-zone behaviour regardless of
	# group membership.
	for n in _walk(root):
		if not (n is Area3D):
			continue
		var s: Script = n.get_script() as Script
		if s == null:
			continue
		var p: String = s.resource_path
		if p.ends_with("load_zone.gd"):
			(n as Area3D).monitoring = enabled


func _toggle_spawn_marker_visibility() -> void:
	# Spawn markers (group "spawn_marker") are visible in edit, hidden
	# in play. Authored as small green spheres for visibility.
	for n in get_tree().get_nodes_in_group("spawn_marker"):
		if n is Node3D:
			(n as Node3D).visible = is_edit


func _toggle_load_zone_visuals() -> void:
	# Some load zones author a child MeshInstance3D for visualization.
	# We show those in edit, hide in play (handled directly by load_zone.gd
	# usually, but we want the editor view to always show them).
	for n in get_tree().get_nodes_in_group("load_zone"):
		if not (n is Node3D):
			continue
		for c in (n as Node3D).get_children():
			if c is MeshInstance3D:
				(c as MeshInstance3D).visible = is_edit
	# Same for script-attached load zones.
	var sc := get_tree().current_scene
	if sc == null:
		return
	for n in _walk(sc):
		if not (n is Area3D):
			continue
		var s: Script = n.get_script() as Script
		if s == null:
			continue
		if s.resource_path.ends_with("load_zone.gd"):
			for c in (n as Node3D).get_children():
				if c is MeshInstance3D:
					(c as MeshInstance3D).visible = is_edit


func _set_camera_priority() -> void:
	# Make the editor camera "current" in edit mode; in play, demote it
	# so the orbit camera takes back over.
	if _editor_camera and is_instance_valid(_editor_camera):
		_editor_camera.current = is_edit
	if is_edit:
		# Demote every OTHER Camera3D so nothing fights for current.
		for n in _walk_cameras():
			if n == _editor_camera:
				continue
			(n as Camera3D).current = false
	else:
		# Find the orbit camera (sibling Camera3D under a free_orbit script).
		var sc := get_tree().current_scene
		if sc == null:
			return
		# Common shape: $Camera/SpringArm/Camera (3D).
		var orbit := sc.find_child("Camera", true, false)
		if orbit and orbit is Node3D:
			var cam3d := orbit.get_node_or_null("SpringArm/Camera")
			if cam3d and cam3d is Camera3D:
				(cam3d as Camera3D).current = true


func _walk_cameras() -> Array:
	var out: Array = []
	var sc := get_tree().current_scene
	if sc == null:
		return out
	for n in _walk(sc):
		if n is Camera3D:
			out.append(n)
	return out


func _find_huds(root: Node) -> Array:
	# Treat any CanvasLayer named "HUD" as the HUD (matches the convention
	# in combat_arena.tscn / built dungeons).
	var out: Array = []
	for n in _walk(root):
		if n is CanvasLayer and n.name == "HUD":
			out.append(n)
	return out


func _walk(root: Node) -> Array:
	# Iterative tree walk that yields every node beneath root (inclusive).
	# Cheap — we never call this faster than once per mode flip.
	var out: Array = [root]
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out


# ---- Save / load helpers (called by editor UI) -------------------------

func get_level_root() -> Node:
	# The level root is the current scene root. Editor UI uses this to
	# pack/save and as the parent for the "Placed" container.
	return get_tree().current_scene


func get_or_create_placed_container() -> Node3D:
	# Returns the auto-created `Placed` child of the level root. New
	# editor-placed objects get parented here so the level's handcrafted
	# nodes stay isolated from machine-placed ones (the spec calls this
	# out explicitly — "this isolates editor placements from any
	# handcrafted parts").
	var sc := get_tree().current_scene
	if sc == null:
		return null
	var existing := sc.get_node_or_null("Placed")
	if existing and existing is Node3D:
		return existing as Node3D
	var p := Node3D.new()
	p.name = "Placed"
	sc.add_child(p)
	p.owner = sc
	return p


func _save_current_level() -> bool:
	var sc := get_tree().current_scene
	if sc == null or sc.scene_file_path == "":
		return false
	# Strip the editor-only nodes before packing so saved .tscns boot
	# straight into play mode without the editor cruft.
	var stripped: Array = _strip_editor_nodes_for_save(sc)
	# Re-parent placed objects' owner to the scene root so they survive
	# the pack (PackedScene.pack only keeps nodes whose .owner is the
	# packed root or a descendant of it).
	_reparent_owners_to_scene(sc)
	var packed := PackedScene.new()
	var err := packed.pack(sc)
	# Restore stripped nodes after pack so the editor session continues.
	for entry in stripped:
		entry["parent"].add_child(entry["node"])
	if err != OK:
		push_warning("EditorMode: pack failed (%s)" % err)
		return false
	err = ResourceSaver.save(packed, sc.scene_file_path)
	if err != OK:
		push_warning("EditorMode: save failed (%s)" % err)
		return false
	dirty = false
	return true


func save_level() -> bool:
	return _save_current_level()


func save_level_as(new_path: String) -> bool:
	var sc := get_tree().current_scene
	if sc == null:
		return false
	var stripped: Array = _strip_editor_nodes_for_save(sc)
	_reparent_owners_to_scene(sc)
	var packed := PackedScene.new()
	var err := packed.pack(sc)
	for entry in stripped:
		entry["parent"].add_child(entry["node"])
	if err != OK:
		return false
	err = ResourceSaver.save(packed, new_path)
	if err != OK:
		return false
	sc.scene_file_path = new_path
	dirty = false
	return true


func _strip_editor_nodes_for_save(sc: Node) -> Array:
	# Remove editor-only siblings from the tree before packing, then
	# return a list so the caller can re-attach them after the pack
	# completes. Doing this avoids dirtying the user's edit session.
	var out: Array = []
	for name in ["EditorCamera", "EditorUI"]:
		var n := sc.get_node_or_null(name)
		if n:
			out.append({"parent": sc, "node": n})
			sc.remove_child(n)
	# Strip ephemeral test-from-camera spawn.
	if _ephemeral_spawn and is_instance_valid(_ephemeral_spawn) \
			and _ephemeral_spawn.is_inside_tree():
		out.append({"parent": _ephemeral_spawn.get_parent(), "node": _ephemeral_spawn})
		_ephemeral_spawn.get_parent().remove_child(_ephemeral_spawn)
	return out


func _reparent_owners_to_scene(sc: Node) -> void:
	# Recursively set every node's owner to the scene root so they're
	# included when PackedScene.pack walks the tree. Editor placements
	# need this — instantiated scenes don't carry owners by default.
	for n in _walk(sc):
		if n == sc:
			continue
		if n.owner == null:
			n.owner = sc


# ---- Test-from-camera --------------------------------------------------

func _get_camera_xz_ground(cam: Camera3D) -> Vector3:
	# Raycast straight down from the editor camera position to find the
	# ground; returns hit.y + 0.5 if found, else cam.position.y.
	var sc := get_tree().current_scene
	if sc == null:
		return cam.global_position
	var world := cam.get_world_3d()
	if world == null:
		return cam.global_position
	var space := world.direct_space_state
	var from: Vector3 = cam.global_position
	var to: Vector3 = from + Vector3.DOWN * 200.0
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = 1     # world layer
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return Vector3(from.x, 0.5, from.z)
	var p: Vector3 = hit["position"]
	return Vector3(p.x, p.y + 0.5, p.z)


func prep_test_from_camera() -> void:
	# Called by the editor UI before flipping to play mode. Creates an
	# ephemeral spawn marker at the editor-camera's XZ position with
	# Y = ground + 0.5 so Tux lands cleanly on the surface, then asks
	# GameState to spawn there on the next scene-ready cycle.
	if _editor_camera == null or not is_instance_valid(_editor_camera):
		return
	var sc := get_tree().current_scene
	if sc == null:
		return
	# Look for an existing spawn within 2m so the user can iterate on a
	# specific marker (e.g. "from_north") without overriding it.
	var cam_xz: Vector3 = _editor_camera.global_position
	var existing: Node3D = _nearest_spawn_marker(sc, cam_xz)
	var spawn_id: String = ""
	if existing:
		spawn_id = String(existing.get_meta("spawn_id", existing.name))
	else:
		spawn_id = "from_editor_camera"
		var pos: Vector3 = _get_camera_xz_ground(_editor_camera)
		_ephemeral_spawn = _make_ephemeral_spawn(spawn_id, pos)
		var spawns := sc.get_node_or_null("Spawns")
		if spawns == null:
			spawns = Node3D.new()
			spawns.name = "Spawns"
			sc.add_child(spawns)
		spawns.add_child(_ephemeral_spawn)
		_ephemeral_spawn.global_position = pos
	GameState.next_spawn_id = spawn_id


func _nearest_spawn_marker(root: Node, xz: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d: float = 2.0     # 2m threshold per spec
	for n in get_tree().get_nodes_in_group("spawn_marker"):
		if not (n is Node3D):
			continue
		var n3d: Node3D = n
		var d: float = Vector2(n3d.global_position.x - xz.x,
				n3d.global_position.z - xz.z).length()
		if d < best_d:
			best_d = d
			best = n3d
	return best


func _make_ephemeral_spawn(spawn_id: String, pos: Vector3) -> Node3D:
	var m := Marker3D.new()
	m.name = spawn_id
	m.set_meta("spawn_id", spawn_id)
	m.add_to_group("spawn_marker")
	m.global_position = pos
	return m


func remove_ephemeral_spawn() -> void:
	# Cleared on return to Edit so we don't accumulate stale markers.
	if _ephemeral_spawn and is_instance_valid(_ephemeral_spawn):
		var p := _ephemeral_spawn.get_parent()
		if p:
			p.remove_child(_ephemeral_spawn)
		_ephemeral_spawn.queue_free()
		_ephemeral_spawn = null
