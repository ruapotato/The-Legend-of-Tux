extends Node

# Survival-style placement mode driven by the Builder's Hammer. Autoload
# so any script (tux_player gate, world_disc reinstantiation, debug
# console) can read `BuildMode.active` without juggling node refs. When
# active:
#
#   * a translucent ghost of the currently-selected piece is parented
#     under the WorldDisc root and snapped to a Valheim-style EDGE
#     SOCKET on a nearby placed piece (walls attach to a foundation
#     edge, roofs sit on a wall top, etc.). Falls back to a flat ground
#     snap a few metres in front of the player when no socket is in
#     range.
#   * The ghost tints GREEN when the placement is valid (snap target
#     acquired AND cost affordable AND no piece already there) and RED
#     when it isn't.
#   * 1 / 2 / 3 select the foundation / wall / roof slot directly,
#     mouse-wheel cycles, E still cycles for back-compat — the same key
#     normally opens dialog / pickup prompts, so we mark it handled in
#     _input so interactables don't double-fire.
#   * R rotates the ghost yaw by 90° (only when ground-snapping; socket
#     snaps choose the yaw for you).
#   * LMB (attack) places the piece if the placement is valid and Tux
#     can afford the cost; appends `{piece_id, pos, yaw}` to
#     GameState.placed_pieces, and refreshes the ghost in place ready
#     for the next plop.
#   * RMB (shield) or F again exits the mode (tux_player's item_use F
#     handler routes the toggle here — see _read_inputs).
#
# A small CanvasLayer hotbar appears bottom-center while the mode is
# active, showing the three slots, their cost, and a ✓/✗ for whether
# the player can currently afford them.
#
# Tolerant of running headless: every reference is guarded with
# is_instance_valid so the autoload doesn't crash a check-only parse or
# a scripted unit test that never builds a scene tree.

const PIECES: Array[Dictionary] = [
	{
		"id": "foundation",
		"scene": "res://scenes/build_foundation.tscn",
		"cost": 2,
		"label": "F",
	},
	{
		"id": "wall",
		"scene": "res://scenes/build_wall.tscn",
		"cost": 2,
		"label": "W",
	},
	{
		"id": "roof",
		"scene": "res://scenes/build_roof.tscn",
		"cost": 2,
		"label": "R",
	},
]

const GROUND_SNAP: float = 2.0
const PLACE_FORWARD: float = 3.0
const SOCKET_RANGE: float = 3.0
const OVERLAP_EPS: float = 0.05
const COST_RESOURCE: String = "wood"

# Foundation: 2 m x 2 m floor, top at y = 0.4 m. Wall: 2 m wide x 2.5 m
# tall, top at y = 2.5 m. Numbers must stay in sync with the .tscn
# pieces — duplicated here so the autoload doesn't need to peek at the
# meshes at runtime.
const FOUNDATION_TOP_Y: float = 0.4
const FOUNDATION_HALF: float = 1.0
const WALL_TOP_Y: float = 2.5

