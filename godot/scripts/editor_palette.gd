extends PanelContainer

# Bottom strip with 16 visible palette slots. Catalog comes in pre-built
# from editor_placement.gd; Q/E or the mouse wheel scrolls; clicking a
# slot or pressing 1-9 emits `entry_selected(catalog_index)`. The
# parent editor_ui.gd wires that into placement.

signal entry_selected(catalog_index: int)

const VISIBLE_SLOTS: int = 16

var catalog: Array = []                 # full catalog (all categories)
var current_category: String = "Geometry"
var scroll_offset: int = 0
var selected_index: int = -1            # absolute index into `catalog`

var _tabs: HBoxContainer = null
var _slots_row: HBoxContainer = null
var _slot_buttons: Array = []           # array of Button (16)


func _ready() -> void:
	# Build static layout once; updated entries hot-swap their text/colour.
	custom_minimum_size = Vector2(0, 100)
	var vbox := VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	add_child(vbox)

	_tabs = HBoxContainer.new()
	vbox.add_child(_tabs)

	_slots_row = HBoxContainer.new()
	_slots_row.add_theme_constant_override("separation", 2)
	vbox.add_child(_slots_row)

	for i in VISIBLE_SLOTS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(60, 60)
		b.text = ""
		b.toggle_mode = true
		b.pressed.connect(_on_slot_pressed.bind(i))
		_slots_row.add_child(b)
		_slot_buttons.append(b)


func set_catalog(c: Array) -> void:
	catalog = c
	_rebuild_tabs()
	_refresh_slots()


func _rebuild_tabs() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	var seen: Dictionary = {}
	var cats: Array = []
	for e in catalog:
		var name := String(e.get("category", "?"))
		if not seen.has(name):
			seen[name] = true
			cats.append(name)
	for cat in cats:
		var b := Button.new()
		b.text = cat
		b.toggle_mode = true
		if cat == current_category:
			b.button_pressed = true
		b.pressed.connect(_on_tab_pressed.bind(cat))
		_tabs.add_child(b)


func _on_tab_pressed(cat: String) -> void:
	current_category = cat
	scroll_offset = 0
	_rebuild_tabs()
	_refresh_slots()


func _entries_for_current() -> Array:
	var out: Array = []
	for e in catalog:
		if String(e.get("category", "")) == current_category:
			out.append(e)
	return out


func get_visible_entries() -> Array:
	# Returns the entries currently rendered as slot buttons. Used by
	# the parent UI for 1-9 keyboard select.
	var es: Array = _entries_for_current()
	var out: Array = []
	for i in VISIBLE_SLOTS:
		var idx: int = scroll_offset + i
		if idx >= es.size():
			break
		out.append(es[idx])
	return out


func _refresh_slots() -> void:
	var es: Array = _entries_for_current()
	for i in VISIBLE_SLOTS:
		var b: Button = _slot_buttons[i]
		var idx: int = scroll_offset + i
		if idx >= es.size():
			b.text = ""
			b.disabled = true
			b.button_pressed = false
			b.modulate = Color(0.6, 0.6, 0.6, 0.4)
			continue
		var e: Dictionary = es[idx]
		b.text = String(e.get("label", "?"))
		b.disabled = false
		b.modulate = Color(1, 1, 1, 1)
		# Highlight if this slot's absolute catalog index is selected.
		var abs_idx: int = _abs_index_for(e)
		b.button_pressed = (abs_idx == selected_index)
		if abs_idx == selected_index:
			b.modulate = Color(1.2, 1.05, 0.55, 1)


func _abs_index_for(entry: Dictionary) -> int:
	# Find the entry's index in the master catalog. Linear scan — fine,
	# catalog is short.
	for i in catalog.size():
		if catalog[i] == entry:
			return i
	return -1


func _on_slot_pressed(slot_idx: int) -> void:
	var es: Array = _entries_for_current()
	var idx: int = scroll_offset + slot_idx
	if idx >= es.size():
		return
	var abs_idx: int = _abs_index_for(es[idx])
	select_index(abs_idx)


func select_index(abs_idx: int) -> void:
	# Toggle off if re-selected.
	if abs_idx == selected_index:
		selected_index = -1
	else:
		selected_index = abs_idx
	_refresh_slots()
	entry_selected.emit(selected_index)


func scroll(direction: int) -> void:
	var es: Array = _entries_for_current()
	var max_off: int = max(0, es.size() - VISIBLE_SLOTS)
	scroll_offset = clamp(scroll_offset + direction, 0, max_off)
	_refresh_slots()
