extends ScrollContainer

# Inspector panel — shows the generic transform fields for the selected
# Node3D plus a smattering of type-specific editors. Supports multi-
# select: when more than one node is selected we show a small banner
# and operate transforms on all of them. Type-specific sections only
# appear when a single node is selected.
#
# Also exposes:
#   - Material picker (any MeshInstance3D descendant)
#   - Non-uniform scale toggle
#   - Snap-to-floor button
#
# Live-binds the selected node so any UI change writes back immediately
# and flips EditorMode.dirty. When the selection clears we hide the
# panel contents.

const EditorMaterialsCls = preload("res://scripts/editor_materials.gd")
const EditorHeightmapCanvasCls = preload("res://scripts/editor_heightmap_canvas.gd")

var _target: Node3D = null
var _targets: Array = []        # multi-select list (subset of selection)
var _owner_ui = null

var _vbox: VBoxContainer = null

# Generic widgets (rebuilt on each set_target).
var _name_edit: LineEdit = null
var _pos_x: SpinBox = null
var _pos_y: SpinBox = null
var _pos_z: SpinBox = null
var _rot_y: SpinBox = null
var _scale_box: SpinBox = null
var _scale_x: SpinBox = null
var _scale_y: SpinBox = null
var _scale_z: SpinBox = null
var _scale_uniform: bool = true


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 6)
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_vbox)
	set_target(null)


func set_owner_ui(ui) -> void:
	_owner_ui = ui


# Single-target entry point (back-compat). Also sets _targets.
func set_target(node: Node3D) -> void:
	if node == null:
		_targets = []
	else:
		_targets = [node]
	_target = node
	_rebuild_ui()


# Multi-target entry point.
func set_target_multi(nodes: Array) -> void:
	_targets = []
	for n in nodes:
		if n is Node3D:
			_targets.append(n)
	if _targets.is_empty():
		_target = null
	else:
		_target = _targets[0]
	_rebuild_ui()


func _rebuild_ui() -> void:
	for c in _vbox.get_children():
		c.queue_free()
	if _target == null:
		var l := Label.new()
		l.text = "(nothing selected)"
		l.modulate = Color(0.7, 0.7, 0.7, 1)
		_vbox.add_child(l)
		return
	if _targets.size() > 1:
		var banner := Label.new()
		banner.text = "(%d selected — common props)" % _targets.size()
		banner.modulate = Color(1, 0.8, 0.4, 1)
		_vbox.add_child(banner)
	_build_generic_section()
	if _targets.size() == 1:
		_build_typed_section()


# ---- Generic fields ---------------------------------------------------