# Socket schema. For each placed-piece id, we enumerate the local-space
# sockets it exposes. Each socket entry is:
#   {
#     "id":     short string for debug,
#     "accepts": Array[String] of piece ids that can plug into it,
#     "pos":    Vector3 local offset from the piece origin,
#     "yaw":    additional yaw (radians) applied to the placed piece,
#   }
# A "wall" placed onto a foundation edge stands with its centre at the
# edge (x = ±1 or z = ±1) and is rotated to face outward — its 0.2 m-
# thick plane lying along the matching axis.
const SOCKETS: Dictionary = {
	"foundation": [
		# N/S/E/W edge sockets for walls. Yaw orients the wall's flat
		# face along the foundation's edge.
		{"id": "edge_n", "accepts": ["wall"],
			"pos": Vector3(0.0, FOUNDATION_TOP_Y, -FOUNDATION_HALF), "yaw": 0.0},
		{"id": "edge_s", "accepts": ["wall"],
			"pos": Vector3(0.0, FOUNDATION_TOP_Y, FOUNDATION_HALF), "yaw": PI},
		{"id": "edge_e", "accepts": ["wall"],
			"pos": Vector3(FOUNDATION_HALF, FOUNDATION_TOP_Y, 0.0), "yaw": PI * 0.5},
		{"id": "edge_w", "accepts": ["wall"],
			"pos": Vector3(-FOUNDATION_HALF, FOUNDATION_TOP_Y, 0.0), "yaw": -PI * 0.5},
		# Top-centre: stack another foundation (a 2nd story floor).
		{"id": "top", "accepts": ["foundation"],
			"pos": Vector3(0.0, FOUNDATION_TOP_Y, 0.0), "yaw": 0.0},
		# Side sockets: place an adjacent foundation to extend the floor.
		{"id": "side_n", "accepts": ["foundation"],
			"pos": Vector3(0.0, 0.0, -FOUNDATION_HALF * 2.0), "yaw": 0.0},
		{"id": "side_s", "accepts": ["foundation"],
			"pos": Vector3(0.0, 0.0, FOUNDATION_HALF * 2.0), "yaw": 0.0},
		{"id": "side_e", "accepts": ["foundation"],
			"pos": Vector3(FOUNDATION_HALF * 2.0, 0.0, 0.0), "yaw": 0.0},
		{"id": "side_w", "accepts": ["foundation"],
			"pos": Vector3(-FOUNDATION_HALF * 2.0, 0.0, 0.0), "yaw": 0.0},
	],
	"wall": [
		# Stack another wall on top — same XY, shifted up by full wall
		# height. Sockets at the same position with different `accepts`
		# coexist fine: snap algorithm picks whichever matches the
		# currently-selected piece.
		{"id": "top_wall", "accepts": ["wall"],
			"pos": Vector3(0.0, WALL_TOP_Y, 0.0), "yaw": 0.0},
		# Roof socket: rests on the wall top, centred.
		{"id": "top_roof", "accepts": ["roof"],
			"pos": Vector3(0.0, WALL_TOP_Y, 0.0), "yaw": 0.0},
	],
	# Roof tiles need to chain horizontally to cover a multi-square
	# floorplan. Mirror the foundation's 4 SIDE sockets but at roof's
	# own Y so the next slab plants on the same plane.
	"roof": [
		{"id": "side_n", "accepts": ["roof"],
			"pos": Vector3(0.0, 0.0, -FOUNDATION_HALF * 2.0), "yaw": 0.0},
		{"id": "side_s", "accepts": ["roof"],
			"pos": Vector3(0.0, 0.0, FOUNDATION_HALF * 2.0), "yaw": 0.0},
		{"id": "side_e", "accepts": ["roof"],
			"pos": Vector3(FOUNDATION_HALF * 2.0, 0.0, 0.0), "yaw": 0.0},
		{"id": "side_w", "accepts": ["roof"],
			"pos": Vector3(-FOUNDATION_HALF * 2.0, 0.0, 0.0), "yaw": 0.0},
	],
}

signal mode_changed(active: bool)
signal piece_changed(piece_id: String)

var active: bool = false
var _piece_index: int = 0
var _player: Node3D = null
var _ghost: Node3D = null
var _ghost_yaw: float = 0.0
# Whether the current ghost position is valid (snap target acquired or
# open ground) AND affordable. Drives the green/red tint.
var _ghost_valid: bool = false
# Cached PackedScenes so the runtime hot path doesn't hit ResourceLoader
# on every refresh. Filled lazily on first use.
var _scene_cache: Dictionary = {}
# Hotbar CanvasLayer rebuilt every entry; nulled on exit.
var _hotbar: CanvasLayer = null
var _hotbar_slots: Array[Control] = []


func _ready() -> void:
	# Autoload runs before any scene; we'll process every frame regardless
	# but the per-tick work is gated on `active`. set_process_input keeps
	# E/R reachable; we mark the events handled so interactables don't
	# also fire on the same press.
	set_process(true)
	set_process_input(true)


func _process(_delta: float) -> void:
	if not active:
		return
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		# Player went away (scene change mid-build, multiplayer drop).
		# Drop the mode silently rather than crash.
		_exit()
		return
	_refresh_ghost()
	# Polling for the bind keys here — _input would also work but the
	# attack/shield paths use the same just-pressed checks tux_player
	# uses, so colocating keeps the flow obvious.
	if Input.is_action_just_pressed("attack"):
		_try_place()
	elif Input.is_action_just_pressed("shield"):
		_exit()


