extends CanvasLayer

# Top-level editor UI overlay. CanvasLayer at layer 70 (above HUD's 50,
# below pause's 80). Owns nearly every interaction surface in edit mode.
#
# Subsystems composed in here:
#   - EditorPalette (bottom)        — placeable catalog, 1-9 keys
#   - EditorInspector (right)       — per-node property editor
#   - EditorMinimap (top-right)     — 2D world overview
#   - EditorUndo (this script)      — Ctrl+Z / Ctrl+Y stack
#   - EditorClipboard               — Ctrl+C / Ctrl+V
#   - EditorSculpt / EditorPaint    — terrain brushes (B / P)
#   - EditorWallTool                — point-to-point wall placement (W)
#
# The 3D viewport is "captured" by the editor camera so mouse-look is
# continuous. When the cursor crosses into a UI panel we release the
# capture so widgets can be clicked, then re-capture on exit.

const EditorPlacementCls = preload("res://scripts/editor_placement.gd")
const EditorPaletteCls   = preload("res://scripts/editor_palette.gd")
const EditorInspectorCls = preload("res://scripts/editor_inspector.gd")
const EditorMinimapCls   = preload("res://scripts/editor_minimap.gd")
const EditorUndoCls      = preload("res://scripts/editor_undo.gd")
const EditorClipboardCls = preload("res://scripts/editor_clipboard.gd")
const EditorSculptCls    = preload("res://scripts/editor_sculpt.gd")
const EditorPaintCls     = preload("res://scripts/editor_paint.gd")
const EditorWallToolCls  = preload("res://scripts/editor_wall_tool.gd")
const EditorMaterialsCls = preload("res://scripts/editor_materials.gd")
const LevelTemplateCls   = preload("res://scripts/level_template.gd")

# ---- UI nodes
var _status: Label = null
var _palette: Control = null
var _palette_ctrl = null
var _inspector: Control = null
var _inspector_ctrl = null
var _minimap: Control = null
var _minimap_ctrl = null
var _hint_bar: Label = null
var _toolbar: Control = null
var _topbar: Control = null
var _snap_check: CheckBox = null
var _snap_step: SpinBox = null
var _bookmark_row: HBoxContainer = null
var _bookmark_buttons: Array = []
var _brush_panel: Control = null
var _brush_label: Label = null
var _paint_palette_row: HBoxContainer = null
var _wall_panel: Control = null
var _wall_height_spin: SpinBox = null
var _wall_thick_spin: SpinBox = null
var _wall_mat_option: OptionButton = null
var _box_select_rect: ColorRect = null
var _viewport_blocker: Control = null     # absorbs viewport clicks vs ui panels

var _file_dialog: FileDialog = null
var _new_level_dialog: AcceptDialog = null
var _new_level_input: LineEdit = null
var _new_level_pending_lz: Node = null

# ---- Selection / tool state
enum Tool { NONE, GRAB, ROTATE, SCALE, WALL, SCULPT, PAINT }
var _selected: Array = []          # Array of Node3D — multi-select
var _outlines: Array = []          # parallel ghost MeshInstance3D
var _tool: int = Tool.NONE
var _drag_active: bool = false
var _drag_start_mouse: Vector2 = Vector2.ZERO
var _drag_start_poses: Array = []  # per-selection start transform snapshot

# Box-select state
var _box_active: bool = false
var _box_start: Vector2 = Vector2.ZERO

# Snap + grid
var _grid_snap: bool = false
var _grid_step: float = 1.0

# Catalog + palette index
var _catalog: Array = []
var _selected_palette: int = -1

# Subsystem singletons
var _undo: EditorUndoCls = null
var _clipboard: EditorClipboardCls = null
var _sculpt: EditorSculptCls = null
var _paint: EditorPaintCls = null
var _wall: EditorWallToolCls = null

# Camera bookmarks 1..9
var _bookmarks: Array = []

# Wireframe + bounding-box toggles
var _wireframe_on: bool = false
var _bbox_on: bool = false
var _bbox_overlays: Array = []

# Brush cursor (terrain disc)
var _brush_cursor: MeshInstance3D = null


func _ready() -> void:
	layer = 70
	visible = false
	_undo = EditorUndoCls.new()
	_clipboard = EditorClipboardCls.new()
	_sculpt = EditorSculptCls.new()
	_paint = EditorPaintCls.new()
	_wall = EditorWallToolCls.new()
	_bookmarks.resize(10)
	for i in 10:
		_bookmarks[i] = {}
	_build_layout()
	_catalog = EditorPlacementCls.build_catalog()
	_palette_ctrl.set_catalog(_catalog)
	EditorMode.mode_changed.connect(_on_mode_changed)
	EditorMode.dirty_changed.connect(_on_dirty_changed)
	visible = EditorMode.is_edit
	_refresh_status()
	set_process(true)


func _process(delta: float) -> void:
	if not EditorMode.is_edit:
		return
	_update_brush_cursor()
	_update_wall_preview()
	_tick_active_brush(delta)


func _on_mode_changed(is_edit: bool) -> void:
	visible = is_edit
	if not is_edit:
		_clear_selection()
		_tool = Tool.NONE
		_sculpt.exit()
		_paint.exit()
		_wall.exit()
		_undo.clear()
		_clear_bbox_overlays()
		if _wireframe_on:
			_apply_wireframe_state_off()
	else:
		_undo.clear()
		_apply_wireframe_state()
	_refresh_status()


func _on_dirty_changed(_is_dirty: bool) -> void:
	_refresh_status()


# ---- Layout ----------------------------------------------------------

