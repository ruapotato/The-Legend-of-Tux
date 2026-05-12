extends CanvasLayer

# Minimal integrated-editor UI. Replaces the previous 1800-line version
# which had brush/wall/hint/topbar/toolbar panels that overlapped each
# other and ate clicks across the viewport.
#
# Design rules (do not break):
#  1. The 3D viewport is the WHOLE WINDOW. No panel covers the centre.
#  2. Only TWO chrome panels exist: bottom palette + right inspector.
#  3. Every chrome panel sets mouse_filter=PASS so empty space lets
#     clicks through; only actual buttons/spinboxes STOP events.
#  4. Picking and placement raycast from screen centre (the crosshair).
#     Mouse cursor is solely for clicking UI widgets.
#  5. Hold RMB → camera fly (handled by editor_camera.gd; we don't
#     intercept). Release RMB → cursor is free for UI clicks.
#
# Subsystems composed (kept from prior version):
#  - editor_palette.gd     bottom palette catalog + 1-9 hotkeys
#  - editor_inspector.gd   right-side property editor
#  - editor_placement.gd   raycast + prefab catalog
#  - editor_undo.gd        Ctrl+Z / Ctrl+Y stack

const EditorPlacementCls = preload("res://scripts/editor_placement.gd")
const EditorPaletteCls   = preload("res://scripts/editor_palette.gd")
const EditorInspectorCls = preload("res://scripts/editor_inspector.gd")
const EditorUndoCls      = preload("res://scripts/editor_undo.gd")
const LevelTemplateCls   = preload("res://scripts/level_template.gd")

const PALETTE_H:   int = 96
const INSPECTOR_W: int = 320
const RETICLE_PX:  int = 10
const STATUS_H:    int = 24

# ---- Layout nodes
var _root: Control          = null
var _palette_panel: PanelContainer = null
var _palette: EditorPaletteCls    = null
var _inspector_panel: PanelContainer = null
var _inspector: EditorInspectorCls   = null
var _status_label: Label    = null
var _hint_label: Label      = null
var _reticle: Control       = null
var _save_dialog: FileDialog = null
var _open_dialog: FileDialog = null
var _new_level_dialog: AcceptDialog = null
var _new_level_input: LineEdit = null
var _new_level_pending_lz: Node = null

# ---- Editor state
var _selected: Node3D = null
var _palette_idx: int = -1
var _catalog: Array = []
var _undo: EditorUndoCls = null

# Pending wall corner (when wall_segment is the palette selection).
var _wall_anchor: Vector3 = Vector3.ZERO
var _wall_has_anchor: bool = false
var _wall_marker: MeshInstance3D = null

# Selection outline ghost.
var _outline: Node3D = null


func _ready() -> void:
	layer = 70
	visible = false
	_undo = EditorUndoCls.new()
	_build_layout()
	_catalog = EditorPlacementCls.build_catalog()
	_palette.set_catalog(_catalog)
	_palette.entry_selected.connect(_on_palette_pick)
	EditorMode.mode_changed.connect(_on_mode_changed)
	EditorMode.dirty_changed.connect(_on_dirty_changed)
	set_process(true)
	_refresh_status()


func _process(_delta: float) -> void:
	if not EditorMode.is_edit:
		return
	_update_outline()
	_update_wall_marker()


# ---------------------------------------------------------------------
# Layout — keep it boringly simple
# ---------------------------------------------------------------------

func _build_layout() -> void:
	# Root never blocks input. Always covers screen for absolute anchoring.
	_root = Control.new()
	_root.name = "EditorRoot"
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_status()
	_build_palette()
	_build_inspector()
	_build_reticle()
	_build_hint()
	_build_dialogs()


func _build_status() -> void:
	# Small label at top-left. Pure read-only — IGNORE clicks.
	_status_label = Label.new()
	_status_label.anchor_left = 0.0
	_status_label.anchor_right = 0.0
	_status_label.offset_left = 8
	_status_label.offset_top = 4
	_status_label.offset_right = 600
	_status_label.offset_bottom = STATUS_H + 4
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color(1, 0.95, 0.55, 1))
	_status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_status_label.add_theme_constant_override("shadow_offset_x", 1)
	_status_label.add_theme_constant_override("shadow_offset_y", 1)
	_root.add_child(_status_label)