func _input(event: InputEvent) -> void:
	if not active:
		return
	# Cycle current piece. Interact would normally open the workbench /
	# pickup the rock you're standing on — suppress it via set_input_as_handled
	# so the player isn't accidentally crafting while wall-spamming.
	if event.is_action_pressed("interact"):
		_cycle_piece(1)
		get_viewport().set_input_as_handled()
		return
	# Mouse-wheel cycles the hotbar. Mark handled so the camera spring-arm
	# zoom (which also listens for the wheel) doesn't fight us.
	if event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle_piece(-1)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle_piece(1)
			get_viewport().set_input_as_handled()
			return
	# Direct-select 1 / 2 / 3. Also R rotates ghost 90° (only meaningful
	# in ground-snap mode; socket snaps override yaw).
	if event is InputEventKey and event.pressed and not event.echo:
		var ek: InputEventKey = event
		match ek.keycode:
			KEY_1:
				_select_piece(0)
				get_viewport().set_input_as_handled()
			KEY_2:
				_select_piece(1)
				get_viewport().set_input_as_handled()
			KEY_3:
				_select_piece(2)
				get_viewport().set_input_as_handled()
			KEY_R:
				_ghost_yaw = wrapf(_ghost_yaw + PI * 0.5, 0.0, TAU)
				get_viewport().set_input_as_handled()


# ---- Public API --------------------------------------------------------

# Toggle the mode for `player`. Called from tux_player when the player
# presses item_use with active_b_item == "hammer", and again to leave.
func toggle(player: Node3D) -> void:
	if active:
		_exit()
	else:
		_enter(player)


func current_piece() -> Dictionary:
	if _piece_index < 0 or _piece_index >= PIECES.size():
		return {}
	return PIECES[_piece_index]


# ---- Entry / exit ------------------------------------------------------

func _enter(player: Node3D) -> void:
	if player == null or not is_instance_valid(player):
		return
	_player = player
	_ghost_yaw = 0.0
	active = true
	_spawn_ghost()
	_build_hotbar()
	mode_changed.emit(true)
	piece_changed.emit(String(current_piece().get("id", "")))
	# Terminal-corner narration: entering build mode reads as `mkdir -p`,
	# matching the lore convention that Tux's actions surface as shell
	# commands in the corner.
	_push_terminal_cmd("mkdir -p ./build")


func _exit() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	if _hotbar != null and is_instance_valid(_hotbar):
		_hotbar.queue_free()
	_hotbar = null
	_hotbar_slots.clear()
	_player = null
	active = false
	mode_changed.emit(false)
	_push_terminal_cmd("cd ..")


# ---- Ghost piece -------------------------------------------------------

func _spawn_ghost() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var scn: PackedScene = _scene_for_piece(current_piece())
	if scn == null:
		return
	var inst: Node = scn.instantiate()
	if inst == null:
		return
	_ghost = inst as Node3D
	if _ghost == null:
		inst.queue_free()
		return
	# Tint everything semi-transparent so the ghost reads as "preview".
	# Walk every MeshInstance3D in the subtree — pieces only have one
	# child mesh today but the loop keeps it future-proof if we add
	# pre-decorated variants.
	_apply_ghost_material(_ghost)
	# Strip the collision so a player standing on the ghost doesn't get
	# shoved as the ghost teleports each tick.
	for n in _ghost.get_children():
		if n is CollisionShape3D:
			(n as CollisionShape3D).disabled = true
	var parent: Node = _placement_parent()
	if parent == null:
		_ghost.queue_free()
		_ghost = null
		return
	parent.add_child(_ghost)