func _build_layout() -> void:
	# Top bar: snap toggle, snap step, bookmark buttons, status text.
	_topbar = PanelContainer.new()
	_topbar.anchor_left = 0.0
	_topbar.anchor_right = 1.0
	_topbar.anchor_top = 0.0
	_topbar.offset_left = 8
	_topbar.offset_right = -8
	_topbar.offset_top = 4
	_topbar.offset_bottom = 38
	add_child(_topbar)
	var topbar_row := HBoxContainer.new()
	topbar_row.add_theme_constant_override("separation", 8)
	_topbar.add_child(topbar_row)
	_status = Label.new()
	_status.text = "EDIT"
	_status.add_theme_font_size_override("font_size", 13)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topbar_row.add_child(_status)
	# Snap toggle + size.
	_snap_check = CheckBox.new()
	_snap_check.text = "Snap"
	_snap_check.button_pressed = _grid_snap
	_snap_check.toggled.connect(func(p): _grid_snap = p)
	topbar_row.add_child(_snap_check)
	_snap_step = SpinBox.new()
	_snap_step.min_value = 0.1
	_snap_step.max_value = 16.0
	_snap_step.step = 0.1
	_snap_step.value = _grid_step
	_snap_step.value_changed.connect(func(v): _grid_step = v)
	topbar_row.add_child(_snap_step)
	# Save / Open.
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_save_level)
	topbar_row.add_child(save_btn)
	var open_btn := Button.new()
	open_btn.text = "Open"
	open_btn.pressed.connect(_open_load_dialog)
	topbar_row.add_child(open_btn)
	# Bookmark row.
	_bookmark_row = HBoxContainer.new()
	_bookmark_row.add_theme_constant_override("separation", 2)
	topbar_row.add_child(_bookmark_row)
	for i in range(1, 10):
		var b := Button.new()
		b.text = str(i)
		b.tooltip_text = "Click: jump to bookmark %d  •  Shift+%d to save" % [i, i]
		b.custom_minimum_size = Vector2(24, 24)
		b.pressed.connect(_on_bookmark_click.bind(i))
		_bookmark_row.add_child(b)
		_bookmark_buttons.append(b)

	# Left toolbar
	_toolbar = PanelContainer.new()
	_toolbar.anchor_top = 0.0
	_toolbar.anchor_bottom = 1.0
	_toolbar.offset_top = 44
	_toolbar.offset_bottom = -120
	_toolbar.offset_left = 8
	_toolbar.offset_right = 60
	add_child(_toolbar)
	var tb_v := VBoxContainer.new()
	tb_v.add_theme_constant_override("separation", 4)
	_toolbar.add_child(tb_v)
	_make_tool_btn(tb_v, "Sel", Tool.NONE, "Select / pan (no tool)")
	_make_tool_btn(tb_v, "G",   Tool.GRAB,   "Grab (G) — drag selection")
	_make_tool_btn(tb_v, "R",   Tool.ROTATE, "Rotate (R)")
	_make_tool_btn(tb_v, "S",   Tool.SCALE,  "Scale (S)")
	_make_tool_btn(tb_v, "Wall", Tool.WALL,  "Wall tool (W)")
	_make_tool_btn(tb_v, "Sclp", Tool.SCULPT,"Sculpt terrain (B)")
	_make_tool_btn(tb_v, "Pnt",  Tool.PAINT, "Paint terrain (P)")

	# Palette strip (bottom).
	_palette = Control.new()
	_palette.anchor_left = 0.0
	_palette.anchor_right = 1.0
	_palette.anchor_bottom = 1.0
	_palette.offset_top = -110
	_palette.offset_bottom = -8
	_palette.offset_left = 68
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
	_inspector.offset_bottom = -200
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

	# Brush panel (bottom-right just above hint bar) — only visible when
	# sculpt or paint is active.
	_brush_panel = PanelContainer.new()
	_brush_panel.anchor_left = 1.0
	_brush_panel.anchor_right = 1.0
	_brush_panel.anchor_bottom = 1.0
	_brush_panel.offset_left = -320
	_brush_panel.offset_right = -8
	_brush_panel.offset_top = -190
	_brush_panel.offset_bottom = -120
	_brush_panel.visible = false
	add_child(_brush_panel)
	var brush_v := VBoxContainer.new()
	_brush_panel.add_child(brush_v)
	_brush_label = Label.new()
	_brush_label.text = "Brush"
	brush_v.add_child(_brush_label)
	_paint_palette_row = HBoxContainer.new()
	brush_v.add_child(_paint_palette_row)
	for sid in range(7):
		var b := Button.new()
		b.text = EditorMaterialsCls.surface_name(sid)
		b.modulate = EditorMaterialsCls.surface_color(sid)
		b.tooltip_text = "Paint as %s (key %d)" % [b.text, sid + 1]
		b.pressed.connect(_on_paint_color_pick.bind(sid))
		_paint_palette_row.add_child(b)

	# Wall config panel (visible when wall tool active).
	_wall_panel = PanelContainer.new()
	_wall_panel.anchor_left = 1.0
	_wall_panel.anchor_right = 1.0
	_wall_panel.anchor_bottom = 1.0
	_wall_panel.offset_left = -320
	_wall_panel.offset_right = -8
	_wall_panel.offset_top = -190
	_wall_panel.offset_bottom = -120
	_wall_panel.visible = false
	add_child(_wall_panel)
	var wall_v := VBoxContainer.new()
	_wall_panel.add_child(wall_v)
	var wh_lbl := Label.new()
	wh_lbl.text = "Wall config"
	wall_v.add_child(wh_lbl)
	_wall_height_spin = SpinBox.new()
	_wall_height_spin.min_value = 1.0
	_wall_height_spin.max_value = 10.0
	_wall_height_spin.step = 0.25
	_wall_height_spin.value = _wall.wall_height
	_wall_height_spin.value_changed.connect(func(v): _wall.wall_height = v)
	wall_v.add_child(_labelled("Height", _wall_height_spin))
	_wall_thick_spin = SpinBox.new()
	_wall_thick_spin.min_value = 0.1
	_wall_thick_spin.max_value = 2.0
	_wall_thick_spin.step = 0.05
	_wall_thick_spin.value = _wall.wall_thickness
	_wall_thick_spin.value_changed.connect(func(v): _wall.wall_thickness = v)
	wall_v.add_child(_labelled("Thickness", _wall_thick_spin))
	_wall_mat_option = OptionButton.new()
	var wall_kinds: Array[String] = ["stone", "wood", "brick", "dirt", "metal"]
	for kind in wall_kinds:
		_wall_mat_option.add_item(kind.capitalize())
	_wall_mat_option.item_selected.connect(func(idx):
		var kinds: Array[String] = ["stone", "wood", "brick", "dirt", "metal"]
		_wall.material_kind = kinds[idx])
	wall_v.add_child(_labelled("Material", _wall_mat_option))

	# Hotkey hint bar (bottom-right).
	var hint_panel := PanelContainer.new()
	hint_panel.anchor_left = 1.0
	hint_panel.anchor_right = 1.0
	hint_panel.anchor_bottom = 1.0
	hint_panel.offset_left = -320
	hint_panel.offset_right = -8
	hint_panel.offset_top = -112
	hint_panel.offset_bottom = -8
	add_child(hint_panel)
	_hint_bar = Label.new()
	_hint_bar.text = ("WASD fly  Q/E  Shift x3  Ctrl x0.3  Wheel FOV\n"
			+ "Alt/F1: release cursor   T/Numpad 7 top   0 reset\n"
			+ "1-9 palette  (no palette: 1-9 jump bookmark, Shift+1-9 save)\n"
			+ "G/R/S grab/rot/scale  W wall  B sculpt  P paint  Z wire  V bbox\n"
			+ "Ctrl-click multi-select  drag empty = box-select  Ctrl+G group\n"
			+ "Ctrl+C/V copy/paste  Ctrl+Z/Y undo  Ctrl+D dup  Del delete\n"
			+ ".  toggle snap  Ctrl+S save  Ctrl+O open  Tab → play")
	_hint_bar.add_theme_font_size_override("font_size", 10)
	hint_panel.add_child(_hint_bar)

	# Box-select overlay (Control + ColorRect drawn on top).
	_box_select_rect = ColorRect.new()
	_box_select_rect.color = Color(1.0, 0.9, 0.2, 0.18)
	_box_select_rect.visible = false
	_box_select_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box_select_rect)


