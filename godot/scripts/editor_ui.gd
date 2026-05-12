extends CanvasLayer

# Top-level editor UI overlay. CanvasLayer at layer 70 (above HUD's 50,
# below pause's 80). Holds:
#   - Status bar (top center)
#   - Palette strip (bottom)
#   - Inspector panel (right)
#   - Minimap (top-right)
#   - Hotkey hint bar (bottom-right)
#
# Owns the click→select / click→place pipeline and the keyboard hotkeys
# (Ctrl+S, Ctrl+O, Ctrl+D, Del, etc.). Defers actual placement logic to
# editor_placement.gd and inspector rendering to editor_inspector.gd.
# Lives only in edit mode — `visible` toggled by EditorMode on flip.

const EditorPlacementCls = preload("res://scripts/editor_placement.gd")
const EditorPaletteCls   = preload("res://scripts/editor_palette.gd")
const EditorInspectorCls = preload("res://scripts/editor_inspector.gd")
const EditorMinimapCls   = preload("res://scripts/editor_minimap.gd")
const LevelTemplateCls   = preload("res://scripts/level_template.gd")

var _status: Label = null
var _palette: Control = null
var _palette_ctrl = null            # EditorPalette instance
var _inspector: Control = null
var _inspector_ctrl = null          # EditorInspector instance
var _minimap: Control = null
var _minimap_ctrl = null
var _hint_bar: Label = null

var _file_dialog: FileDialog = null
var _new_level_dialog: AcceptDialog = null
var _new_level_input: LineEdit = null
var _new_level_pending_lz: Node = null    # the load_zone we're filling

# Selection / tool state.
var _selected: Node3D = null
var _outline: MeshInstance3D = null
enum Tool { NONE, GRAB, ROTATE, SCALE }
var _tool: int = Tool.NONE
var _drag_active: bool = false
var _drag_start_mouse: Vector2 = Vector2.ZERO
var _drag_start_pos: Vector3 = Vector3.ZERO
var _drag_start_rot: Vector3 = Vector3.ZERO
var _drag_start_scale: Vector3 = Vector3.ZERO
var _grid_snap: bool = false

# Catalog & current selection in the palette.
var _catalog: Array = []
var _selected_palette: int = -1


func _ready() -> void:
	layer = 70
	visible = false
	_build_layout()
	_catalog = EditorPlacementCls.build_catalog()
	_palette_ctrl.set_catalog(_catalog)
	EditorMode.mode_changed.connect(_on_mode_changed)
	EditorMode.dirty_changed.connect(_on_dirty_changed)
	visible = EditorMode.is_edit
	_refresh_status()


func _on_mode_changed(is_edit: bool) -> void:
	visible = is_edit
	if not is_edit:
		_clear_selection()
		_tool = Tool.NONE
	_refresh_status()


func _on_dirty_changed(_is_dirty: bool) -> void:
	_refresh_status()


# ---- Layout -----------------------------------------------------------