# Iterate the ghost's mesh nodes and override the material with a
# tinted unshaded transparent copy. Cached on the mesh's meta so the
# colour swap (`_set_ghost_tint`) doesn't reallocate per frame.
func _apply_ghost_material(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			var ghost_mat := StandardMaterial3D.new()
			ghost_mat.albedo_color = Color(0.5, 0.95, 0.5, 0.45)
			ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			ghost_mat.emission_enabled = true
			ghost_mat.emission = Color(0.5, 0.95, 0.5)
			ghost_mat.emission_energy_multiplier = 0.4
			mi.material_override = ghost_mat
			mi.set_meta("_ghost_mat", ghost_mat)
		# Recurse for completeness — single-level today, but defensive.
		_apply_ghost_material(child)


# Update the colour of the ghost's cached material(s) in place. Cheap —
# pokes albedo + emission without allocating a new material.
func _set_ghost_tint(root: Node, col: Color) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			var mat: StandardMaterial3D = mi.get_meta("_ghost_mat") as StandardMaterial3D
			if mat != null:
				mat.albedo_color = Color(col.r, col.g, col.b, 0.45)
				mat.emission = Color(col.r, col.g, col.b)
		_set_ghost_tint(child, col)


func _refresh_ghost() -> void:
	if _ghost == null or not is_instance_valid(_ghost):
		return
	var snap: Dictionary = _compute_ghost_snap()
	_ghost.global_transform = snap["xform"]
	_ghost_valid = bool(snap["valid"])
	# Cost gate folds into validity feedback — if you can't afford it the
	# ghost goes red even if the geometry is fine.
	if _ghost_valid:
		var cost: int = int(current_piece().get("cost", 2))
		if GameState != null and int(GameState.resources.get(COST_RESOURCE, 0)) < cost:
			_ghost_valid = false
	var col := Color(0.4, 1.0, 0.4) if _ghost_valid else Color(1.0, 0.35, 0.35)
	_set_ghost_tint(_ghost, col)
	_refresh_hotbar_affordability()


# Compute the snapped transform for the current ghost, plus a validity
# flag. Order of preference:
#   1. Edge/top socket on a nearby placed piece that accepts the current
#      piece type.
#   2. Ground snap on the 2m grid in front of the player.
# `valid` is false if no socket is found AND the would-be ground spot
# overlaps an existing piece.
func _compute_ghost_snap() -> Dictionary:
	var origin: Vector3 = Vector3.ZERO
	var yaw: float = _ghost_yaw
	var valid: bool = true
	var snapped: bool = false
	if is_instance_valid(_player):
		var fwd: Vector3 = -_player.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() < 0.001:
			fwd = Vector3(0, 0, -1)
		fwd = fwd.normalized()
		var probe: Vector3 = _player.global_position + fwd * PLACE_FORWARD
		# Look for a socket within SOCKET_RANGE of probe accepting this piece.
		var hit: Dictionary = _nearest_socket_for(current_piece(), probe)
		if not hit.is_empty():
			origin = hit["pos"]
			yaw = hit["yaw"]
			snapped = true
		else:
			# Ground snap fallback.
			var gy: float = _player.global_position.y
			var wgen: Node = get_node_or_null("/root/WorldGen")
			if wgen != null and wgen.has_method("height_at"):
				gy = float(wgen.call("height_at", probe.x, probe.z))
			origin = Vector3(
				round(probe.x / GROUND_SNAP) * GROUND_SNAP,
				gy,
				round(probe.z / GROUND_SNAP) * GROUND_SNAP
			)
			# Refuse to stack ground-snapped pieces on top of an existing
			# piece (within OVERLAP_EPS). Sockets are how you legitimately
			# build on existing pieces.
			if _has_piece_at(origin):
				valid = false
	var basis: Basis = Basis(Vector3.UP, yaw)
	return {
		"xform": Transform3D(basis, origin),
		"valid": valid,
		"snapped": snapped,
		"yaw": yaw,
	}


# Scan placed-piece nodes (group "build_piece") for any whose socket
# table offers a socket accepting `piece` within SOCKET_RANGE of probe.
# Returns the closest matching socket's world transform info as
# {pos, yaw, host}. Empty dict on miss.
func _nearest_socket_for(piece: Dictionary, probe: Vector3) -> Dictionary:
	var want_id: String = String(piece.get("id", ""))
	if want_id == "":
		return {}
	var tree: SceneTree = get_tree()
	if tree == null:
		return {}
	var best: Dictionary = {}
	var best_d2: float = SOCKET_RANGE * SOCKET_RANGE
	for n in tree.get_nodes_in_group("build_piece"):
		if not (n is Node3D):
			continue
		var host: Node3D = n
		if host == _ghost:
			continue
		var host_id: String = String(host.get_meta("piece_id", ""))
		var sockets: Variant = SOCKETS.get(host_id, [])
		if typeof(sockets) != TYPE_ARRAY:
			continue
		var host_x: Transform3D = host.global_transform
		for s in (sockets as Array):
			if typeof(s) != TYPE_DICTIONARY:
				continue
			var accepts: Variant = s.get("accepts", [])
			if typeof(accepts) != TYPE_ARRAY or (accepts as Array).find(want_id) == -1:
				continue
			var local_pos: Vector3 = s.get("pos", Vector3.ZERO)
			var local_yaw: float = float(s.get("yaw", 0.0))
			var world_pos: Vector3 = host_x * local_pos
			var d2: float = world_pos.distance_squared_to(probe)
			if d2 >= best_d2:
				continue
			# Don't snap to a socket whose target slot is already
			# occupied by another placed piece (avoids the ghost
			# colour-flickering between green and red when two walls
			# share the same edge).
			if _has_piece_at(world_pos):
				continue
			best_d2 = d2
			# Yaw: host's yaw plus socket-local yaw.
			var host_yaw: float = host.rotation.y
			best = {
				"pos": world_pos,
				"yaw": host_yaw + local_yaw,
				"host": host,
				"socket": String(s.get("id", "")),
			}
	return best


# True iff some placed piece's origin is within OVERLAP_EPS of `pos`.
# Used both for ground-snap overlap rejection and socket occupancy.
func _has_piece_at(pos: Vector3) -> bool:
	var tree: SceneTree = get_tree()
	if tree == null:
		return false
	var eps2: float = OVERLAP_EPS * OVERLAP_EPS
	for n in tree.get_nodes_in_group("build_piece"):
		if not (n is Node3D):
			continue
		var host: Node3D = n
		if host == _ghost:
			continue
		if host.global_position.distance_squared_to(pos) < eps2:
			return true
	return false


# The WorldDisc root (or whatever the current scene root is) hosts the
# placed pieces so they save/load with the world. Falls back to the
# current scene root if the level isn't WorldDisc — keeps the autoload
# usable in editor/test scenes where the level root is named otherwise.
func _placement_parent() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var root: Node = tree.current_scene
	if root == null:
		return null
	# Prefer a node in the "level_root" group (world_disc.tscn tags itself
	# this way) so a more deeply-nested hierarchy still finds the right
	# parent.
	for n in tree.get_nodes_in_group("level_root"):
		if n is Node:
			return n
	return root


# ---- Cycling -----------------------------------------------------------

func _cycle_piece(delta: int) -> void:
	if PIECES.is_empty():
		return
	_piece_index = (_piece_index + delta) % PIECES.size()
	if _piece_index < 0:
		_piece_index += PIECES.size()
	_after_piece_change()


func _select_piece(idx: int) -> void:
	if idx < 0 or idx >= PIECES.size():
		return
	if idx == _piece_index:
		return
	_piece_index = idx
	_after_piece_change()


# Common tail for cycle + direct-select: respawn the ghost, refresh the
# hotbar highlight, fire the signal.
func _after_piece_change() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_spawn_ghost()
	_refresh_hotbar_highlight()
	piece_changed.emit(String(current_piece().get("id", "")))


# ---- Placement ---------------------------------------------------------

func _try_place() -> void:
	if not is_instance_valid(_player):
		return
	var piece: Dictionary = current_piece()
	if piece.is_empty():
		return
	# Validation first — we compute the same snap _process used and only
	# commit if it's still valid. This way the player isn't charged for
	# an attempt the ghost just rejected as red.
	var snap: Dictionary = _compute_ghost_snap()
	if not bool(snap.get("valid", false)):
		var sb_inv: Node = get_node_or_null("/root/SoundBank")
		if sb_inv != null and sb_inv.has_method("play_2d"):
			sb_inv.call("play_2d", "build_fail")
		return
	var cost: int = int(piece.get("cost", 2))
	if GameState == null:
		return
	if not GameState.consume_resource(COST_RESOURCE, cost):
		# Soft feedback. SoundBank silent-fallbacks if "build_fail" isn't
		# registered so this stays safe in headless test runs.
		var sb: Node = get_node_or_null("/root/SoundBank")
		if sb != null and sb.has_method("play_2d"):
			sb.call("play_2d", "build_fail")
		return
	var xform: Transform3D = snap["xform"]
	var yaw: float = float(snap.get("yaw", _ghost_yaw))
	instantiate_placed(String(piece.get("id", "")), xform.origin, yaw)
	# Append to the per-playthrough placement list. Vector3 is not JSON-
	# serialisable directly so we store it as a dict — same shape the
	# world_disc reloader expects.
	GameState.placed_pieces.append({
		"piece_id": String(piece.get("id", "")),
		"pos": {"x": xform.origin.x, "y": xform.origin.y, "z": xform.origin.z},
		"yaw": yaw,
	})
	print("[build_mode] placed %s @ (%.1f, %.1f, %.1f) yaw=%.2f  total=%d"
			% [String(piece.get("id", "")), xform.origin.x, xform.origin.y,
					xform.origin.z, yaw, GameState.placed_pieces.size()])
	var sb2: Node = get_node_or_null("/root/SoundBank")
	if sb2 != null and sb2.has_method("play_3d"):
		sb2.call("play_3d", "hammer_strike", xform.origin)
	_refresh_hotbar_affordability()


# Real (non-ghost) instantiation. Used by both the live place path AND
# the world_disc reloader on scene _ready, so the spawn rules stay in
# one spot.
#
# Note on transform handling: we set `inst.transform` BEFORE add_child
# (so the very first frame of the piece's life is at the requested
# pose — important when called from world_disc._ready, where deferred
# transform writes would race against the WorldStreamer's chunk pump).
# Because both the placement parent (WorldDisc / level_root) and any
# fall-back current_scene root sit at the world origin, a local
# transform here matches the intended global. After add_child we
# additionally set `global_transform` to be defensive against future
# reparenting under a non-origin host.
func instantiate_placed(piece_id: String, pos: Vector3, yaw: float,
		parent_override: Node = null) -> Node3D:
	var piece: Dictionary = _piece_by_id(piece_id)
	if piece.is_empty():
		return null
	var scn: PackedScene = _scene_for_piece(piece)
	if scn == null:
		return null
	var inst: Node3D = scn.instantiate() as Node3D
	if inst == null:
		return null
	var parent: Node = parent_override if parent_override != null else _placement_parent()
	if parent == null:
		inst.queue_free()
		return null
	# Stamp the piece id for socket-snap lookups (works for both freshly
	# placed pieces and reload-restored ones).
	inst.set_meta("piece_id", piece_id)
	var xform := Transform3D(Basis(Vector3.UP, yaw), pos)
	inst.transform = xform
	parent.add_child(inst)
	# Re-apply as global once parented so a non-origin parent (theoretical
	# future case) still lands the piece where the saved data says.
	inst.global_transform = xform
	return inst


func _piece_by_id(piece_id: String) -> Dictionary:
	for p in PIECES:
		if String(p.get("id", "")) == piece_id:
			return p
	return {}


func _scene_for_piece(piece: Dictionary) -> PackedScene:
	var path: String = String(piece.get("scene", ""))
	if path == "":
		return null
	if _scene_cache.has(path):
		return _scene_cache[path] as PackedScene
	var scn: PackedScene = load(path) as PackedScene
	if scn != null:
		_scene_cache[path] = scn
	return scn


func _push_terminal_cmd(text: String) -> void:
	var tl: Node = get_node_or_null("/root/TerminalLog")
	if tl != null and tl.has_method("cmd"):
		tl.call("cmd", text)


# ---- Hotbar UI ---------------------------------------------------------
#
# Bottom-center CanvasLayer with one ColorRect-per-slot, a letter icon,
# the cost, and a ✓ / ✗ for affordability. Built procedurally — no
# external assets — and torn down on exit. The whole thing is purely
# visual; input is captured in _input above.

const _SLOT_SIZE := Vector2(72.0, 84.0)
const _SLOT_GAP := 8.0


func _build_hotbar() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var root: Node = tree.current_scene
	if root == null:
		return
	_hotbar = CanvasLayer.new()
	_hotbar.layer = 90
	_hotbar.name = "BuildHotbar"
	root.add_child(_hotbar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(_SLOT_GAP))
	row.anchor_left = 0.5
	row.anchor_right = 0.5
	row.anchor_top = 1.0
	row.anchor_bottom = 1.0
	# Center the row horizontally, anchor to the bottom with a margin.
	var total_w: float = float(PIECES.size()) * _SLOT_SIZE.x \
			+ float(PIECES.size() - 1) * _SLOT_GAP
	row.offset_left = -total_w * 0.5
	row.offset_right = total_w * 0.5
	row.offset_top = -_SLOT_SIZE.y - 24.0
	row.offset_bottom = -24.0
	_hotbar.add_child(row)
	_hotbar_slots.clear()
	for i in range(PIECES.size()):
		var slot := _make_hotbar_slot(i)
		row.add_child(slot)
		_hotbar_slots.append(slot)
	_refresh_hotbar_highlight()
	_refresh_hotbar_affordability()


# Build one slot Control: outer panel + key label + procedural icon +
# cost row. Each slot has children named so _refresh_*  can find them
# without having to rebuild every frame.
func _make_hotbar_slot(idx: int) -> Control:
	var piece: Dictionary = PIECES[idx]
	var panel := PanelContainer.new()
	panel.custom_minimum_size = _SLOT_SIZE
	panel.name = "slot_%d" % idx

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.10, 0.14, 0.85)
	bg.name = "bg"
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	panel.add_child(bg)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	panel.add_child(vb)

	# Number label (1/2/3).
	var key_lbl := Label.new()
	key_lbl.text = str(idx + 1)
	key_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_lbl.add_theme_font_size_override("font_size", 12)
	key_lbl.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	vb.add_child(key_lbl)

	# Icon: big letter on a coloured rounded square. Pure procedural.
	var icon_holder := CenterContainer.new()
	icon_holder.custom_minimum_size = Vector2(0, 36)
	vb.add_child(icon_holder)
	var icon := ColorRect.new()
	icon.color = _icon_colour_for(String(piece.get("id", "")))
	icon.custom_minimum_size = Vector2(34, 34)
	icon_holder.add_child(icon)
	var letter := Label.new()
	letter.text = String(piece.get("label", "?"))
	letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	letter.anchor_right = 1.0
	letter.anchor_bottom = 1.0
	letter.add_theme_font_size_override("font_size", 22)
	letter.add_theme_color_override("font_color", Color(1, 1, 1))
	icon.add_child(letter)

	# Cost row + affordability glyph.
	var cost_lbl := Label.new()
	cost_lbl.name = "cost"
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost_lbl.add_theme_font_size_override("font_size", 12)
	vb.add_child(cost_lbl)
	return panel