func _make_tool_btn(parent: VBoxContainer, label: String, tool_id: int, tip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(44, 32)
	b.pressed.connect(_on_tool_btn.bind(tool_id))
	parent.add_child(b)
	return b


func _on_tool_btn(id: int) -> void:
	_set_tool(id)


func _labelled(text: String, child: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(80, 0)
	h.add_child(l)
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(child)
	return h


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
	var tool_name: String = "—"
	match _tool:
		Tool.GRAB:   tool_name = "GRAB"
		Tool.ROTATE: tool_name = "ROT"
		Tool.SCALE:  tool_name = "SCL"
		Tool.WALL:   tool_name = "WALL"
		Tool.SCULPT: tool_name = "SCULPT"
		Tool.PAINT:  tool_name = "PAINT"
	var sel_count := _selected.size()
	var sel_str: String = ""
	if sel_count > 0:
		sel_str = " | sel=%d" % sel_count
	_status.text = "[%s%s] %s — %s  [%s]%s" % [badge, dirty_marker, sname, path, tool_name, sel_str]


# ---- Input dispatch --------------------------------------------------

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

	# Ctrl combos first.
	if ev.ctrl_pressed:
		match ev.keycode:
			KEY_S:
				if ev.shift_pressed:
					_open_save_as_dialog()
				else:
					_save_level()
				get_viewport().set_input_as_handled()
				return
			KEY_O:
				_open_load_dialog()
				get_viewport().set_input_as_handled()
				return
			KEY_D:
				_duplicate_selected()
				get_viewport().set_input_as_handled()
				return
			KEY_C:
				_copy_selection()
				get_viewport().set_input_as_handled()
				return
			KEY_V:
				_paste_clipboard()
				get_viewport().set_input_as_handled()
				return
			KEY_Z:
				if ev.shift_pressed:
					_redo()
				else:
					_undo_action()
				get_viewport().set_input_as_handled()
				return
			KEY_Y:
				_redo()
				get_viewport().set_input_as_handled()
				return
			KEY_G:
				if ev.shift_pressed:
					_ungroup_selected()
				else:
					_group_selected()
				get_viewport().set_input_as_handled()
				return

	# Number keys 1-9: palette slot OR bookmark jump (when palette empty).
	if ev.keycode >= KEY_1 and ev.keycode <= KEY_9:
		var num: int = ev.keycode - KEY_0
		if ev.shift_pressed:
			_save_bookmark(num)
			get_viewport().set_input_as_handled()
			return
		# Brush strength override (sculpt/paint tool active).
		if _tool == Tool.SCULPT:
			_sculpt.set_strength(0.1 * num)
			_refresh_brush_panel()
			get_viewport().set_input_as_handled()
			return
		if _tool == Tool.PAINT:
			_paint.set_surface(num - 1)
			_refresh_brush_panel()
			get_viewport().set_input_as_handled()
			return
		var visible_entries: Array = _palette_ctrl.get_visible_entries()
		if _selected_palette >= 0 or num - 1 < visible_entries.size():
			# Palette select path (also handles "no entry yet" by toggling).
			var idx: int = num - 1
			if idx < visible_entries.size():
				_palette_ctrl.select_index(_palette_ctrl.scroll_offset + idx)
				get_viewport().set_input_as_handled()
				return
		# No palette selection and bookmark exists → jump.
		_jump_bookmark(num)
		get_viewport().set_input_as_handled()
		return

	match ev.keycode:
		KEY_ESCAPE:
			_palette_ctrl.select_index(-1)
			_clear_selection()
			_set_tool(Tool.NONE)
			get_viewport().set_input_as_handled()
		KEY_G:
			_set_tool(Tool.GRAB)
			get_viewport().set_input_as_handled()
		KEY_R:
			_set_tool(Tool.ROTATE)
			get_viewport().set_input_as_handled()
		KEY_S:
			# Only switch to scale tool if there's a selection AND no movement
			# keys held (so S stays "fly back").
			if not _selected.is_empty() and not _looking_or_moving():
				_set_tool(Tool.SCALE)
				get_viewport().set_input_as_handled()
		KEY_W:
			# Same guard for W → wall tool.
			if not _looking_or_moving():
				_set_tool(Tool.WALL)
				get_viewport().set_input_as_handled()
		KEY_B:
			# Sculpt — only when a terrain is selected.
			if _selected.size() == 1 and _selected[0].is_in_group("terrain_patch"):
				if _tool == Tool.SCULPT:
					_set_tool(Tool.NONE)
				else:
					_set_tool(Tool.SCULPT)
				get_viewport().set_input_as_handled()
		KEY_P:
			if _selected.size() == 1 and _selected[0].is_in_group("terrain_patch"):
				if _tool == Tool.PAINT:
					_set_tool(Tool.NONE)
				else:
					_set_tool(Tool.PAINT)
				get_viewport().set_input_as_handled()
		KEY_BRACKETLEFT:
			if _tool == Tool.SCULPT:
				_sculpt.set_radius_delta(-0.5); _refresh_brush_panel()
			elif _tool == Tool.PAINT:
				_paint.set_radius_delta(-0.5); _refresh_brush_panel()
			get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			if _tool == Tool.SCULPT:
				_sculpt.set_radius_delta(0.5); _refresh_brush_panel()
			elif _tool == Tool.PAINT:
				_paint.set_radius_delta(0.5); _refresh_brush_panel()
			get_viewport().set_input_as_handled()
		KEY_T:
			_apply_top_view()
			get_viewport().set_input_as_handled()
		KEY_PERIOD:
			_grid_snap = not _grid_snap
			_snap_check.button_pressed = _grid_snap
			get_viewport().set_input_as_handled()
		KEY_Z:
			_toggle_wireframe()
			get_viewport().set_input_as_handled()
		KEY_V:
			_toggle_bbox()
			get_viewport().set_input_as_handled()
		KEY_DELETE, KEY_BACKSPACE:
			_delete_selected()
			get_viewport().set_input_as_handled()


func _looking_or_moving() -> bool:
	return (Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_A)
			or Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_Q)
			or Input.is_key_pressed(KEY_E))