func _build_generic_section() -> void:
	var hdr := Label.new()
	hdr.text = "Object: %s" % _target.name
	hdr.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(hdr)

	if _targets.size() == 1:
		_name_edit = LineEdit.new()
		_name_edit.text = _target.name
		_name_edit.text_changed.connect(_on_name_changed)
		_vbox.add_child(_row("Name", _name_edit))

	_pos_x = _spin(_target.position.x, -2000, 2000, 0.1)
	_pos_y = _spin(_target.position.y, -2000, 2000, 0.1)
	_pos_z = _spin(_target.position.z, -2000, 2000, 0.1)
	_pos_x.value_changed.connect(_on_pos_changed)
	_pos_y.value_changed.connect(_on_pos_changed)
	_pos_z.value_changed.connect(_on_pos_changed)
	var pos_row := HBoxContainer.new()
	pos_row.add_child(_pos_x); pos_row.add_child(_pos_y); pos_row.add_child(_pos_z)
	_vbox.add_child(_row("Pos XYZ", pos_row))

	_rot_y = _spin(rad_to_deg(_target.rotation.y), -360, 360, 1.0)
	_rot_y.value_changed.connect(_on_rot_changed)
	_vbox.add_child(_row("Rot Y°", _rot_y))

	# Uniform / non-uniform scale toggle.
	var scale_toggle := CheckBox.new()
	scale_toggle.text = "Non-uniform scale"
	scale_toggle.button_pressed = not _scale_uniform
	scale_toggle.toggled.connect(func(p):
		_scale_uniform = not p
		_rebuild_ui())
	_vbox.add_child(scale_toggle)

	if _scale_uniform:
		_scale_box = _spin(_target.scale.x, 0.05, 100.0, 0.05)
		_scale_box.value_changed.connect(_on_scale_changed)
		_vbox.add_child(_row("Scale", _scale_box))
	else:
		_scale_x = _spin(_target.scale.x, 0.05, 100.0, 0.05)
		_scale_y = _spin(_target.scale.y, 0.05, 100.0, 0.05)
		_scale_z = _spin(_target.scale.z, 0.05, 100.0, 0.05)
		_scale_x.value_changed.connect(_on_scale_xyz_changed)
		_scale_y.value_changed.connect(_on_scale_xyz_changed)
		_scale_z.value_changed.connect(_on_scale_xyz_changed)
		var sr := HBoxContainer.new()
		sr.add_child(_scale_x); sr.add_child(_scale_y); sr.add_child(_scale_z)
		_vbox.add_child(_row("Scale XYZ", sr))

	# Buttons row: Delete + Snap-to-floor.
	var br := HBoxContainer.new()
	var del := Button.new()
	del.text = "Delete"
	del.pressed.connect(_on_delete_pressed)
	br.add_child(del)
	var snap_btn := Button.new()
	snap_btn.text = "Snap-to-floor"
	snap_btn.pressed.connect(_on_snap_floor_pressed)
	br.add_child(snap_btn)
	_vbox.add_child(br)

	# Material picker for any node that has a descendant MeshInstance3D.
	var mi := _find_first_mesh_instance(_target)
	if mi:
		_build_material_picker(mi)

	_vbox.add_child(_hr())


func _build_typed_section() -> void:
	var hdr := Label.new()
	hdr.text = "Type-specific"
	hdr.modulate = Color(0.85, 0.85, 0.7, 1)
	hdr.add_theme_font_size_override("font_size", 13)
	_vbox.add_child(hdr)

	var s: Script = _target.get_script() as Script
	var sp: String = s.resource_path if s else ""

	if sp.ends_with("npc.gd") or _target.is_in_group("npc"):
		_build_npc_section()
	elif sp.ends_with("sign_post.gd"):
		_build_sign_section()
	elif sp.ends_with("treasure_chest.gd"):
		_build_chest_section()
	elif sp.ends_with("load_zone.gd") or _target.is_in_group("load_zone"):
		_build_load_zone_section()
	elif sp.ends_with("owl_statue.gd"):
		_build_owl_section()
	elif sp.ends_with("spawn_marker.gd") or _target.is_in_group("spawn_marker"):
		_build_spawn_marker_section()
	elif _target is DirectionalLight3D or _target is OmniLight3D \
			or _target is SpotLight3D:
		_build_light_section()
	elif sp.ends_with("water_volume.gd") or _target.is_in_group("water_volume"):
		_build_water_section()
	elif sp.ends_with("terrain_patch_edit.gd") or _target.is_in_group("terrain_patch"):
		_build_terrain_section()
	elif sp.ends_with("terrain_point_mesh.gd") or _target.is_in_group("terrain_point_mesh"):
		_build_terrain_point_mesh_section()
	elif _target is MeshInstance3D and _target.has_meta("mesh_id"):
		_build_mesh_section()
	else:
		var l := Label.new()
		l.text = "(no type-specific fields)"
		l.modulate = Color(0.6, 0.6, 0.6, 1)
		_vbox.add_child(l)


# ---- Generic handlers -------------------------------------------------

func _on_name_changed(new_name: String) -> void:
	if _target == null:
		return
	if new_name.length() > 0:
		_target.name = new_name
	EditorMode.dirty = true


