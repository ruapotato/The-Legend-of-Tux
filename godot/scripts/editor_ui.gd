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
const STATUS_H:    int = 24

# Set to true to dump every editor decision to stdout + an on-screen
# overlay. Flip to false once the persistent bugs are nailed down.
const DEBUG: bool = true
const DEBUG_MAX: int = 30

# ---- Layout nodes
var _root: Control          = null
var _palette_panel: PanelContainer = null
var _palette: EditorPaletteCls    = null
var _inspector_panel: PanelContainer = null
var _inspector: EditorInspectorCls   = null
var _status_label: Label    = null
var _hint_label: Label      = null
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

# Placement preview ghost (shown at the reticle when a palette slot is active).
var _preview: Node3D = null
var _preview_kind: String = ""

# When the user has the Terrain Mesh palette slot active, every LMB
# click drops a point onto this mesh instead of placing a new mesh
# each time. Cleared on Esc, palette deselect, or after the user
# explicitly re-picks the palette slot.
var _active_terrain_mesh: Node3D = null

# Debug overlay state.
var _debug_label: Label = null
var _debug_log: Array = []

# Grid snap toggle (G). When on, click-placement snaps to the entry's
# `snap` value (or 1.0). Nudges use the same step.
var _snap_enabled: bool = false


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
	# Godot 4 auto-nulls typed Node references when the target is freed,
	# so `_selected` becomes null after undo's queue_free — NOT "non-null
	# but invalid". Detect orphan outlines via the outline existing while
	# the selection has gone away.
	if _outline and (_selected == null or not is_instance_valid(_selected)):
		_dlog("orphan outline detected (sel=%s), clearing" % _dbg_sel_name())
		_selected = null
		_clear_outline()
		if _inspector_panel:
			_inspector_panel.visible = false
			_inspector.set_target(null)
	_update_outline()
	_update_wall_marker()
	_update_preview()


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
	_build_hint()
	_build_dialogs()
	_build_debug_overlay()


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


func _build_hint() -> void:
	# Bottom-right one-line hint with the essential keys.
	_hint_label = Label.new()
	_hint_label.text = "RMB: fly  •  MMB: teleport to spot  •  LMB: pick/place  •  P: drop point AT CAMERA  •  Wheel (on terrain): sculpt  •  Arrows/PgUp/PgDn: nudge  •  R: rotate  •  G: snap  •  Ctrl+D: dup  •  Ctrl+Z/Y: undo/redo  •  Del: delete  •  Tab: play"
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


func _build_debug_overlay() -> void:
	if not DEBUG:
		return
	_debug_label = Label.new()
	_debug_label.name = "DebugLog"
	_debug_label.anchor_left = 0.0
	_debug_label.anchor_right = 0.0
	_debug_label.anchor_top = 0.0
	_debug_label.anchor_bottom = 1.0
	_debug_label.offset_left = 8
	_debug_label.offset_top = STATUS_H + 16
	_debug_label.offset_right = 700
	_debug_label.offset_bottom = -PALETTE_H - 30
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_label.add_theme_font_size_override("font_size", 11)
	_debug_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.65, 1))
	_debug_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	_debug_label.text = "[debug log]"
	_root.add_child(_debug_label)


func _dlog(msg: String) -> void:
	if not DEBUG:
		return
	var line: String = "%5d  %s" % [Engine.get_process_frames() % 100000, msg]
	_debug_log.append(line)
	if _debug_log.size() > DEBUG_MAX:
		_debug_log.pop_front()
	print("[EDITOR] " + line)
	if _debug_label:
		_debug_label.text = "STATE  sel=%s  pal=%d  act_mesh=%s  undo=%d/%d\n%s" % [
			_dbg_sel_name(),
			_palette_idx,
			_dbg_active_mesh_name(),
			_undo.done.size() if _undo else -1,
			_undo.undone.size() if _undo else -1,
			"\n".join(_debug_log),
		]


func _dbg_sel_name() -> String:
	if _selected and is_instance_valid(_selected):
		return _selected.name
	return "none"


func _dbg_active_mesh_name() -> String:
	if _active_terrain_mesh and is_instance_valid(_active_terrain_mesh):
		return _active_terrain_mesh.name
	return "none"


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
		_clear_preview()
		_active_terrain_mesh = null
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
	var snap_hint := "  •  SNAP" if _snap_enabled else ""
	_status_label.text = "EDIT %s%s%s%s" % [name, dirty, palette_hint, snap_hint]