func _build_layout() -> void:
	# Status bar (top-center).
	var status_panel := PanelContainer.new()
	status_panel.anchor_left = 0.5
	status_panel.anchor_right = 0.5
	status_panel.anchor_top = 0.0
	status_panel.offset_left = -220
	status_panel.offset_right = 220
	status_panel.offset_top = 8
	status_panel.offset_bottom = 40
	add_child(status_panel)
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.text = "EDIT"
	_status.add_theme_font_size_override("font_size", 16)
	status_panel.add_child(_status)

	# Palette strip (bottom).
	_palette = Control.new()
	_palette.anchor_left = 0.0
	_palette.anchor_right = 1.0
	_palette.anchor_bottom = 1.0
	_palette.offset_top = -110
	_palette.offset_bottom = -8
	_palette.offset_left = 8
	_palette.offset_right = -332
	add_child(_palette)
	_palette_ctrl = EditorPaletteCls.new()
	_palette_ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_ctrl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette_ctrl.anchor_right = 1.0
	_palette_ctrl.anchor_bottom = 1.0
	_palette.add_child(_palette_ctrl)
	_palette_ctrl.entry_selected.connect(_on_palette_entry_selected)

	# Inspector (right).
	_inspector = PanelContainer.new()
	_inspector.anchor_top = 0.0
	_inspector.anchor_bottom = 1.0
	_inspector.anchor_left = 1.0
	_inspector.anchor_right = 1.0
	_inspector.offset_left = -320
	_inspector.offset_right = -8
	_inspector.offset_top = 290
	_inspector.offset_bottom = -120
	add_child(_inspector)
	_inspector_ctrl = EditorInspectorCls.new()
	_inspector_ctrl.anchor_right = 1.0
	_inspector_ctrl.anchor_bottom = 1.0
	_inspector_ctrl.set_owner_ui(self)
	_inspector.add_child(_inspector_ctrl)

	# Minimap (top-right).
	_minimap = PanelContainer.new()
	_minimap.anchor_left = 1.0
	_minimap.anchor_right = 1.0
	_minimap.offset_left = -248
	_minimap.offset_right = -8
	_minimap.offset_top = 44
	_minimap.offset_bottom = 284
	add_child(_minimap)
	_minimap_ctrl = EditorMinimapCls.new()
	_minimap_ctrl.anchor_right = 1.0
	_minimap_ctrl.anchor_bottom = 1.0
	_minimap.add_child(_minimap_ctrl)

	# Hotkey hint bar (bottom-right).
	var hint_panel := PanelContainer.new()
	hint_panel.anchor_left = 1.0
	hint_panel.anchor_right = 1.0
	hint_panel.anchor_bottom = 1.0
	hint_panel.offset_left = -320
	hint_panel.offset_right = -8
	hint_panel.offset_top = -110
	hint_panel.offset_bottom = -8
	add_child(hint_panel)
	_hint_bar = Label.new()
	_hint_bar.text = ("WASD fly  Q/E down/up  RMB look  Shift x3\n"
			+ "1-9 palette  Click place/select  Esc deselect\n"
			+ "G grab  R rotate  S scale  Del delete  Ctrl+D dup\n"
			+ "Ctrl+S save  Ctrl+Shift+S save as  Ctrl+O open\n"
			+ "Tab → Play mode (auto-saves)")
	_hint_bar.add_theme_font_size_override("font_size", 11)
	hint_panel.add_child(_hint_bar)

	# File dialogs created lazily (avoids window pop on init).


func _refresh_status() -> void:
	if _status == null:
		return
	var sc := get_tree().current_scene
	var path: String = ""
	var sname: String = ""
	if sc:
		path = sc.scene_file_path
		sname = sc.name
	var badge := "EDIT" if EditorMode.is_edit else "PLAY"
	var dirty_marker := " *" if EditorMode.dirty else ""
	_status.text = "[%s%s] %s — %s" % [badge, dirty_marker, sname, path]


# ---- Input handling ---------------------------------------------------

func _input(event: InputEvent) -> void:
	if not EditorMode.is_edit:
		return
	if event is InputEventKey:
		_handle_key(event as InputEventKey)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)


func _handle_key(ev: InputEventKey) -> void:
	if not ev.pressed or ev.echo:
		return
	# Number keys 1-9 → palette slot.
	if ev.keycode >= KEY_1 and ev.keycode <= KEY_9:
		var idx: int = ev.keycode - KEY_1
		var visible_entries: Array = _palette_ctrl.get_visible_entries()
		if idx < visible_entries.size():
			_palette_ctrl.select_index(_palette_ctrl.scroll_offset + idx)
		get_viewport().set_input_as_handled()
		return
	# Ctrl+S / Ctrl+Shift+S / Ctrl+O / Ctrl+D
	if ev.ctrl_pressed:
		if ev.keycode == KEY_S:
			if ev.shift_pressed:
				_open_save_as_dialog()
			else:
				_save_level()
			get_viewport().set_input_as_handled()
			return
		if ev.keycode == KEY_O:
			_open_load_dialog()
			get_viewport().set_input_as_handled()
			return
		if ev.keycode == KEY_D:
			_duplicate_selected()
			get_viewport().set_input_as_handled()
			return
	# Single keys
	match ev.keycode:
		KEY_ESCAPE:
			_palette_ctrl.select_index(-1)
			_clear_selection()
			get_viewport().set_input_as_handled()
		KEY_G:
			_tool = Tool.GRAB
			get_viewport().set_input_as_handled()
		KEY_R:
			_tool = Tool.ROTATE
			get_viewport().set_input_as_handled()
		KEY_S:
			# S is also free-fly back. Only treat as scale tool when
			# the player has a selection AND no movement key is held.
			if _selected and not _looking_or_moving():
				_tool = Tool.SCALE
				get_viewport().set_input_as_handled()
		KEY_DELETE, KEY_BACKSPACE:
			_delete_selected()
			get_viewport().set_input_as_handled()