func _build_palette() -> void:
	# Bottom strip. PanelContainer is PASS; the EditorPaletteCls children
	# manage their own STOP'd buttons.
	_palette_panel = PanelContainer.new()
	_palette_panel.name = "PalettePanel"
	_palette_panel.anchor_left = 0.0
	_palette_panel.anchor_right = 1.0
	_palette_panel.anchor_top = 1.0
	_palette_panel.anchor_bottom = 1.0
	_palette_panel.offset_top = -PALETTE_H
	_palette_panel.offset_right = -INSPECTOR_W   # leave space for inspector even when empty
	_palette_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_child(_palette_panel)
	# Tinted background so it reads as chrome, not transparent.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.92)
	sb.border_color = Color(0.40, 0.36, 0.20, 1)
	sb.border_width_top = 1
	_palette_panel.add_theme_stylebox_override("panel", sb)

	_palette = EditorPaletteCls.new()
	_palette.anchor_right = 1.0
	_palette.anchor_bottom = 1.0
	_palette.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette_panel.add_child(_palette)


func _build_inspector() -> void:
	_inspector_panel = PanelContainer.new()
	_inspector_panel.name = "InspectorPanel"
	_inspector_panel.anchor_left = 1.0
	_inspector_panel.anchor_right = 1.0
	_inspector_panel.anchor_top = 0.0
	_inspector_panel.anchor_bottom = 1.0
	_inspector_panel.offset_left = -INSPECTOR_W
	_inspector_panel.offset_top = STATUS_H + 8
	_inspector_panel.offset_bottom = -PALETTE_H
	_inspector_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_inspector_panel.visible = false
	_root.add_child(_inspector_panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.92)
	sb.border_color = Color(0.40, 0.36, 0.20, 1)
	sb.border_width_left = 1
	_inspector_panel.add_theme_stylebox_override("panel", sb)

	_inspector = EditorInspectorCls.new()
	_inspector.anchor_right = 1.0
	_inspector.anchor_bottom = 1.0
	_inspector.set_owner_ui(self)
	_inspector_panel.add_child(_inspector)


func _build_reticle() -> void:
	# A tiny crosshair Control centred on screen. IGNORE clicks.
	_reticle = Control.new()
	_reticle.name = "Reticle"
	_reticle.anchor_left = 0.5
	_reticle.anchor_right = 0.5
	_reticle.anchor_top = 0.5
	_reticle.anchor_bottom = 0.5
	_reticle.offset_left = -RETICLE_PX
	_reticle.offset_right = RETICLE_PX
	_reticle.offset_top = -RETICLE_PX
	_reticle.offset_bottom = RETICLE_PX
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.draw.connect(_draw_reticle)
	_root.add_child(_reticle)
	_reticle.queue_redraw()


func _draw_reticle() -> void:
	# 10px crosshair, white with black shadow.
	var c := Vector2(RETICLE_PX, RETICLE_PX)
	var col := Color(1, 1, 1, 0.95)
	var sh  := Color(0, 0, 0, 0.85)
	_reticle.draw_line(c + Vector2(-RETICLE_PX, 0), c + Vector2(RETICLE_PX, 0), sh, 3.0)
	_reticle.draw_line(c + Vector2(0, -RETICLE_PX), c + Vector2(0, RETICLE_PX), sh, 3.0)
	_reticle.draw_line(c + Vector2(-RETICLE_PX, 0), c + Vector2(RETICLE_PX, 0), col, 1.5)
	_reticle.draw_line(c + Vector2(0, -RETICLE_PX), c + Vector2(0, RETICLE_PX), col, 1.5)


func _build_hint() -> void:
	# Bottom-right one-line hint with the essential keys.
	_hint_label = Label.new()
	_hint_label.text = "RMB: fly  •  LMB: place / select  •  Esc: deselect  •  Del: delete  •  Ctrl+S: save  •  Tab: play"
	_hint_label.anchor_left = 0.0
	_hint_label.anchor_right = 1.0
	_hint_label.anchor_top = 1.0
	_hint_label.anchor_bottom = 1.0
	_hint_label.offset_top = -PALETTE_H - 22
	_hint_label.offset_bottom = -PALETTE_H - 2
	_hint_label.offset_right = -INSPECTOR_W - 8
	_hint_label.offset_left = 8
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.85))
	_hint_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_hint_label.add_theme_constant_override("shadow_offset_x", 1)
	_hint_label.add_theme_constant_override("shadow_offset_y", 1)
	_root.add_child(_hint_label)