func _on_pos_changed(_v: float) -> void:
	if _target == null:
		return
	# In multi-select, treat the inspector's pos as a delta from the
	# previously committed _target position and apply to all.
	var newp := Vector3(_pos_x.value, _pos_y.value, _pos_z.value)
	if _targets.size() > 1:
		var delta: Vector3 = newp - _target.position
		for n in _targets:
			(n as Node3D).position += delta
	else:
		_target.position = newp
	EditorMode.dirty = true


func _on_rot_changed(v: float) -> void:
	if _target == null:
		return
	for n in _targets:
		(n as Node3D).rotation.y = deg_to_rad(v)
	EditorMode.dirty = true


func _on_scale_changed(v: float) -> void:
	if _target == null:
		return
	for n in _targets:
		(n as Node3D).scale = Vector3(v, v, v)
	EditorMode.dirty = true


func _on_scale_xyz_changed(_v: float) -> void:
	if _target == null:
		return
	var s := Vector3(_scale_x.value, _scale_y.value, _scale_z.value)
	for n in _targets:
		(n as Node3D).scale = s
	EditorMode.dirty = true


func _on_delete_pressed() -> void:
	if _owner_ui:
		_owner_ui.delete_selected_external()


func _on_snap_floor_pressed() -> void:
	if _owner_ui and _owner_ui.has_method("snap_selected_to_floor"):
		_owner_ui.snap_selected_to_floor()
		_rebuild_ui()


# ---- Material picker --------------------------------------------------

func _build_material_picker(mi: MeshInstance3D) -> void:
	var hdr := Label.new()
	hdr.text = "Material"
	hdr.modulate = Color(0.85, 0.85, 0.7, 1)
	_vbox.add_child(hdr)
	var opt := OptionButton.new()
	for k in EditorMaterialsCls.KINDS:
		opt.add_item(k.capitalize())
	# Pre-select if we have a mat_kind meta.
	var current: String = String(mi.get_meta("mat_kind", "default"))
	for i in EditorMaterialsCls.KINDS.size():
		if EditorMaterialsCls.KINDS[i] == current:
			opt.select(i)
			break
	opt.item_selected.connect(func(idx):
		var kind: String = String(EditorMaterialsCls.KINDS[idx])
		mi.set_meta("mat_kind", kind)
		if kind == "default":
			mi.material_override = null
		elif kind == "custom_color":
			# Build a colored material from the picker's value.
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.8, 0.8, 0.8, 1)
			mi.material_override = m
		else:
			mi.material_override = EditorMaterialsCls.get_material(kind)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Preset", opt))

	# Optional color override (always visible — applies on top of preset).
	var cp := ColorPickerButton.new()
	var existing_color: Color = Color(0.8, 0.8, 0.8, 1)
	if mi.material_override is StandardMaterial3D:
		existing_color = (mi.material_override as StandardMaterial3D).albedo_color
	cp.color = existing_color
	cp.color_changed.connect(func(c):
		var m: StandardMaterial3D = mi.material_override as StandardMaterial3D
		if m == null:
			m = StandardMaterial3D.new()
			mi.material_override = m
		m.albedo_color = c
		mi.set_meta("mat_kind", "custom_color")
		EditorMode.dirty = true)
	_vbox.add_child(_row("Tint", cp))

	var reset := Button.new()
	reset.text = "Reset material"
	reset.pressed.connect(func():
		mi.material_override = null
		mi.remove_meta("mat_kind")
		EditorMode.dirty = true
		_rebuild_ui())
	_vbox.add_child(reset)


# ---- Type-specific builders ------------------------------------------