# ---------------------------------------------------------------------
# Input — kept in one place for clarity
# ---------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Global Ctrl+* shortcuts — run in _input so a focused LineEdit /
	# SpinBox in the inspector can't swallow Ctrl+Z and stall the undo
	# system. Other shortcuts stay in _unhandled_input.
	if not EditorMode.is_edit:
		return
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if ke.ctrl_pressed:
		_dlog("_input Ctrl+key keycode=%d Z=%d Y=%d S=%d shift=%s" % [
			ke.keycode, KEY_Z, KEY_Y, KEY_S, str(ke.shift_pressed)])
	if not ke.ctrl_pressed:
		return
	match ke.keycode:
		KEY_Z:
			_dlog("Ctrl+Z via _input  stack=%d" % _undo.done.size())
			if ke.shift_pressed:
				var ok := _undo.redo(get_tree().current_scene)
				_dlog("  redo returned %s, stack now %d" % [str(ok), _undo.done.size()])
			else:
				var ok := _undo.undo(get_tree().current_scene)
				_dlog("  undo returned %s, stack now %d" % [str(ok), _undo.done.size()])
			get_viewport().set_input_as_handled()
		KEY_Y:
			_dlog("Ctrl+Y via _input")
			_undo.redo(get_tree().current_scene)
			get_viewport().set_input_as_handled()
		KEY_S:
			_dlog("Ctrl+S via _input")
			if ke.shift_pressed:
				_save_dialog.popup_centered(Vector2i(800, 500))
			else:
				_save_level()
			get_viewport().set_input_as_handled()
		KEY_O:
			_open_dialog.popup_centered(Vector2i(800, 500))
			get_viewport().set_input_as_handled()
		KEY_D:
			if _selected:
				_duplicate_selection()
				get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not EditorMode.is_edit:
		return

	# Mouse — only LMB does work; RMB is the camera's job.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if _is_cursor_over_chrome(mb.position):
				return    # let the UI handle it
			_on_viewport_click(mb.position)
			get_viewport().set_input_as_handled()
			return
		# Wheel raises/lowers terrain at the reticle. Only consumed when
		# the reticle actually hits a terrain_patch — otherwise it falls
		# through so the editor camera can adjust fly speed (when flying).
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _is_cursor_over_chrome(mb.position):
				return
			var step: float = 0.25 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -0.25
			if Input.is_key_pressed(KEY_SHIFT):
				step *= 4.0
			if Input.is_key_pressed(KEY_CTRL):
				step *= 0.25
			if _try_sculpt_at_mouse(step, mb.position):
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
		KEY_G:
			_snap_enabled = not _snap_enabled
			_refresh_status()
			get_viewport().set_input_as_handled()
		KEY_R:
			if _selected:
				_rotate_selection(-15.0 if ke.shift_pressed else 15.0)
				get_viewport().set_input_as_handled()
		KEY_P:
			# Drop a control point. Works whether the user has the
			# Terrain Mesh itself selected, or one of its child points
			# (we walk up to find the mesh in _drop_terrain_point).
			# Uses has_method/parentage rather than group membership so
			# a freshly-placed mesh works before its _ready fires.
			_dlog("KEY_P pressed sel=%s has_method=%s anc=%s" % [
				_dbg_sel_name(),
				str(_selected.has_method("add_point")) if _selected else "n/a",
				str(_has_terrain_mesh_ancestor(_selected)) if _selected else "n/a"])
			if _selected and (_selected.has_method("add_point")
					or _has_terrain_mesh_ancestor(_selected)):
				_drop_terrain_point()
				get_viewport().set_input_as_handled()
			else:
				_dlog("  KEY_P gate failed, nothing happens")
		KEY_UP:
			_nudge_selection(Vector3(0, 0, -1), ke)
			get_viewport().set_input_as_handled()
		KEY_DOWN:
			_nudge_selection(Vector3(0, 0, 1), ke)
			get_viewport().set_input_as_handled()
		KEY_LEFT:
			_nudge_selection(Vector3(-1, 0, 0), ke)
			get_viewport().set_input_as_handled()
		KEY_RIGHT:
			_nudge_selection(Vector3(1, 0, 0), ke)
			get_viewport().set_input_as_handled()
		KEY_PAGEUP:
			_nudge_selection(Vector3(0, 1, 0), ke)
			get_viewport().set_input_as_handled()
		KEY_PAGEDOWN:
			_nudge_selection(Vector3(0, -1, 0), ke)
			get_viewport().set_input_as_handled()
		# Ctrl+S, Ctrl+O, Ctrl+Z, Ctrl+Y, Ctrl+D are handled in _input
		# so focused widgets don't swallow them.


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