func _looking_or_moving() -> bool:
	# Conservative — if the user is holding WASDQE we want S to keep
	# being "fly back".
	return (Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_A)
			or Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_Q)
			or Input.is_key_pressed(KEY_E))


func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	# Suppress UI interactions while the user is RMB-looking (the editor
	# camera owns the cursor in that mode).
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		# Don't grab clicks landing on the UI panels.
		if _mouse_on_ui(mb.position):
			return
		if mb.pressed:
			if _selected_palette >= 0:
				_place_at_mouse(mb.position)
			else:
				if _tool != Tool.NONE and _selected:
					_begin_drag(mb.position)
				else:
					_pick_at_mouse(mb.position)
		else:
			if _drag_active:
				_end_drag()
		get_viewport().set_input_as_handled()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
		_palette_ctrl.scroll(-1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
		_palette_ctrl.scroll(1)


func _handle_mouse_motion(mm: InputEventMouseMotion) -> void:
	if _drag_active and _selected:
		_update_drag(mm.position, mm.relative)


func _mouse_on_ui(pos: Vector2) -> bool:
	# Crude bounding-box test against our panels; cheap and avoids the
	# Control.gui_input glue which would otherwise eat clicks meant for
	# the 3D viewport.
	var panels := [_palette, _inspector, _minimap]
	for p in panels:
		if p == null:
			continue
		var rect := Rect2(p.global_position, p.size)
		if rect.has_point(pos):
			return true
	return false


# ---- Placement --------------------------------------------------------

func _place_at_mouse(mouse_pos: Vector2) -> void:
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	if _selected_palette < 0 or _selected_palette >= _catalog.size():
		return
	var entry: Dictionary = _catalog[_selected_palette]
	if entry.get("kind", "") == "mesh_placeholder":
		return
	var hit: Dictionary = EditorPlacementCls.raycast_from_mouse(cam, mouse_pos)
	var pos: Vector3 = hit["position"]
	# Snap.
	var snap_step: float = float(entry.get("snap", 0.5))
	if _grid_snap:
		pos = EditorPlacementCls.snap_to_grid(pos, snap_step)
	var parent: Node = EditorMode.get_or_create_placed_container()
	if parent == null:
		return
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, parent)
	if node == null:
		return
	node.global_position = pos
	# Spawn markers + load zones get a default config — load zones in
	# particular need to know which level they target, which the user
	# fills in via the inspector.
	if entry.get("kind", "") == "spawn" and "spawn_id" in node:
		node.spawn_id = "spawn_%d" % parent.get_child_count()
	EditorMode.dirty = true
	_select(node)


# ---- Picking / selection ----------------------------------------------

func _pick_at_mouse(mouse_pos: Vector2) -> void:
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var hit: Dictionary = EditorPlacementCls.raycast_from_mouse(cam, mouse_pos)
	if not hit.get("hit", false):
		_clear_selection()
		return
	var collider = hit.get("collider", null)
	if collider == null:
		_clear_selection()
		return
	# Walk up to find the most useful "thing" to select. Heuristic:
	# select the topmost ancestor that's parented under the level root
	# or the Placed container — i.e. the entire palette-placed instance.
	var node: Node3D = _resolve_select_ancestor(collider)
	if node:
		_select(node)


func _resolve_select_ancestor(collider: Node) -> Node3D:
	# Walk upward until we find a node whose parent is the scene root
	# or the Placed container. This avoids selecting a deep child like
	# a CollisionShape3D when the user clicked an NPC.
	var sc: Node = get_tree().current_scene
	var placed: Node = sc.get_node_or_null("Placed") if sc else null
	var cur: Node = collider
	var last: Node3D = collider as Node3D
	while cur and cur.get_parent():
		if cur is Node3D:
			last = cur as Node3D
		var p := cur.get_parent()
		if p == sc or p == placed:
			return cur as Node3D
		cur = p
	return last


func _select(node: Node3D) -> void:
	_clear_selection()
	if node == null:
		return
	_selected = node
	_build_outline(node)
	if _inspector_ctrl:
		_inspector_ctrl.set_target(_selected)


func get_selected() -> Node3D:
	return _selected


func _clear_selection() -> void:
	if _outline and is_instance_valid(_outline):
		_outline.queue_free()
	_outline = null
	_selected = null
	if _inspector_ctrl:
		_inspector_ctrl.set_target(null)