func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	# Right-click cancels wall placement.
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		if _tool == Tool.WALL:
			_wall.have_anchor = false
			get_viewport().set_input_as_handled()
			return
	# Wheel pass-through to palette when over palette only.
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
		if _mouse_on_panel(_palette, mb.position):
			_palette_ctrl.scroll(-1)
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
		if _mouse_on_panel(_palette, mb.position):
			_palette_ctrl.scroll(1)
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	# Toggle capture when clicking into UI / viewport.
	var cam: Camera3D = _get_editor_camera()
	if _mouse_on_ui(mb.position):
		# Click landed on a UI panel; the panel handles it. Release cursor
		# so the user can interact with widgets.
		if cam and cam.has_method("release_mouse"):
			cam.release_mouse()
		return
	# Clicking the viewport — re-capture mouse so look continues.
	if cam and cam.has_method("capture_mouse"):
		cam.capture_mouse()

	if mb.pressed:
		_on_viewport_lmb_pressed(mb)
	else:
		_on_viewport_lmb_released(mb)


func _on_viewport_lmb_pressed(mb: InputEventMouseButton) -> void:
	# Wall tool path.
	if _tool == Tool.WALL:
		var cam: Camera3D = _get_editor_camera()
		if cam == null:
			return
		var hit := EditorPlacementCls.raycast_from_mouse(cam, mb.position)
		var pos: Vector3 = hit["position"]
		if _grid_snap:
			pos = EditorPlacementCls.snap_to_grid(pos, _grid_step)
		var parent: Node = EditorMode.get_or_create_placed_container()
		var placed: Node3D = _wall.pick(pos, parent)
		if placed:
			_push_place_action(placed)
			EditorMode.dirty = true
		get_viewport().set_input_as_handled()
		return
	# Sculpt brush stroke.
	if _tool == Tool.SCULPT and _selected.size() == 1 \
			and _selected[0].is_in_group("terrain_patch"):
		_sculpt.enter(_selected[0])
		var mode := EditorSculptCls.MODE_RAISE
		if Input.is_key_pressed(KEY_SHIFT):
			mode = EditorSculptCls.MODE_LOWER
		elif Input.is_key_pressed(KEY_CTRL):
			mode = EditorSculptCls.MODE_SMOOTH
		elif Input.is_key_pressed(KEY_ALT):
			mode = EditorSculptCls.MODE_FLATTEN
		_sculpt.begin_stroke(mode)
		get_viewport().set_input_as_handled()
		return
	# Paint brush stroke.
	if _tool == Tool.PAINT and _selected.size() == 1 \
			and _selected[0].is_in_group("terrain_patch"):
		_paint.enter(_selected[0])
		_paint.begin_stroke()
		get_viewport().set_input_as_handled()
		return
	# Palette placement.
	if _selected_palette >= 0:
		_place_at_mouse(mb.position)
		get_viewport().set_input_as_handled()
		return
	# Transform drag on existing selection.
	if _tool in [Tool.GRAB, Tool.ROTATE, Tool.SCALE] and not _selected.is_empty():
		_begin_drag(mb.position)
		get_viewport().set_input_as_handled()
		return
	# Pick / box-select.
	var ctrl_held: bool = Input.is_key_pressed(KEY_CTRL)
	_pick_or_box_start(mb.position, ctrl_held)
	get_viewport().set_input_as_handled()