# Per-piece icon background colour. Mirrors the in-world piece tint
# (foundation = warm wood, wall = darker wood, roof = darker still).
func _icon_colour_for(piece_id: String) -> Color:
	match piece_id:
		"foundation": return Color(0.46, 0.31, 0.18)
		"wall":       return Color(0.42, 0.28, 0.16)
		"roof":       return Color(0.38, 0.25, 0.15)
	return Color(0.5, 0.5, 0.5)


# Tint the selected slot's bg a bright frame; dim the others.
func _refresh_hotbar_highlight() -> void:
	for i in range(_hotbar_slots.size()):
		var slot: Control = _hotbar_slots[i]
		if slot == null:
			continue
		var bg: ColorRect = slot.get_node_or_null("bg") as ColorRect
		if bg == null:
			continue
		if i == _piece_index:
			bg.color = Color(0.20, 0.32, 0.50, 0.95)
		else:
			bg.color = Color(0.08, 0.10, 0.14, 0.85)


# Update each slot's cost row with the current ✓/✗.
func _refresh_hotbar_affordability() -> void:
	var have: int = 0
	if GameState != null:
		have = int(GameState.resources.get(COST_RESOURCE, 0))
	for i in range(_hotbar_slots.size()):
		var slot: Control = _hotbar_slots[i]
		if slot == null:
			continue
		var lbl: Label = slot.get_node_or_null("VBoxContainer/cost") as Label
		# VBoxContainer is auto-named; fall back to a deep search if
		# Godot picked a different name.
		if lbl == null:
			for c in slot.get_children():
				if c is VBoxContainer:
					var inner: Node = (c as VBoxContainer).get_node_or_null("cost")
					if inner is Label:
						lbl = inner
						break
		if lbl == null:
			continue
		var cost: int = int(PIECES[i].get("cost", 2))
		var ok: bool = have >= cost
		var tick: String = "OK" if ok else "X"
		lbl.text = "%d wood %s" % [cost, tick]
		lbl.add_theme_color_override("font_color",
				Color(0.55, 1.0, 0.55) if ok else Color(1.0, 0.45, 0.45))