func _build_outline(node: Node3D) -> void:
	# Simple yellow halo — duplicate the first descendant MeshInstance's
	# mesh, scale 1.05, unshaded yellow. Crude but effective.
	var mi: MeshInstance3D = _first_mesh_instance(node)
	if mi == null:
		return
	var ghost := MeshInstance3D.new()
	ghost.mesh = mi.mesh
	ghost.top_level = true
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 0, 0.5)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.material_override = mat
	node.add_child(ghost)
	ghost.global_transform = mi.global_transform
	ghost.scale = mi.global_transform.basis.get_scale() * 1.05
	_outline = ghost


func _first_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var found := _first_mesh_instance(c)
		if found:
			return found
	return null


# ---- Drag / transform tools ------------------------------------------

func _begin_drag(mouse_pos: Vector2) -> void:
	if _selected == null:
		return
	_drag_active = true
	_drag_start_mouse = mouse_pos
	_drag_start_pos = _selected.global_position
	_drag_start_rot = _selected.rotation
	_drag_start_scale = _selected.scale


func _end_drag() -> void:
	_drag_active = false
	if _selected:
		EditorMode.dirty = true
		# Re-position outline.
		if _outline and is_instance_valid(_outline):
			_outline.global_position = _selected.global_position


func _update_drag(mouse_pos: Vector2, rel: Vector2) -> void:
	if _selected == null:
		return
	match _tool:
		Tool.GRAB:
			# Project mouse onto XZ plane at Y of start pos (or Y plane if Shift).
			var cam: Camera3D = _get_editor_camera()
			if cam == null:
				return
			if Input.is_key_pressed(KEY_SHIFT):
				# Y axis: delta from mouse Y in pixels.
				var pixels: float = (_drag_start_mouse.y - mouse_pos.y) * 0.05
				_selected.global_position = Vector3(
					_drag_start_pos.x, _drag_start_pos.y + pixels, _drag_start_pos.z
				)
			else:
				var origin: Vector3 = cam.project_ray_origin(mouse_pos)
				var dir: Vector3 = cam.project_ray_normal(mouse_pos)
				if abs(dir.y) < 0.001:
					return
				var t: float = (_drag_start_pos.y - origin.y) / dir.y
				if t < 0.0:
					return
				var hit_pos: Vector3 = origin + dir * t
				if _grid_snap:
					hit_pos = EditorPlacementCls.snap_to_grid(hit_pos, 0.5)
				_selected.global_position = Vector3(hit_pos.x, _drag_start_pos.y, hit_pos.z)
		Tool.ROTATE:
			var dx: float = (mouse_pos.x - _drag_start_mouse.x) * 0.01
			if Input.is_key_pressed(KEY_SHIFT):
				_selected.rotation = Vector3(_drag_start_rot.x + dx, _drag_start_rot.y, _drag_start_rot.z)
			elif Input.is_key_pressed(KEY_CTRL):
				_selected.rotation = Vector3(_drag_start_rot.x, _drag_start_rot.y, _drag_start_rot.z + dx)
			else:
				_selected.rotation = Vector3(_drag_start_rot.x, _drag_start_rot.y + dx, _drag_start_rot.z)
		Tool.SCALE:
			var dy: float = (_drag_start_mouse.y - mouse_pos.y) * 0.01
			var k: float = max(0.05, 1.0 + dy)
			_selected.scale = _drag_start_scale * k
	if _outline and is_instance_valid(_outline):
		_outline.global_transform = _selected.global_transform


# ---- Hotkey actions ---------------------------------------------------

func _delete_selected() -> void:
	if _selected == null:
		return
	var n := _selected
	_clear_selection()
	n.queue_free()
	EditorMode.dirty = true


func _duplicate_selected() -> void:
	if _selected == null:
		return
	var clone := _selected.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
	var parent := _selected.get_parent()
	if parent == null:
		return
	parent.add_child(clone)
	if clone is Node3D:
		(clone as Node3D).global_position = _selected.global_position + Vector3(1, 0, 1)
		_select(clone as Node3D)
	EditorMode.dirty = true


# Public helper used by inspector's Delete button.
func delete_selected_external() -> void:
	_delete_selected()


# ---- Palette events ---------------------------------------------------

func _on_palette_entry_selected(index: int) -> void:
	_selected_palette = index
	if index >= 0:
		# Clear node-selection when palette is active.
		_clear_selection()
		_tool = Tool.NONE