func _on_viewport_lmb_released(_mb: InputEventMouseButton) -> void:
	if _box_active:
		_finish_box_select(_mb.position)
		return
	if _drag_active:
		_end_drag()
		return
	if _sculpt.painting:
		var action: Dictionary = _sculpt.end_stroke()
		if not action.is_empty() and _selected.size() == 1:
			action["target"] = _node_path_for(_selected[0])
			_undo.push(action)
			EditorMode.dirty = true
		return
	if _paint.painting:
		var paction: Dictionary = _paint.end_stroke()
		if not paction.is_empty() and _selected.size() == 1:
			paction["target"] = _node_path_for(_selected[0])
			_undo.push(paction)
			EditorMode.dirty = true
		return


func _handle_mouse_motion(mm: InputEventMouseMotion) -> void:
	if _drag_active and not _selected.is_empty():
		_update_drag(mm.position, mm.relative)
		return
	if _box_active:
		_update_box_select(mm.position)
		return


# ---- Tool switching --------------------------------------------------

func _set_tool(t: int) -> void:
	if _tool == t:
		return
	# Tear down old tool.
	if _tool == Tool.SCULPT:
		_sculpt.exit()
	elif _tool == Tool.PAINT:
		_paint.exit()
	elif _tool == Tool.WALL:
		_wall.exit()
	_tool = t
	# Bring up new tool.
	if t == Tool.SCULPT and _selected.size() == 1:
		_sculpt.enter(_selected[0])
	elif t == Tool.PAINT and _selected.size() == 1:
		_paint.enter(_selected[0])
	elif t == Tool.WALL:
		_wall.enter(get_tree().current_scene)
	_brush_panel.visible = (t == Tool.SCULPT or t == Tool.PAINT)
	_wall_panel.visible = (t == Tool.WALL)
	_refresh_brush_panel()
	_refresh_status()


func _refresh_brush_panel() -> void:
	if _brush_label == null:
		return
	if _tool == Tool.SCULPT:
		_brush_label.text = "Sculpt — r=%.1fm  str=%.2f  [Shift=lower Ctrl=smooth Alt=flatten]" \
				% [_sculpt.radius, _sculpt.strength]
		_paint_palette_row.visible = false
	elif _tool == Tool.PAINT:
		_brush_label.text = "Paint — r=%.1fm  surface=%s" \
				% [_paint.radius, EditorMaterialsCls.surface_name(_paint.surf_id)]
		_paint_palette_row.visible = true
	else:
		_brush_label.text = ""


# ---- Placement -------------------------------------------------------

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
	if _grid_snap:
		pos = EditorPlacementCls.snap_to_grid(pos, _grid_step)
	var parent: Node = EditorMode.get_or_create_placed_container()
	if parent == null:
		return
	var node: Node3D = EditorPlacementCls.spawn_entry(entry, parent)
	if node == null:
		return
	node.global_position = pos
	if entry.get("kind", "") == "spawn" and "spawn_id" in node:
		node.spawn_id = "spawn_%d" % parent.get_child_count()
	EditorMode.dirty = true
	_push_place_action(node)
	_select_single(node)


func _push_place_action(node: Node3D) -> void:
	# Pack the node for the undo stack so we can restore it after delete.
	if node == null:
		return
	# For freshly placed nodes, just record the path so undo = queue_free.
	_undo.push({
		"type": "place",
		"target": _node_path_for(node),
	})


# ---- Picking + box-select -------------------------------------------

func _pick_or_box_start(mouse_pos: Vector2, additive: bool) -> void:
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var hit: Dictionary = EditorPlacementCls.raycast_from_mouse(cam, mouse_pos)
	if not hit.get("hit", false):
		# Empty space — start a box drag.
		_box_active = true
		_box_start = mouse_pos
		_box_select_rect.visible = true
		_box_select_rect.position = mouse_pos
		_box_select_rect.size = Vector2.ZERO
		return
	var collider = hit.get("collider", null)
	if collider == null:
		_clear_selection()
		return
	var node: Node3D = _resolve_select_ancestor(collider)
	if node == null:
		return
	if additive:
		if _selected.has(node):
			_deselect_one(node)
		else:
			_add_to_selection(node)
	else:
		_select_single(node)


func _update_box_select(p: Vector2) -> void:
	if not _box_active:
		return
	var x0: float = min(_box_start.x, p.x)
	var y0: float = min(_box_start.y, p.y)
	var x1: float = max(_box_start.x, p.x)
	var y1: float = max(_box_start.y, p.y)
	_box_select_rect.position = Vector2(x0, y0)
	_box_select_rect.size = Vector2(x1 - x0, y1 - y0)


func _finish_box_select(p: Vector2) -> void:
	_box_active = false
	_box_select_rect.visible = false
	var x0: float = min(_box_start.x, p.x)
	var y0: float = min(_box_start.y, p.y)
	var x1: float = max(_box_start.x, p.x)
	var y1: float = max(_box_start.y, p.y)
	var rect := Rect2(Vector2(x0, y0), Vector2(x1 - x0, y1 - y0))
	if rect.size.length() < 6:
		# Treat as miss-click; just clear if Ctrl not held.
		if not Input.is_key_pressed(KEY_CTRL):
			_clear_selection()
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var sc := get_tree().current_scene
	if sc == null:
		return
	var additive: bool = Input.is_key_pressed(KEY_CTRL)
	if not additive:
		_clear_selection()
	# Walk selectable nodes; project centers; test screen rect.
	for n in _selectable_nodes(sc):
		if n == null:
			continue
		var center: Vector3 = (n as Node3D).global_position
		if cam.is_position_behind(center):
			continue
		var sp: Vector2 = cam.unproject_position(center)
		if rect.has_point(sp):
			_add_to_selection(n as Node3D)


func _selectable_nodes(root: Node) -> Array:
	var out: Array = []
	var sc := get_tree().current_scene
	var placed: Node = sc.get_node_or_null("Placed") if sc else null
	for n in _walk(root):
		if not (n is Node3D):
			continue
		var nn: Node = n
		if nn.name == "EditorCamera":
			continue
		if nn == sc:
			continue
		# Heuristic: top-level children of scene root + Placed.
		var p: Node = nn.get_parent()
		if p == sc or p == placed:
			out.append(nn)
	return out