func _build_dialogs() -> void:
	# Save-As + Open file pickers, lazy-built and tucked under root.
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.add_filter("*.tscn ; Godot Scene")
	_save_dialog.current_dir = "res://scenes"
	_save_dialog.file_selected.connect(_on_save_as_picked)
	_root.add_child(_save_dialog)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_RESOURCES
	_open_dialog.add_filter("*.tscn ; Godot Scene")
	_open_dialog.current_dir = "res://scenes"
	_open_dialog.file_selected.connect(_on_open_picked)
	_root.add_child(_open_dialog)

	_new_level_dialog = AcceptDialog.new()
	_new_level_dialog.title = "New Linked Level"
	_new_level_dialog.dialog_text = "Name for the new level (alphanumeric + underscore):"
	_new_level_dialog.confirmed.connect(_on_new_level_confirmed)
	var vb := VBoxContainer.new()
	_new_level_dialog.add_child(vb)
	_new_level_input = LineEdit.new()
	_new_level_input.custom_minimum_size = Vector2(280, 0)
	vb.add_child(_new_level_input)
	_new_level_dialog.register_text_enter(_new_level_input)
	_root.add_child(_new_level_dialog)


# ---------------------------------------------------------------------
# Mode + status
# ---------------------------------------------------------------------

func _on_mode_changed(is_edit: bool) -> void:
	visible = is_edit
	if not is_edit:
		_clear_selection()
		_clear_wall_anchor()
		_palette_idx = -1
	_refresh_status()


func _on_dirty_changed(_d: bool) -> void:
	_refresh_status()


func _refresh_status() -> void:
	if _status_label == null:
		return
	var sc := get_tree().current_scene
	var name: String = "(no level)"
	if sc and sc.scene_file_path != "":
		name = sc.scene_file_path.get_file().get_basename()
	var dirty := "*" if EditorMode.dirty else ""
	var palette_hint := ""
	if _palette_idx >= 0 and _palette_idx < _catalog.size():
		palette_hint = "  •  brush: " + str(_catalog[_palette_idx].get("label", "?"))
	_status_label.text = "EDIT %s%s%s" % [name, dirty, palette_hint]


# ---------------------------------------------------------------------
# Input — kept in one place for clarity
# ---------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not EditorMode.is_edit:
		return

	# Mouse — only LMB does work; RMB is the camera's job.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _is_cursor_over_chrome(mb.position):
				return    # let the UI handle it
			_on_viewport_click()
			get_viewport().set_input_as_handled()
		return

	# Keyboard.
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return

	# Number keys pick palette slot. Esc cancels.
	if ke.keycode >= KEY_1 and ke.keycode <= KEY_9:
		var slot := ke.keycode - KEY_1
		_palette.activate_slot(slot)
		get_viewport().set_input_as_handled()
		return

	match ke.keycode:
		KEY_ESCAPE:
			if _wall_has_anchor:
				_clear_wall_anchor()
			elif _palette_idx >= 0:
				_palette_idx = -1
				_palette.clear_selection()
				_refresh_status()
			else:
				_clear_selection()
			get_viewport().set_input_as_handled()
		KEY_DELETE, KEY_BACKSPACE:
			_delete_selection()
			get_viewport().set_input_as_handled()
		KEY_F:
			_focus_on_selection()
			get_viewport().set_input_as_handled()
		KEY_S:
			if ke.ctrl_pressed:
				if ke.shift_pressed:
					_save_dialog.popup_centered(Vector2i(800, 500))
				else:
					_save_level()
				get_viewport().set_input_as_handled()
		KEY_O:
			if ke.ctrl_pressed:
				_open_dialog.popup_centered(Vector2i(800, 500))
				get_viewport().set_input_as_handled()
		KEY_Z:
			if ke.ctrl_pressed:
				if ke.shift_pressed:
					_undo.redo(get_tree().current_scene)
				else:
					_undo.undo(get_tree().current_scene)
				get_viewport().set_input_as_handled()
		KEY_Y:
			if ke.ctrl_pressed:
				_undo.redo(get_tree().current_scene)
				get_viewport().set_input_as_handled()


func _is_cursor_over_chrome(pos: Vector2) -> bool:
	# True if the cursor sits over the palette or the visible inspector.
	# Centre crosshair clicks always go through to viewport logic.
	var size := get_viewport().get_visible_rect().size
	# Palette occupies [0..size.x - inspector_w, size.y - palette_h .. size.y]
	var pal_x_max: float = size.x - INSPECTOR_W
	var pal_y_min: float = size.y - PALETTE_H
	if pos.x < pal_x_max and pos.y > pal_y_min:
		return true
	# Inspector occupies [size.x - inspector_w .. size.x, status_top .. palette_top]
	if _inspector_panel and _inspector_panel.visible:
		var ins_x_min: float = size.x - INSPECTOR_W
		if pos.x > ins_x_min and pos.y > STATUS_H and pos.y < size.y - PALETTE_H:
			return true
	return false