func _on_viewport_click(mouse_pos: Vector2) -> void:
	_dlog("LMB click mouse=%s pal=%d sel=%s" % [
		str(mouse_pos), _palette_idx, _dbg_sel_name()])
	# The user's cursor IS the picker. Raycast from the mouse position
	# through the camera into the 3D scene.
	var cam := _editor_cam()
	if cam == null:
		return
	var hit := EditorPlacementCls.raycast_from_mouse(cam, mouse_pos, 500.0, _preview_exclude_rids())
	_dlog("  raycast hit=%s pos=%s collider=%s" % [
		str(hit.get("hit")), str(hit.get("position")),
		(hit.get("collider").name if hit.get("collider") else "null")])

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
	if _snap_enabled:
		target_pos = EditorPlacementCls.snap_to_grid(target_pos, float(entry.get("snap", 1.0)))

	_dlog("  palette entry label=%s kind=%s path=%s" % [
		entry.get("label"), kind, entry.get("scene_path")])

	if kind == "wall_segment":
		_place_wall_step(target_pos)
		return

	# Terrain Mesh palette mode: each LMB click drops a point onto an
	# active terrain mesh. First click also creates the mesh. Tracked
	# in _active_terrain_mesh so subsequent clicks accumulate.
	if entry.get("scene_path", "") == EditorPlacementCls.TERRAIN_POINT_MESH_SCENE:
		_dlog("  -> terrain_mesh_click_workflow (active=%s)" % _dbg_active_mesh_name())
		_terrain_mesh_click_workflow(target_pos)
		return

	# Hide the ghost while we spawn the real prefab — _update_preview
	# will respawn next frame.
	_clear_preview()
	# Generic prefab/primitive placement.
	var placed: Node3D = EditorMode.get_or_create_placed_container()
	if placed == null:
		return
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, placed)
	if node == null:
		return
	node.global_position = target_pos
	_undo.record_place(node)
	_dlog("  placed %s, undo stack=%d" % [node.name, _undo.done.size()])
	EditorMode.dirty = true
	_select(node)


func _terrain_mesh_click_workflow(world_pos: Vector3) -> void:
	# Pick the target mesh in this order:
	#   1. Whatever the user has selected (TerrainPointMesh OR one of its
	#      child points — walked up to the mesh).
	#   2. The mesh we created during this palette session.
	#   3. A new mesh, if nothing else matches.
	# Without (1), clicking with a mesh selected would silently spawn a
	# new mesh somewhere else — the exact bug reported.
	var target_mesh: Node3D = null
	if _selected and is_instance_valid(_selected):
		if _selected.has_method("add_point"):
			target_mesh = _selected
		else:
			var n: Node = _selected.get_parent()
			while n != null:
				if n.has_method("add_point"):
					target_mesh = n as Node3D
					break
				n = n.get_parent()
	if target_mesh == null and _active_terrain_mesh and is_instance_valid(_active_terrain_mesh):
		target_mesh = _active_terrain_mesh
	if target_mesh == null:
		_dlog("  no selected/active mesh, creating new one")
		var placed: Node3D = EditorMode.get_or_create_placed_container()
		if placed == null:
			_dlog("  FAIL: no Placed container")
			return
		var scn: PackedScene = load(EditorPlacementCls.TERRAIN_POINT_MESH_SCENE) as PackedScene
		if scn == null:
			_dlog("  FAIL: cannot load terrain_point_mesh.tscn")
			return
		var fresh: Node3D = scn.instantiate() as Node3D
		placed.add_child(fresh)
		fresh.global_position = world_pos
		target_mesh = fresh
		_undo.record_place(fresh)
		_dlog("  created mesh=%s parent=%s undo=%d" % [fresh.name, placed.name, _undo.done.size()])
		EditorMode.dirty = true
	else:
		_dlog("  using existing mesh=%s" % target_mesh.name)
	_active_terrain_mesh = target_mesh
	if not target_mesh.has_method("add_point"):
		_dlog("  FAIL: target mesh has no add_point method")
		return
	var local_pos: Vector3 = target_mesh.to_local(world_pos)
	var p: Node3D = target_mesh.call("add_point", local_pos)
	if p == null:
		_dlog("  FAIL: add_point returned null")
		return
	_undo.record_place(p)
	_dlog("  added point=%s child_of=%s undo=%d" % [
		p.name, p.get_parent().name if p.get_parent() else "ORPHAN", _undo.done.size()])
	EditorMode.dirty = true
	_select(p)