func _walk(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _resolve_select_ancestor(collider: Node) -> Node3D:
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


# ---- Selection management -------------------------------------------

func _select_single(node: Node3D) -> void:
	_clear_selection()
	_add_to_selection(node)


func _add_to_selection(node: Node3D) -> void:
	if node == null or _selected.has(node):
		return
	_selected.append(node)
	var o := _build_outline(node)
	_outlines.append(o)
	_inspector_ctrl.set_target_multi(_selected)
	_refresh_status()


func _deselect_one(node: Node3D) -> void:
	var i: int = _selected.find(node)
	if i < 0:
		return
	_selected.remove_at(i)
	if i < _outlines.size():
		var o = _outlines[i]
		if o and is_instance_valid(o):
			o.queue_free()
		_outlines.remove_at(i)
	_inspector_ctrl.set_target_multi(_selected)
	_refresh_status()


func _clear_selection() -> void:
	for o in _outlines:
		if o and is_instance_valid(o):
			o.queue_free()
	_outlines.clear()
	_selected.clear()
	if _inspector_ctrl:
		_inspector_ctrl.set_target(null)
	_refresh_status()


func get_selected() -> Node3D:
	# Back-compat for minimap.
	if _selected.is_empty():
		return null
	return _selected[0]


func get_selection_list() -> Array:
	return _selected


func _build_outline(node: Node3D) -> MeshInstance3D:
	var mi: MeshInstance3D = _first_mesh_instance(node)
	if mi == null:
		return null
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
	return ghost


func _first_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var found := _first_mesh_instance(c)
		if found:
			return found
	return null


# ---- Drag tools (multi-aware) ---------------------------------------

func _begin_drag(mouse_pos: Vector2) -> void:
	if _selected.is_empty():
		return
	_drag_active = true
	_drag_start_mouse = mouse_pos
	_drag_start_poses.clear()
	for n in _selected:
		var n3d: Node3D = n
		_drag_start_poses.append({
			"node": n3d,
			"pos": n3d.global_position,
			"rot": n3d.rotation,
			"scale": n3d.scale,
		})


func _end_drag() -> void:
	if not _drag_active:
		return
	_drag_active = false
	# Build undo entry: a multi-action of per-node transform snapshots.
	var subs: Array = []
	for entry in _drag_start_poses:
		var n: Node3D = entry["node"]
		if not is_instance_valid(n):
			continue
		var before: Dictionary = {
			"pos": entry["pos"],
			"rot": entry["rot"],
			"scale": entry["scale"],
		}
		var after: Dictionary = {
			"pos": n.global_position,
			"rot": n.rotation,
			"scale": n.scale,
		}
		subs.append({
			"type": "transform",
			"target": _node_path_for(n),
			"before": before,
			"after": after,
		})
	if not subs.is_empty():
		_undo.push({"type": "multi", "before": subs, "after": subs})
		EditorMode.dirty = true
	# Re-position outlines.
	for i in _selected.size():
		var o = _outlines[i] if i < _outlines.size() else null
		if o and is_instance_valid(o):
			(o as MeshInstance3D).global_transform = (_selected[i] as Node3D).global_transform


func _update_drag(mouse_pos: Vector2, rel: Vector2) -> void:
	if _selected.is_empty():
		return
	# Pivot = centroid of selection at drag start.
	var centroid := Vector3.ZERO
	for entry in _drag_start_poses:
		centroid += entry["pos"]
	if not _drag_start_poses.is_empty():
		centroid /= float(_drag_start_poses.size())
	match _tool:
		Tool.GRAB:
			var cam: Camera3D = _get_editor_camera()
			if cam == null:
				return
			if Input.is_key_pressed(KEY_SHIFT):
				var pixels: float = (_drag_start_mouse.y - mouse_pos.y) * 0.05
				var delta_y := Vector3(0, pixels, 0)
				for entry in _drag_start_poses:
					(entry["node"] as Node3D).global_position = entry["pos"] + delta_y
			else:
				var origin: Vector3 = cam.project_ray_origin(mouse_pos)
				var dir: Vector3 = cam.project_ray_normal(mouse_pos)
				if abs(dir.y) < 0.001:
					return
				var t: float = (centroid.y - origin.y) / dir.y
				if t < 0.0:
					return
				var hit_pos: Vector3 = origin + dir * t
				if _grid_snap:
					hit_pos = EditorPlacementCls.snap_to_grid(hit_pos, _grid_step)
				var delta := hit_pos - centroid
				delta.y = 0
				for entry in _drag_start_poses:
					var sp: Vector3 = entry["pos"] + delta
					sp.y = entry["pos"].y
					(entry["node"] as Node3D).global_position = sp
		Tool.ROTATE:
			var dx: float = (mouse_pos.x - _drag_start_mouse.x) * 0.01
			var axis: Vector3 = Vector3.UP
			if Input.is_key_pressed(KEY_SHIFT):
				axis = Vector3.RIGHT
			elif Input.is_key_pressed(KEY_CTRL):
				axis = Vector3.FORWARD
			for entry in _drag_start_poses:
				var n: Node3D = entry["node"]
				if _selected.size() == 1:
					var er: Vector3 = entry["rot"]
					n.rotation = er + axis * dx
				else:
					# Rotate around centroid.
					var rel_pos: Vector3 = entry["pos"] - centroid
					rel_pos = rel_pos.rotated(axis, dx)
					n.global_position = centroid + rel_pos
					n.rotation = entry["rot"] + axis * dx
		Tool.SCALE:
			var dy: float = (_drag_start_mouse.y - mouse_pos.y) * 0.01
			var k: float = max(0.05, 1.0 + dy)
			for entry in _drag_start_poses:
				var n: Node3D = entry["node"]
				n.scale = entry["scale"] * k
	# Keep outlines glued.
	for i in _selected.size():
		var o = _outlines[i] if i < _outlines.size() else null
		if o and is_instance_valid(o):
			(o as MeshInstance3D).global_transform = (_selected[i] as Node3D).global_transform


# ---- Hotkey actions -------------------------------------------------

func _delete_selected() -> void:
	if _selected.is_empty():
		return
	var subs: Array = []
	for n in _selected:
		var packed: PackedScene = EditorUndoCls.pack_for_delete(n)
		var parent: Node = n.get_parent()
		subs.append({
			"type": "delete",
			"target": _node_path_for(n),
			"packed": packed,
			"transform": (n as Node3D).transform,
			"name": n.name,
			"parent_path": _node_path_for(parent) if parent else ".",
		})
	_undo.push({"type": "multi", "before": subs, "after": subs})
	for n in _selected:
		n.queue_free()
	_clear_selection()
	EditorMode.dirty = true


func _duplicate_selected() -> void:
	if _selected.is_empty():
		return
	var clones: Array = []
	for n in _selected:
		var n3d: Node3D = n
		var clone: Node = n3d.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
		var parent: Node = n3d.get_parent()
		if parent == null:
			continue
		parent.add_child(clone)
		if clone is Node3D:
			(clone as Node3D).global_position = n3d.global_position + Vector3(1, 0, 1)
		clones.append(clone)
	_clear_selection()
	for c in clones:
		_add_to_selection(c)
		_push_place_action(c)
	EditorMode.dirty = true


func _copy_selection() -> void:
	_clipboard.copy(_selected)


func _paste_clipboard() -> void:
	if _clipboard.is_empty():
		return
	# Use cursor raycast (last known) or camera position.
	var cam: Camera3D = _get_editor_camera()
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var pos: Vector3 = cam.global_position
	if cam:
		var hit := EditorPlacementCls.raycast_from_mouse(cam, mouse_pos)
		pos = hit["position"]
	var parent: Node = EditorMode.get_or_create_placed_container()
	var pasted: Array = _clipboard.paste(parent, pos)
	_clear_selection()
	for n in pasted:
		if n is Node3D:
			_add_to_selection(n as Node3D)
			_push_place_action(n as Node3D)
	EditorMode.dirty = true


# ---- Group / ungroup ------------------------------------------------

func _group_selected() -> void:
	if _selected.size() < 2:
		return
	var parent: Node = EditorMode.get_or_create_placed_container()
	if parent == null:
		parent = get_tree().current_scene
	var group_root := Node3D.new()
	group_root.name = "Group"
	# Center on selection centroid.
	var c := Vector3.ZERO
	for n in _selected:
		c += (n as Node3D).global_position
	c /= float(_selected.size())
	parent.add_child(group_root)
	group_root.global_position = c
	for n in _selected.duplicate():
		var prev_xform: Transform3D = (n as Node3D).global_transform
		(n as Node3D).reparent(group_root)
		(n as Node3D).global_transform = prev_xform
	_clear_selection()
	_add_to_selection(group_root)
	EditorMode.dirty = true


func _ungroup_selected() -> void:
	if _selected.size() != 1:
		return
	var g: Node = _selected[0]
	if not (g is Node3D):
		return
	var parent: Node = g.get_parent()
	if parent == null:
		return
	var to_select: Array = []
	for c in g.get_children().duplicate():
		var cn: Node = c
		var prev_xform: Transform3D = (cn as Node3D).global_transform if cn is Node3D else Transform3D.IDENTITY
		cn.reparent(parent)
		if cn is Node3D:
			(cn as Node3D).global_transform = prev_xform
		to_select.append(cn)
	g.queue_free()
	_clear_selection()
	for c in to_select:
		if c is Node3D:
			_add_to_selection(c as Node3D)
	EditorMode.dirty = true


# ---- Undo / redo wiring ----------------------------------------------

func _undo_action() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	_undo.undo(sc)
	# Selection may have been modified; clear to be safe.
	_clear_selection()
	EditorMode.dirty = true


func _redo() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	_undo.redo(sc)
	_clear_selection()
	EditorMode.dirty = true


# ---- Bookmarks -------------------------------------------------------

func _save_bookmark(slot: int) -> void:
	if slot < 1 or slot > 9:
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null or not cam.has_method("capture_bookmark"):
		return
	_bookmarks[slot] = cam.capture_bookmark()
	if slot - 1 < _bookmark_buttons.size():
		(_bookmark_buttons[slot - 1] as Button).modulate = Color(1.2, 1.2, 0.6, 1)


func _jump_bookmark(slot: int) -> void:
	if slot < 1 or slot > 9:
		return
	var b: Dictionary = _bookmarks[slot]
	if b.is_empty():
		return
	var cam: Camera3D = _get_editor_camera()
	if cam and cam.has_method("apply_bookmark"):
		cam.apply_bookmark(b)


func _on_bookmark_click(slot: int) -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		_save_bookmark(slot)
	else:
		_jump_bookmark(slot)


# ---- Views -----------------------------------------------------------

func _apply_top_view() -> void:
	var cam: Camera3D = _get_editor_camera()
	if cam and cam.has_method("view_top"):
		cam.view_top()


# ---- Wireframe / bbox ------------------------------------------------

func _toggle_wireframe() -> void:
	_wireframe_on = not _wireframe_on
	_apply_wireframe_state()


func _apply_wireframe_state() -> void:
	# Per-viewport debug draw mode. Viewport.DEBUG_DRAW_WIREFRAME = 2.
	var vp := get_viewport()
	if vp == null:
		return
	if _wireframe_on:
		vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	else:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED


func _apply_wireframe_state_off() -> void:
	var vp := get_viewport()
	if vp:
		vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED


func _toggle_bbox() -> void:
	_bbox_on = not _bbox_on
	_clear_bbox_overlays()
	if not _bbox_on:
		return
	var sc := get_tree().current_scene
	if sc == null:
		return
	for n in _walk(sc):
		if not (n is CollisionShape3D):
			continue
		var cs: CollisionShape3D = n
		var ov := _shape_to_wireframe(cs)
		if ov:
			_bbox_overlays.append(ov)


func _clear_bbox_overlays() -> void:
	for o in _bbox_overlays:
		if o and is_instance_valid(o):
			o.queue_free()
	_bbox_overlays.clear()


func _shape_to_wireframe(cs: CollisionShape3D) -> MeshInstance3D:
	# Build a unshaded yellow box matching the shape's AABB.
	if cs.shape == null:
		return null
	var aabb: AABB = cs.shape.get_debug_mesh().get_aabb() if cs.shape.has_method("get_debug_mesh") else AABB(Vector3.ZERO, Vector3.ONE)
	# Fallback to standard shape extents.
	var size: Vector3 = aabb.size
	if cs.shape is BoxShape3D:
		size = (cs.shape as BoxShape3D).size
	elif cs.shape is SphereShape3D:
		var r: float = (cs.shape as SphereShape3D).radius
		size = Vector3(r * 2, r * 2, r * 2)
	elif cs.shape is CylinderShape3D:
		var c: CylinderShape3D = cs.shape
		size = Vector3(c.radius * 2, c.height, c.radius * 2)
	elif cs.shape is CapsuleShape3D:
		var cap: CapsuleShape3D = cs.shape
		size = Vector3(cap.radius * 2, cap.height, cap.radius * 2)
	var mi := MeshInstance3D.new()
	mi.top_level = true
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 0.2, 0.18)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	cs.add_child(mi)
	mi.global_transform = cs.global_transform
	return mi