# ---- File dialogs -----------------------------------------------------

func _ensure_file_dialog() -> void:
	if _file_dialog and is_instance_valid(_file_dialog):
		return
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.filters = PackedStringArray(["*.tscn ; Scenes"])
	_file_dialog.size = Vector2i(720, 520)
	add_child(_file_dialog)


func _open_save_as_dialog() -> void:
	_ensure_file_dialog()
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.current_dir = "res://scenes"
	_file_dialog.title = "Save Level As"
	# Reconnect cleanly.
	if _file_dialog.file_selected.is_connected(_on_save_as_selected):
		_file_dialog.file_selected.disconnect(_on_save_as_selected)
	if _file_dialog.file_selected.is_connected(_on_open_selected):
		_file_dialog.file_selected.disconnect(_on_open_selected)
	_file_dialog.file_selected.connect(_on_save_as_selected)
	_file_dialog.popup_centered()


func _open_load_dialog() -> void:
	_ensure_file_dialog()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.current_dir = "res://scenes"
	_file_dialog.title = "Open Level"
	if _file_dialog.file_selected.is_connected(_on_save_as_selected):
		_file_dialog.file_selected.disconnect(_on_save_as_selected)
	if _file_dialog.file_selected.is_connected(_on_open_selected):
		_file_dialog.file_selected.disconnect(_on_open_selected)
	_file_dialog.file_selected.connect(_on_open_selected)
	_file_dialog.popup_centered()


func _on_save_as_selected(path: String) -> void:
	EditorMode.save_level_as(path)
	_refresh_status()


func _on_open_selected(path: String) -> void:
	get_tree().change_scene_to_file(path)


func _save_level() -> void:
	EditorMode.save_level()
	_refresh_status()


# ---- + NEW LEVEL flow -------------------------------------------------
#
# Called by the inspector when a load_zone is selected. We pop a dialog,
# accept a level id, write the .tscn via LevelTemplate, then wire the
# current load_zone's target_scene to the new level.

func prompt_new_level(load_zone: Node) -> void:
	_new_level_pending_lz = load_zone
	if _new_level_dialog and is_instance_valid(_new_level_dialog):
		_new_level_dialog.popup_centered()
		return
	_new_level_dialog = AcceptDialog.new()
	_new_level_dialog.title = "New Linked Level"
	_new_level_dialog.dialog_text = "Level id (alphanumeric + underscore):"
	_new_level_input = LineEdit.new()
	_new_level_input.placeholder_text = "forge_basement"
	_new_level_dialog.add_child(_new_level_input)
	_new_level_dialog.register_text_enter(_new_level_input)
	_new_level_dialog.confirmed.connect(_on_new_level_confirmed)
	add_child(_new_level_dialog)
	_new_level_dialog.popup_centered(Vector2(360, 140))


func _on_new_level_confirmed() -> void:
	if _new_level_input == null or _new_level_pending_lz == null:
		return
	var level_id: String = _new_level_input.text.strip_edges().to_lower()
	if not LevelTemplateCls.valid_level_id(level_id):
		push_warning("invalid level id: %s" % level_id)
		return
	var current_id: String = _current_level_id()
	var path: String = LevelTemplateCls.create_level(level_id, current_id)
	if path == "":
		push_warning("level template creation failed (already exists?)")
		return
	# Wire the load zone to point at the new level.
	var lz: Node = _new_level_pending_lz
	if lz and is_instance_valid(lz):
		if "target_scene" in lz:
			lz.target_scene = path
		if "target_spawn" in lz:
			lz.target_spawn = "from_%s" % current_id
		EditorMode.dirty = true
		if _inspector_ctrl:
			_inspector_ctrl.set_target(lz)
	_new_level_pending_lz = null


func _current_level_id() -> String:
	var sc := get_tree().current_scene
	if sc == null:
		return "level"
	var p: String = sc.scene_file_path
	if p.begins_with("res://scenes/"):
		p = p.substr("res://scenes/".length())
	if p.ends_with(".tscn"):
		p = p.substr(0, p.length() - ".tscn".length())
	return p


# ---- helpers ---------------------------------------------------------

func _get_editor_camera() -> Camera3D:
	var sc := get_tree().current_scene
	if sc == null:
		return null
	var n := sc.find_child("EditorCamera", true, false)
	return n as Camera3D