# ---------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------

func _select(node: Node3D) -> void:
	if _selected == node:
		return
	_clear_selection()
	_selected = node
	_dlog("_select %s parent=%s groups=%s" % [
		node.name if node else "null",
		node.get_parent().name if node and node.get_parent() else "null",
		str(node.get_groups()) if node else "[]"])
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
	# Terrain points break out of the walk early so each point is its
	# own selectable target rather than always grabbing the whole mesh.
	var sc := get_tree().current_scene
	var n: Node = collider as Node
	var best: Node3D = null
	while n != null and n != sc:
		if n is Node3D:
			best = n
			if (n as Node3D).is_in_group("terrain_point"):
				break
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


func _rotate_selection(degrees: float) -> void:
	if _selected == null:
		return
	var before := _xform_snapshot(_selected)
	_selected.rotation.y += deg_to_rad(degrees)
	_push_transform_undo(_selected, before)


func _nudge_selection(world_axis: Vector3, ke: InputEventKey) -> void:
	if _selected == null:
		return
	var step: float = 0.5
	if ke.shift_pressed:
		step = 2.0
	elif ke.ctrl_pressed:
		step = 0.1
	if _snap_enabled:
		# Use the most reasonable snap unit available.
		step = max(step, 0.5)
	var before := _xform_snapshot(_selected)
	_selected.global_position += world_axis * step
	_push_transform_undo(_selected, before)


func _duplicate_selection() -> void:
	if _selected == null:
		return
	# Use Godot's duplicate so any custom properties / children survive.
	# DUPLICATE_USE_INSTANTIATION preserves scene-instance structure.
	var clone: Node = _selected.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
	if clone == null or not (clone is Node3D):
		return
	var c3d: Node3D = clone
	var parent: Node = _selected.get_parent()
	if parent == null:
		parent = EditorMode.get_or_create_placed_container()
	parent.add_child(c3d)
	# Offset 1m to the camera-right so the dupe doesn't z-fight the source.
	var cam := _editor_cam()
	var right: Vector3 = Vector3.RIGHT
	if cam:
		right = cam.global_transform.basis.x
		right.y = 0
		if right.length() > 0.0001:
			right = right.normalized()
	c3d.global_position = _selected.global_position + right * 1.0
	c3d.rotation = _selected.rotation
	c3d.scale = _selected.scale
	_undo.record_place(c3d)
	EditorMode.dirty = true
	_select(c3d)


func _xform_snapshot(n: Node3D) -> Dictionary:
	return {
		"pos":   n.position,
		"rot":   n.rotation,
		"scale": n.scale,
	}


func _push_transform_undo(n: Node3D, before: Dictionary) -> void:
	_undo.push({
		"type":   "transform",
		"target": n.get_path(),
		"before": before,
		"after":  _xform_snapshot(n),
	})
	EditorMode.dirty = true
	# Refresh inspector spinboxes so they reflect the new transform.
	if _inspector and _selected == n:
		_inspector.set_target(n)


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
	ghost.set_meta("editor_only", true)
	_outline = ghost


func _update_outline() -> void:
	if _outline == null or _selected == null or not is_instance_valid(_selected):
		return
	var mesh: MeshInstance3D = _find_mesh(_selected)
	if mesh:
		# Mirror the mesh's transform, then apply a fixed 4% scale offset.
		# The previous version did `*= 1.04` every frame, so the outline
		# grew without bound (~10× after one second) — that's what made
		# the "ghost" hang around looking enormous after Ctrl+Z.
		var t: Transform3D = mesh.global_transform
		t.basis = t.basis.scaled(Vector3(1.04, 1.04, 1.04))
		_outline.global_transform = t


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

	_clear_preview()
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
# Placement preview (translucent ghost at the reticle)
# ---------------------------------------------------------------------