# ---- Brush cursor preview ------------------------------------------

func _update_brush_cursor() -> void:
	if _tool != Tool.SCULPT and _tool != Tool.PAINT:
		if _brush_cursor and is_instance_valid(_brush_cursor):
			_brush_cursor.visible = false
		return
	if _selected.size() != 1 or not _selected[0].is_in_group("terrain_patch"):
		if _brush_cursor and is_instance_valid(_brush_cursor):
			_brush_cursor.visible = false
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var hit := EditorPlacementCls.raycast_from_mouse(cam, mouse_pos)
	var pos: Vector3 = hit["position"]
	if _tool == Tool.SCULPT:
		_sculpt.cursor_world = pos
	else:
		_paint.cursor_world = pos
	if _brush_cursor == null or not is_instance_valid(_brush_cursor):
		_brush_cursor = MeshInstance3D.new()
		_brush_cursor.top_level = true
		var tm := TorusMesh.new()
		_brush_cursor.mesh = tm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0.9, 0.2, 0.55)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_brush_cursor.material_override = mat
		var sc := get_tree().current_scene
		if sc:
			sc.add_child(_brush_cursor)
	var r: float = _sculpt.radius if _tool == Tool.SCULPT else _paint.radius
	var tm: TorusMesh = _brush_cursor.mesh
	tm.outer_radius = r
	tm.inner_radius = max(0.05, r - 0.15)
	_brush_cursor.global_position = pos + Vector3(0, 0.05, 0)
	_brush_cursor.visible = true