func _build_npc_section() -> void:
	var name_field := LineEdit.new()
	name_field.text = String(_target.get_meta("npc_name", _target.name))
	name_field.text_changed.connect(func(t):
		_target.set_meta("npc_name", t)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Name", name_field))

	var hint_field := LineEdit.new()
	hint_field.text = String(_target.get_meta("idle_hint", ""))
	hint_field.text_changed.connect(func(t):
		_target.set_meta("idle_hint", t)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Idle Hint", hint_field))

	var body_picker := ColorPickerButton.new()
	body_picker.color = _meta_color("body_color", Color(0.85, 0.78, 0.65, 1))
	body_picker.color_changed.connect(func(c):
		_target.set_meta("body_color", c)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Body Color", body_picker))

	var hat_picker := ColorPickerButton.new()
	hat_picker.color = _meta_color("hat_color", Color(0.42, 0.30, 0.20, 1))
	hat_picker.color_changed.connect(func(c):
		_target.set_meta("hat_color", c)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Hat Color", hat_picker))

	var dialog_edit := TextEdit.new()
	dialog_edit.custom_minimum_size = Vector2(0, 180)
	var tree = _target.get_meta("dialog_tree", null)
	if tree == null:
		dialog_edit.text = "{}"
	else:
		dialog_edit.text = JSON.stringify(tree, "  ")
	dialog_edit.text_changed.connect(func():
		var parsed: Variant = JSON.parse_string(dialog_edit.text)
		if parsed != null:
			_target.set_meta("dialog_tree", parsed)
		EditorMode.dirty = true)
	_vbox.add_child(Label.new())
	var dl := Label.new()
	dl.text = "Dialog tree (JSON)"
	_vbox.add_child(dl)
	_vbox.add_child(dialog_edit)


func _build_sign_section() -> void:
	var msg := TextEdit.new()
	msg.custom_minimum_size = Vector2(0, 120)
	msg.text = String(_target.get_meta("message", _get_export(_target, "message", "")))
	msg.text_changed.connect(func():
		var t := msg.text.substr(0, min(200, msg.text.length()))
		if "message" in _target:
			_target.message = t
		_target.set_meta("message", t)
		EditorMode.dirty = true)
	_vbox.add_child(Label.new())
	var dl := Label.new()
	dl.text = "Message (max 200)"
	_vbox.add_child(dl)
	_vbox.add_child(msg)


func _build_chest_section() -> void:
	var opt := OptionButton.new()
	var items := ["heart", "key", "boomerang", "bow", "slingshot", "hookshot",
			"hammer", "bombs", "fairy_bottle", "glim_sight", "anchor_boots",
			"glim_mirror", "pebble", "heart_piece", "heart_container"]
	for i in items.size():
		opt.add_item(items[i], i)
	var current := String(_target.get_meta("contents",
			_get_export(_target, "contents", "heart")))
	for i in items.size():
		if items[i] == current:
			opt.select(i)
			break
	opt.item_selected.connect(func(idx):
		var v: String = String(items[idx])
		if "contents" in _target:
			_target.contents = v
		_target.set_meta("contents", v)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Contents", opt))

	var req := LineEdit.new()
	req.text = String(_target.get_meta("requires_flag",
			_get_export(_target, "requires_flag", "")))
	req.text_changed.connect(func(t):
		if "requires_flag" in _target:
			_target.requires_flag = t
		_target.set_meta("requires_flag", t)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Requires Flag", req))

	var kg := LineEdit.new()
	kg.text = String(_target.get_meta("key_group",
			_get_export(_target, "key_group", "")))
	kg.text_changed.connect(func(t):
		if "key_group" in _target:
			_target.key_group = t
		_target.set_meta("key_group", t)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Key Group", kg))


func _build_load_zone_section() -> void:
	var tgt := LineEdit.new()
	tgt.text = String(_get_export(_target, "target_scene", ""))
	tgt.text_changed.connect(func(t):
		if "target_scene" in _target:
			_target.target_scene = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Target", tgt))

	var btn_row := HBoxContainer.new()
	var browse := Button.new()
	browse.text = "Browse..."
	browse.pressed.connect(func():
		var fd := FileDialog.new()
		fd.access = FileDialog.ACCESS_RESOURCES
		fd.filters = PackedStringArray(["*.tscn ; Scenes"])
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.current_dir = "res://scenes"
		fd.title = "Pick Target Scene"
		_owner_ui.add_child(fd)
		fd.file_selected.connect(func(p):
			tgt.text = p
			if "target_scene" in _target:
				_target.target_scene = p
			EditorMode.dirty = true
			fd.queue_free())
		fd.canceled.connect(func(): fd.queue_free())
		fd.popup_centered(Vector2(720, 520)))
	btn_row.add_child(browse)

	var new_btn := Button.new()
	new_btn.text = "+ NEW LEVEL"
	new_btn.pressed.connect(func():
		if _owner_ui:
			_owner_ui.prompt_new_level(_target))
	btn_row.add_child(new_btn)
	_vbox.add_child(btn_row)

	var spawn := LineEdit.new()
	spawn.text = String(_get_export(_target, "target_spawn", "default"))
	spawn.text_changed.connect(func(t):
		if "target_spawn" in _target:
			_target.target_spawn = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Spawn Id", spawn))

	var prompt := LineEdit.new()
	prompt.text = String(_get_export(_target, "prompt", "Travel"))
	prompt.text_changed.connect(func(t):
		if "prompt" in _target:
			_target.prompt = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Prompt", prompt))

	var auto := CheckBox.new()
	auto.text = "Auto-trigger"
	auto.button_pressed = bool(_get_export(_target, "auto_trigger", true))
	auto.toggled.connect(func(p):
		if "auto_trigger" in _target:
			_target.auto_trigger = p
		EditorMode.dirty = true)
	_vbox.add_child(auto)


func _build_owl_section() -> void:
	var warp_id := LineEdit.new()
	warp_id.text = String(_get_export(_target, "warp_id", ""))
	warp_id.text_changed.connect(func(t):
		if "warp_id" in _target:
			_target.warp_id = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Warp Id", warp_id))

	var warp_name := LineEdit.new()
	warp_name.text = String(_get_export(_target, "warp_name", ""))
	warp_name.text_changed.connect(func(t):
		if "warp_name" in _target:
			_target.warp_name = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Warp Name", warp_name))

	var warp_target := LineEdit.new()
	warp_target.text = String(_get_export(_target, "warp_target_scene", ""))
	warp_target.text_changed.connect(func(t):
		if "warp_target_scene" in _target:
			_target.warp_target_scene = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Warp Target", warp_target))


func _build_spawn_marker_section() -> void:
	var sp_id := LineEdit.new()
	sp_id.text = String(_target.get_meta("spawn_id",
			_get_export(_target, "spawn_id", _target.name)))
	sp_id.text_changed.connect(func(t):
		if "spawn_id" in _target:
			_target.spawn_id = t
		_target.set_meta("spawn_id", t)
		if t != "":
			_target.name = t
		EditorMode.dirty = true)
	_vbox.add_child(_row("Spawn Id", sp_id))


func _build_light_section() -> void:
	var col := ColorPickerButton.new()
	col.color = _target.light_color
	col.color_changed.connect(func(c):
		_target.light_color = c
		EditorMode.dirty = true)
	_vbox.add_child(_row("Color", col))

	var energy := SpinBox.new()
	energy.min_value = 0.0
	energy.max_value = 16.0
	energy.step = 0.1
	energy.value = _target.light_energy
	energy.value_changed.connect(func(v):
		_target.light_energy = v
		EditorMode.dirty = true)
	_vbox.add_child(_row("Energy", energy))

	if _target is OmniLight3D:
		var rng := SpinBox.new()
		rng.min_value = 0.5
		rng.max_value = 256.0
		rng.step = 0.5
		rng.value = (_target as OmniLight3D).omni_range
		rng.value_changed.connect(func(v):
			(_target as OmniLight3D).omni_range = v
			EditorMode.dirty = true)
		_vbox.add_child(_row("Range", rng))


func _build_water_section() -> void:
	var sy := SpinBox.new()
	sy.min_value = -100.0
	sy.max_value = 100.0
	sy.step = 0.1
	sy.value = float(_get_export(_target, "surface_y", 0.0))
	sy.value_changed.connect(func(v):
		if "surface_y" in _target:
			_target.surface_y = v
		_target.set_meta("surface_y", v)
		EditorMode.dirty = true)
	_vbox.add_child(_row("Surface Y", sy))


func _build_terrain_section() -> void:
	var gs := SpinBox.new()
	gs.min_value = 2
	gs.max_value = 128
	gs.step = 1
	gs.value = float(_get_export(_target, "grid_size", 32))
	gs.value_changed.connect(func(v):
		_target.grid_size = int(v)
		EditorMode.dirty = true
		# Rebuild the painter so the canvas matches the new grid size.
		_rebuild_ui())
	_vbox.add_child(_row("Grid size", gs))
	var cs := SpinBox.new()
	cs.min_value = 0.25
	cs.max_value = 8.0
	cs.step = 0.25
	cs.value = float(_get_export(_target, "cell_size", 2.0))
	cs.value_changed.connect(func(v):
		_target.cell_size = v
		EditorMode.dirty = true)
	_vbox.add_child(_row("Cell size m", cs))

	# Inline heightmap painter — LMB drag raises, RMB drag lowers, wheel
	# adjusts brush radius. Real-time mesh update.
	var painter_label := Label.new()
	painter_label.text = "Heightmap painter (LMB=up, RMB=down, wheel=size)"
	painter_label.modulate = Color(0.85, 0.85, 0.55, 1)
	_vbox.add_child(painter_label)
	var painter := EditorHeightmapCanvasCls.new()
	painter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(painter)
	painter.set_patch(_target)

	# Quick-action buttons.
	var br := HBoxContainer.new()
	var flat_btn := Button.new()
	flat_btn.text = "Flatten"
	flat_btn.pressed.connect(func():
		var sz: int = (int(_target.grid_size) + 1) * (int(_target.grid_size) + 1)
		var z := PackedFloat32Array()
		z.resize(sz)
		_target.set_heights(z)
		painter.set_patch(_target)
		EditorMode.dirty = true)
	br.add_child(flat_btn)
	_vbox.add_child(br)


func _build_terrain_point_mesh_section() -> void:
	# Single colour per mesh — the user mixes biomes by placing
	# multiple TerrainPointMeshes side-by-side.
	var cp := ColorPickerButton.new()
	var current: Color = Color(0.40, 0.55, 0.30, 1)
	if "terrain_color" in _target:
		current = _target.terrain_color
	cp.color = current
	cp.color_changed.connect(func(c):
		if "terrain_color" in _target:
			_target.terrain_color = c
		EditorMode.dirty = true)
	_vbox.add_child(_row("Color", cp))

	var pt_count: int = 0
	for c in _target.get_children():
		if c is Node3D and (c.is_in_group("terrain_point") or c.has_meta("is_terrain_point")):
			pt_count += 1
	var info := Label.new()
	info.text = "Points: %d  •  P to drop one at the camera" % pt_count
	info.modulate = Color(0.8, 0.8, 0.7, 1)
	_vbox.add_child(info)


func _build_mesh_section() -> void:
	var le := LineEdit.new()
	le.text = String(_target.get_meta("mesh_id", ""))
	le.editable = false
	_vbox.add_child(_row("Mesh Id", le))


# ---- Helpers ----------------------------------------------------------

func _find_first_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var f := _find_first_mesh_instance(c)
		if f:
			return f
	return null


func _row(label: String, child: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(96, 0)
	h.add_child(l)
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(child)
	return h


func _spin(value: float, lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(80, 0)
	return s


func _hr() -> HSeparator:
	return HSeparator.new()


func _meta_color(key: String, default: Color) -> Color:
	var v: Variant = _target.get_meta(key, null)
	if v is Color:
		return v
	return default


func _get_export(node: Node, prop: String, default: Variant) -> Variant:
	if node == null:
		return default
	if prop in node:
		return node.get(prop)
	return default