# ---------------------------------------------------------------------
# Click handling
# ---------------------------------------------------------------------

func _on_viewport_click() -> void:
	# Always use the centre-screen reticle. Cursor position is irrelevant.
	var cam := _editor_cam()
	if cam == null:
		return
	var hit := EditorPlacementCls.raycast_from_center(cam, 200.0)

	if _palette_idx < 0:
		# Pure pick: select whatever's at the reticle.
		if hit.get("hit", false):
			_select_from_collider(hit.get("collider"))
		else:
			_clear_selection()
		return

	# Palette slot active → place. Special-case wall (two-point).
	var entry: Dictionary = _catalog[_palette_idx]
	var kind: String = entry.get("kind", "")
	var target_pos: Vector3 = hit.get("position", cam.global_position + (-cam.global_transform.basis.z) * 5.0)

	if kind == "wall_segment":
		_place_wall_step(target_pos)
		return

	# Generic prefab/primitive placement.
	var placed: Node3D = EditorMode.get_or_create_placed_container()
	if placed == null:
		return
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, placed)
	if node == null:
		return
	node.global_position = target_pos
	_undo.record_place(node)
	EditorMode.dirty = true
	_select(node)


# ---------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------

func _select(node: Node3D) -> void:
	if _selected == node:
		return
	_clear_selection()
	_selected = node
	_make_outline(node)
	if _inspector_panel:
		_inspector_panel.visible = true
		_inspector.set_target(node)


func _clear_selection() -> void:
	_selected = null
	_clear_outline()
	if _inspector_panel:
		_inspector_panel.visible = false
		_inspector.set_target(null)


func _select_from_collider(collider: Object) -> void:
	if collider == null:
		_clear_selection()
		return
	# Walk up the parent chain to find the gameplay node (Node3D directly
	# under the level root, the placed container, or marked editable).
	var sc := get_tree().current_scene
	var n: Node = collider as Node
	var best: Node3D = null
	while n != null and n != sc:
		if n is Node3D:
			best = n
		if n.get_parent() == sc:
			break
		if n.get_parent() and n.get_parent().name == "Placed":
			break
		n = n.get_parent()
	if best == null:
		_clear_selection()
		return
	if best == EditorMode._editor_camera:
		_clear_selection()
		return
	_select(best)


func _delete_selection() -> void:
	if _selected == null:
		return
	var n := _selected
	_clear_selection()
	_undo.record_delete(n)
	n.queue_free()
	EditorMode.dirty = true


func _focus_on_selection() -> void:
	if _selected == null:
		return
	var cam := _editor_cam()
	if cam == null:
		return
	var target := _selected.global_position
	# Fly to 5m back, 3m up, look at target.
	cam.global_position = target + Vector3(0, 3, 5)
	cam.look_at(target, Vector3.UP)


# ---------------------------------------------------------------------
# Outline (selection visual)
# ---------------------------------------------------------------------

func _make_outline(node: Node3D) -> void:
	_clear_outline()
	if node == null:
		return
	var mesh: MeshInstance3D = _find_mesh(node)
	if mesh == null:
		return
	var ghost := MeshInstance3D.new()
	ghost.mesh = mesh.mesh
	ghost.transform = mesh.global_transform
	ghost.scale = ghost.scale * 1.04
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 0.2, 0.45)
	mat.flags_transparent = true
	mat.flags_unshaded = true
	mat.flags_no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost.material_override = mat
	get_tree().current_scene.add_child(ghost)
	ghost.set_meta("editor_outline", true)
	_outline = ghost


func _update_outline() -> void:
	if _outline == null or _selected == null:
		return
	var mesh: MeshInstance3D = _find_mesh(_selected)
	if mesh:
		_outline.global_transform = mesh.global_transform
		_outline.scale *= 1.04


func _clear_outline() -> void:
	if _outline and is_instance_valid(_outline):
		_outline.queue_free()
	_outline = null


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null


# ---------------------------------------------------------------------
# Wall tool — two-point placement
# ---------------------------------------------------------------------