func _update_wall_preview() -> void:
	if _tool != Tool.WALL:
		return
	var cam: Camera3D = _get_editor_camera()
	if cam == null:
		return
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var hit := EditorPlacementCls.raycast_from_mouse(cam, mouse_pos)
	_wall.preview(hit["position"], get_tree().current_scene)


func _tick_active_brush(delta: float) -> void:
	if _sculpt.painting:
		_sculpt.tick(delta)
	if _paint.painting:
		_paint.tick()


func _on_paint_color_pick(sid: int) -> void:
	_paint.set_surface(sid)
	_refresh_brush_panel()


# ---- File dialogs ---------------------------------------------------

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


# ---- Palette ---------------------------------------------------------

func _on_palette_entry_selected(index: int) -> void:
	_selected_palette = index
	if index >= 0:
		_clear_selection()
		_set_tool(Tool.NONE)


# ---- + NEW LEVEL flow (preserved from previous version) -------------

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


# ---- helpers --------------------------------------------------------

func _get_editor_camera() -> Camera3D:
	var sc := get_tree().current_scene
	if sc == null:
		return null
	var n := sc.find_child("EditorCamera", true, false)
	return n as Camera3D


# Public — used by inspector's Delete button.
func delete_selected_external() -> void:
	_delete_selected()


# Snap-to-floor: raycast from selected node down to ground, set Y to hit+0.05.
func snap_selected_to_floor() -> void:
	if _selected.is_empty():
		return
	for n in _selected:
		var n3d: Node3D = n
		var world := n3d.get_world_3d()
		if world == null:
			continue
		var space := world.direct_space_state
		var from: Vector3 = n3d.global_position + Vector3(0, 1.5, 0)
		var to: Vector3 = from + Vector3.DOWN * 200.0
		var params := PhysicsRayQueryParameters3D.create(from, to)
		params.collision_mask = 1
		# Exclude self from raycast.
		var exclude: Array = []
		for c in n3d.get_children():
			if c is CollisionObject3D:
				exclude.append((c as CollisionObject3D).get_rid())
		if n3d is CollisionObject3D:
			exclude.append((n3d as CollisionObject3D).get_rid())
		params.exclude = exclude
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			continue
		n3d.global_position = Vector3(n3d.global_position.x,
				float(hit["position"].y) + 0.05,
				n3d.global_position.z)
	EditorMode.dirty = true


func _mouse_on_ui(pos: Vector2) -> bool:
	var panels := [_palette, _inspector, _minimap, _toolbar, _topbar, _brush_panel, _wall_panel]
	for p in panels:
		if p == null or not p.visible:
			continue
		if _mouse_on_panel(p, pos):
			return true
	return false


func _mouse_on_panel(panel: Control, pos: Vector2) -> bool:
	if panel == null:
		return false
	var rect := Rect2(panel.global_position, panel.size)
	return rect.has_point(pos)


# NodePath relative to the scene root, for the undo stack.
func _node_path_for(n: Node) -> String:
	var sc := get_tree().current_scene
	if sc == null or n == null:
		return ""
	return String(sc.get_path_to(n))