func _update_preview() -> void:
	# No active palette slot → no ghost.
	if _palette_idx < 0 or _palette_idx >= _catalog.size():
		_clear_preview()
		return
	var entry: Dictionary = _catalog[_palette_idx]
	var kind: String = String(entry.get("kind", ""))
	# mesh_placeholder doesn't actually place anything.
	if kind == "mesh_placeholder":
		_clear_preview()
		return
	# Re-spawn the ghost if the palette pick changed.
	if _preview == null or not is_instance_valid(_preview) or _preview_kind != kind:
		_spawn_preview(entry)
		if _preview == null:
			return
	# Position at the cursor — exclude the ghost's own bodies so the
	# preview doesn't intercept its own targeting ray. Hide the ghost
	# entirely when the cursor is over UI chrome so it doesn't jump
	# around behind the palette/inspector.
	var cam := _editor_cam()
	if cam == null:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	if _is_cursor_over_chrome(mouse_pos):
		_preview.visible = false
		return
	_preview.visible = true
	var hit := EditorPlacementCls.raycast_from_mouse(cam, mouse_pos, 500.0, _preview_exclude_rids())
	var target_pos: Vector3 = hit.get("position",
			cam.global_position + (-cam.global_transform.basis.z) * 5.0)
	if _snap_enabled:
		target_pos = EditorPlacementCls.snap_to_grid(target_pos, float(entry.get("snap", 1.0)))
	if kind == "wall_segment" and _wall_has_anchor:
		# Stretch the ghost from the anchor to the reticle.
		var a := _wall_anchor
		var b := target_pos
		var mid := (a + b) * 0.5
		var delta := b - a
		delta.y = 0
		var length: float = max(delta.length(), 0.1)
		var yaw: float = atan2(delta.x, delta.z)
		_preview.global_position = mid
		_preview.rotation = Vector3(0, yaw, 0)
		_preview.scale = Vector3(1.0, 1.0, length / 10.0)
	else:
		_preview.global_position = target_pos
		_preview.rotation = Vector3.ZERO
		_preview.scale = Vector3.ONE


func _spawn_preview(entry: Dictionary) -> void:
	_clear_preview()
	var sc := get_tree().current_scene
	if sc == null:
		return
	# Use spawn_entry to build the node, then mark it as ghost-only.
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, sc)
	if node == null:
		return
	node.set_meta("editor_only", true)
	_disable_collision(node)
	_apply_ghost_material(node)
	_preview = node
	_preview_kind = String(entry.get("kind", ""))


func _clear_preview() -> void:
	if _preview and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null
	_preview_kind = ""


func _preview_exclude_rids() -> Array:
	# Returns every CollisionObject3D RID in the ghost subtree so raycasts
	# can ignore the ghost. Belt-and-braces with _disable_collision since
	# some prefabs (CSG, post-_ready scripts) can re-enable layers.
	if _preview == null or not is_instance_valid(_preview):
		return []
	var out: Array = []
	for n in _walk(_preview):
		if n is CollisionObject3D:
			out.append((n as CollisionObject3D).get_rid())
	return out


func _disable_collision(node: Node) -> void:
	# Walk the subtree and disable every CollisionObject3D so the ghost
	# doesn't intercept the raycast we're using to position it.
	for n in _walk(node):
		if n is CollisionObject3D:
			var co: CollisionObject3D = n
			co.collision_layer = 0
			co.collision_mask = 0
		elif n is Area3D:
			(n as Area3D).monitoring = false


func _apply_ghost_material(node: Node) -> void:
	# Override every MeshInstance3D with a translucent unshaded material so
	# the ghost reads as a preview. Also dim Light nodes so the ghost
	# doesn't blow out the level.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.85, 1.0, 0.45)
	mat.flags_transparent = true
	mat.flags_unshaded = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	for n in _walk(node):
		if n is MeshInstance3D:
			(n as MeshInstance3D).material_override = mat
		elif n is Light3D:
			(n as Light3D).light_energy = 0.0
		elif n is Sprite3D:
			(n as Sprite3D).modulate = Color(1, 1, 1, 0.45)


func _walk(root: Node) -> Array:
	var out: Array = [root]
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out


# ---------------------------------------------------------------------
# Terrain height (wheel at reticle)
# ---------------------------------------------------------------------