func _place_wall_step(p: Vector3) -> void:
	if not _wall_has_anchor:
		_wall_anchor = p
		_wall_has_anchor = true
		_show_wall_marker(p)
		return
	# Second click — build the wall.
	var a := _wall_anchor
	var b := p
	var mid := (a + b) * 0.5
	var delta := b - a
	delta.y = 0
	var length: float = max(delta.length(), 0.1)
	var yaw: float = atan2(delta.x, delta.z)

	var entry: Dictionary = _catalog[_palette_idx]
	var placed: Node3D = EditorMode.get_or_create_placed_container()
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, placed)
	if node == null:
		_clear_wall_anchor()
		return
	node.global_position = mid
	node.rotation = Vector3(0, yaw, 0)
	# Scale length along local Z to match the click distance.
	node.scale = Vector3(1.0, 1.0, length / 10.0)
	_undo.record_place(node)
	EditorMode.dirty = true
	_clear_wall_anchor()


func _show_wall_marker(p: Vector3) -> void:
	_clear_wall_anchor_marker()
	var m := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	m.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0.2, 0.2, 1.0)
	mat.flags_unshaded = true
	m.material_override = mat
	m.position = p
	get_tree().current_scene.add_child(m)
	m.set_meta("editor_only", true)
	_wall_marker = m


func _clear_wall_anchor() -> void:
	_wall_has_anchor = false
	_clear_wall_anchor_marker()


func _clear_wall_anchor_marker() -> void:
	if _wall_marker and is_instance_valid(_wall_marker):
		_wall_marker.queue_free()
	_wall_marker = null


func _update_wall_marker() -> void:
	# Marker doesn't move; placed once at the first click point.
	pass


# ---------------------------------------------------------------------
# Save / load
# ---------------------------------------------------------------------

func _save_level() -> void:
	# Strip outline + wall marker so they don't pack into the .tscn.
	_clear_outline()
	_clear_wall_anchor_marker()
	if EditorMode.save_level():
		_refresh_status()


func _on_save_as_picked(path: String) -> void:
	_clear_outline()
	_clear_wall_anchor_marker()
	if EditorMode.save_level_as(path):
		_refresh_status()


func _on_open_picked(path: String) -> void:
	_clear_selection()
	_clear_wall_anchor()
	get_tree().change_scene_to_file(path)


# ---------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------

func _on_palette_pick(catalog_index: int) -> void:
	_palette_idx = catalog_index
	_clear_wall_anchor()
	_refresh_status()


# ---------------------------------------------------------------------
# Linked-level creation (called from inspector via owner_ui)
# ---------------------------------------------------------------------

func request_new_linked_level(load_zone_node: Node) -> void:
	_new_level_pending_lz = load_zone_node
	_new_level_input.text = ""
	_new_level_input.grab_focus.call_deferred()
	_new_level_dialog.popup_centered()


func _on_new_level_confirmed() -> void:
	if _new_level_pending_lz == null:
		return
	var raw: String = _new_level_input.text.strip_edges()
	if raw == "":
		return
	var safe: String = ""
	for c in raw.to_lower():
		var u: int = c.unicode_at(0)
		# Allow a-z, 0-9, underscore.
		if (u >= 97 and u <= 122) or (u >= 48 and u <= 57) or u == 95:
			safe += c
	if safe == "":
		return
	var sc := get_tree().current_scene
	if sc == null:
		return
	var current_id: String = sc.scene_file_path.get_file().get_basename()
	var new_path: String = LevelTemplateCls.create_level(safe, current_id)
	if new_path == "":
		push_warning("EditorUI: failed to create level %s" % safe)
		return
	# Wire current load_zone's target.
	_new_level_pending_lz.set("target_scene", safe)
	if _new_level_pending_lz.has_method("set_target_spawn"):
		_new_level_pending_lz.set_target_spawn("from_" + current_id)
	else:
		_new_level_pending_lz.set("target_spawn", "from_" + current_id)
	EditorMode.dirty = true
	_inspector.set_target(_selected)   # refresh inspector
	_new_level_pending_lz = null


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

func _editor_cam() -> Camera3D:
	# EditorMode caches it. Re-resolve defensively.
	var cam = EditorMode._editor_camera
	if cam and is_instance_valid(cam):
		return cam
	var sc := get_tree().current_scene
	if sc:
		var found := sc.find_child("EditorCamera", true, false)
		if found and found is Camera3D:
			return found
	return null


func get_selected() -> Node3D:
	return _selected


func get_undo() -> EditorUndoCls:
	return _undo