func _try_sculpt_at_mouse(step: float, mouse_pos: Vector2) -> bool:
	# Wheel-tick sculpt: raise (+) or lower (-) the terrain under the
	# cursor by `step` metres at the centre, falling off to 0 at radius.
	# Returns true if a terrain_patch was hit (so the caller swallows the
	# event); false lets the wheel fall through to fly-speed adjust.
	var cam := _editor_cam()
	if cam == null:
		return false
	var hit := EditorPlacementCls.raycast_from_mouse(cam, mouse_pos, 500.0, _preview_exclude_rids())
	if not hit.get("hit", false):
		return false
	var patch: Node = _find_terrain_patch(hit.get("collider"))
	if patch == null or not patch.has_method("sculpt"):
		return false
	var center: Vector3 = hit.get("position", Vector3.ZERO)
	var radius: float = 4.0 if Input.is_key_pressed(KEY_SHIFT) else 2.0
	# patch.sculpt computes height += strength * dt * falloff. Encode the
	# discrete tick as strength*dt = |step| so the centre vertex moves
	# exactly `step` metres.
	var before: PackedFloat32Array = patch.call("get_heights")
	patch.sculpt(center, radius, abs(step) * 10.0, 0.1,
			"raise" if step > 0.0 else "lower")
	var after: PackedFloat32Array = patch.call("get_heights")
	_undo.push({
		"type":   "sculpt",
		"target": patch.get_path(),
		"before": before,
		"after":  after,
	})
	EditorMode.dirty = true
	_refresh_status()
	return true


func _drop_terrain_point() -> void:
	_dlog("P-drop fired sel=%s" % _dbg_sel_name())
	# P-key hotkey when a Terrain Mesh is selected. If the reticle hits
	# something, drop the point at that hit; otherwise (hovering in
	# empty space) drop it at the camera so the user can fly around
	# placing points free-form without needing a surface underneath.
	var cam := _editor_cam()
	if cam == null or _selected == null:
		_dlog("  abort: cam=%s sel=%s" % [str(cam), _dbg_sel_name()])
		return
	# Walk up if the user has a child point selected — drop into the
	# parent mesh, not into a point.
	var mesh: Node = _selected
	if not mesh.has_method("add_point"):
		_dlog("  selected lacks add_point, walking up parents")
		var p_walk: Node = mesh.get_parent()
		while p_walk != null:
			_dlog("    walk: %s has_method=%s" % [p_walk.name, str(p_walk.has_method("add_point"))])
			if p_walk.has_method("add_point"):
				mesh = p_walk
				break
			p_walk = p_walk.get_parent()
	if not mesh.has_method("add_point"):
		_dlog("  FAIL: no ancestor with add_point — P does nothing")
		return
	# P always drops the point at the camera position. To place at a
	# specific spot, MMB-click that spot first to teleport the camera
	# there, then press P. This decouples placement from cursor (which
	# was confusing because the cursor is also the picker).
	var world_pos: Vector3 = cam.global_position
	var local_pos: Vector3 = (mesh as Node3D).to_local(world_pos)
	var p: Node3D = mesh.call("add_point", local_pos)
	if p:
		_undo.record_place(p)
		_dlog("  P added point=%s under=%s undo=%d" % [
			p.name, p.get_parent().name if p.get_parent() else "ORPHAN", _undo.done.size()])
		EditorMode.dirty = true
		_select(p)
	else:
		_dlog("  FAIL: add_point returned null")


func _has_terrain_mesh_ancestor(n: Node) -> bool:
	# True if any ancestor exposes add_point — that's the duck-typed
	# signature of a terrain_point_mesh.gd container.
	var cur: Node = n.get_parent() if n else null
	while cur != null:
		if cur.has_method("add_point"):
			return true
		cur = cur.get_parent()
	return false


func _find_terrain_patch(collider: Variant) -> Node:
	# Walk up from the raycast collider to the nearest terrain_patch group
	# member. Returns null if none found.
	var n: Node = collider as Node
	while n != null:
		if n.is_in_group("terrain_patch"):
			return n
		n = n.get_parent()
	return null


# ---------------------------------------------------------------------
# Save / load
# ---------------------------------------------------------------------

func _save_level() -> void:
	# Strip outline + wall marker + ghost so they don't pack into the .tscn.
	_clear_outline()
	_clear_wall_anchor_marker()
	_clear_preview()
	if EditorMode.save_level():
		_refresh_status()


func _on_save_as_picked(path: String) -> void:
	_clear_outline()
	_clear_wall_anchor_marker()
	_clear_preview()
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
	# Switching palette slot starts a fresh terrain mesh — otherwise
	# re-picking Terrain Mesh would keep dropping points into the old
	# one. Also clears on deselect (catalog_index = -1).
	_active_terrain_mesh = null
	_dlog("palette pick idx=%d label=%s" % [
		catalog_index,
		_catalog[catalog_index].get("label") if catalog_index >= 0 and catalog_index < _catalog.size() else "(none)"])
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
