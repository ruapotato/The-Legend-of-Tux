extends CanvasLayer

# World-disc pause menu. Esc toggles. Owns the mouse-capture state
# while open so the player can actually use the cursor; on close, the
# mouse re-captures so the orbit camera works again.
#
# Tabs:
#   Resume   — closes the menu.
#   Inventory — Minecraft/Valheim-style grid of resource slots with
#               procedural color+glyph icons, plus a key-items strip and
#               a craft panel that lists every Recipes.RECIPES entry.
#   Quit     — returns to main_menu.
#
# Lives as a CanvasLayer in world_disc.tscn at a high layer so it
# draws over the rest of the HUD.

# Display name + procedural icon for each known resource id. The icon is
# a flat ColorRect with a single capital letter centered on it (drawn at
# runtime by _make_slot_icon — no asset files). Unknown ids fall back to
# a neutral grey "?" slot.
const RESOURCE_DISPLAY: Dictionary = {
	"wood":        {"name": "Wood",        "color": Color(0.45, 0.30, 0.18, 1), "glyph": "W"},
	"stone":       {"name": "Stone",       "color": Color(0.55, 0.55, 0.58, 1), "glyph": "S"},
	"raspberry":   {"name": "Raspberry",   "color": Color(0.78, 0.18, 0.30, 1), "glyph": "R"},
	"mushroom":    {"name": "Mushroom",    "color": Color(0.78, 0.66, 0.50, 1), "glyph": "M"},
	"meat_raw":    {"name": "Raw Meat",    "color": Color(0.92, 0.55, 0.62, 1), "glyph": "m"},
	"cooked_meat": {"name": "Cooked Meat", "color": Color(0.50, 0.28, 0.18, 1), "glyph": "C"},
	"antler":      {"name": "Antler",      "color": Color(0.92, 0.88, 0.72, 1), "glyph": "A"},
	"flint":       {"name": "Flint",       "color": Color(0.38, 0.40, 0.42, 1), "glyph": "F"},
	"arrow":       {"name": "Arrow",       "color": Color(0.70, 0.60, 0.30, 1), "glyph": "a"},
}

const KEY_ITEMS: Array = [
	{"id": "sapling_blade", "name": "Sapling Blade",   "color": Color(0.55, 0.75, 0.40, 1), "glyph": "/"},
	{"id": "bark_round",    "name": "Bark Round",      "color": Color(0.55, 0.40, 0.25, 1), "glyph": "O"},
	{"id": "hammer",        "name": "Builder's Hammer","color": Color(0.65, 0.55, 0.40, 1), "glyph": "T"},
	{"id": "stone_axe",     "name": "Stone Axe",       "color": Color(0.60, 0.62, 0.66, 1), "glyph": "X"},
]

const GRID_COLS: int = 6
const GRID_ROWS: int = 4
const GRID_SLOTS: int = GRID_COLS * GRID_ROWS
const SLOT_SIZE: Vector2 = Vector2(56, 56)
const KEY_SLOT_SIZE: Vector2 = Vector2(48, 48)

var _root: Control = null
var _open: bool = false

# Inventory tab containers — populated/refreshed by _refresh_inventory.
# _key_items_box is typed as Container because the strip is a VBox at
# runtime; widening here keeps us from having to declare two fields.
var _grid: GridContainer = null
var _key_items_box: Container = null
var _craft_list: VBoxContainer = null

# Shared tooltip — one Label parented to _root, hidden by default. Each
# slot updates the text + position on mouse_entered.
var _tooltip: Panel = null
var _tooltip_label: Label = null


func _ready() -> void:
	layer = 95
	_build_layout()
	_close()
	set_process_input(true)
	# Auto-refresh on any resource / item change so a chest pickup mid-
	# pause (rare but possible via debug) or a successful craft updates
	# the slots without the player having to close+reopen the menu.
	if GameState:
		if GameState.has_signal("resource_changed") and not GameState.resource_changed.is_connected(_on_resource_changed):
			GameState.resource_changed.connect(_on_resource_changed)
		if GameState.has_signal("item_acquired") and not GameState.item_acquired.is_connected(_on_item_acquired):
			GameState.item_acquired.connect(_on_item_acquired)


func _build_layout() -> void:
	_root = Control.new()
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	_root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 600)
	center.add_child(panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.97)
	sb.border_color = Color(0.55, 0.40, 0.25, 1)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.95, 0.90, 0.70, 1))
	v.add_child(title)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	v.add_child(btn_row)

	var resume_btn := Button.new()
	resume_btn.text = "Resume  (Esc)"
	resume_btn.custom_minimum_size = Vector2(180, 36)
	resume_btn.pressed.connect(_close)
	btn_row.add_child(resume_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Quit to Main Menu"
	quit_btn.custom_minimum_size = Vector2(180, 36)
	quit_btn.pressed.connect(_on_quit)
	btn_row.add_child(quit_btn)

	v.add_child(HSeparator.new())

	# Inventory body: grid on the left, key-items column on the right.
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 18)
	v.add_child(body)

	# ---- LEFT: resource grid + craft panel ------------------------------
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	body.add_child(left)

	var grid_hdr := Label.new()
	grid_hdr.text = "RESOURCES"
	grid_hdr.add_theme_color_override("font_color", Color(0.80, 0.80, 0.60, 1))
	left.add_child(grid_hdr)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLS
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	left.add_child(_grid)

	left.add_child(HSeparator.new())

	var craft_hdr := Label.new()
	craft_hdr.text = "CRAFT"
	craft_hdr.add_theme_color_override("font_color", Color(0.80, 0.80, 0.60, 1))
	left.add_child(craft_hdr)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 200)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)

	_craft_list = VBoxContainer.new()
	_craft_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_craft_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_craft_list)

	# ---- RIGHT: key items strip ----------------------------------------
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	body.add_child(right)

	var items_hdr := Label.new()
	items_hdr.text = "KEY ITEMS"
	items_hdr.add_theme_color_override("font_color", Color(0.80, 0.80, 0.60, 1))
	right.add_child(items_hdr)

	# The key items live in a vertical strip (one slot per row + label)
	# so the column stays narrow next to the wider resource grid.
	# _refresh_key_items clears and repopulates this container.
	_key_items_box = VBoxContainer.new()
	_key_items_box.add_theme_constant_override("separation", 6)
	right.add_child(_key_items_box)

	# ---- shared tooltip overlay (top of _root, sits above everything) --
	_tooltip = Panel.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tip_sb := StyleBoxFlat.new()
	tip_sb.bg_color = Color(0.05, 0.05, 0.07, 0.97)
	tip_sb.border_color = Color(0.55, 0.40, 0.25, 1)
	tip_sb.set_border_width_all(1)
	tip_sb.content_margin_left = 6
	tip_sb.content_margin_right = 6
	tip_sb.content_margin_top = 3
	tip_sb.content_margin_bottom = 3
	_tooltip.add_theme_stylebox_override("panel", tip_sb)
	_tooltip_label = Label.new()
	_tooltip_label.add_theme_font_size_override("font_size", 12)
	_tooltip_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.80, 1))
	_tooltip.add_child(_tooltip_label)
	_root.add_child(_tooltip)


func _unhandled_input(event: InputEvent) -> void:
	# _unhandled_input (not _input) so other overlays that swallow
	# Esc via set_input_as_handled() — e.g. the world mini-map's
	# fullscreen view — can close themselves without us also opening
	# the pause menu on the same keypress.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if _open:
			_close()
		else:
			_open_menu()


func _open_menu() -> void:
	_open = true
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_inventory()
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS


func _close() -> void:
	_open = false
	_root.visible = false
	if _tooltip:
		_tooltip.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false


# Full repaint: clears + rebuilds the resource grid, key-items strip,
# and craft list. Called on open and whenever a relevant signal fires
# while the menu is visible.
func _refresh_inventory() -> void:
	_refresh_grid()
	_refresh_key_items()
	_refresh_craft_list()


func _refresh_grid() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()

	# Backstop: any resource id the player owns but that isn't in
	# slot_order yet (legacy save path, or an add_resource that missed
	# the append for some reason) gets appended now so it has a home.
	for k in GameState.resources.keys():
		var s := String(k)
		if int(GameState.resources[k]) > 0 and GameState.slot_order.find(s) == -1:
			GameState.slot_order.append(s)

	# Walk the persistent slot_order so the layout matches whatever the
	# player has arranged (or, for a fresh game, pickup order). Indexes
	# past slot_order.size() are filled with non-draggable padding slots
	# so the grid keeps its full 6×4 shape; draggable empty slots are
	# only the ones the player has actively freed up (id present in
	# slot_order but count 0 / missing from resources).
	for i in GRID_SLOTS:
		if i < GameState.slot_order.size():
			var id: String = String(GameState.slot_order[i])
			var count: int = int(GameState.resources.get(id, 0))
			if count > 0:
				_grid.add_child(_make_resource_slot(id, count, i))
			else:
				# Player-freed empty slot: draggable target so the player
				# can shuffle resources into it.
				_grid.add_child(_make_empty_slot(i, true))
		else:
			# Past the player's arranged region — show a flat empty slot
			# that also accepts drops so the player can extend the
			# layout into the unused area.
			_grid.add_child(_make_empty_slot(i, true))


func _refresh_key_items() -> void:
	if _key_items_box == null:
		return
	for c in _key_items_box.get_children():
		c.queue_free()
	for entry in KEY_ITEMS:
		var id: String = String(entry["id"])
		var owned: bool = bool(GameState.inventory.get(id, false))
		_key_items_box.add_child(_make_key_item_row(entry, owned))


func _refresh_craft_list() -> void:
	if _craft_list == null:
		return
	for c in _craft_list.get_children():
		c.queue_free()
	# One row per recipe, in RECIPES insertion order. Crafting is now
	# available from the pause menu regardless of nearby station — the
	# old workbench-only gate is gone for pause-menu crafting.
	for id in Recipes.RECIPES.keys():
		var r: Dictionary = Recipes.RECIPES[id]
		_craft_list.add_child(_make_recipe_row(String(id), r))


# ---- Slot factories ----------------------------------------------------

# A populated resource slot: colored panel + glyph letter + count in the
# bottom-right corner. Hover shows the tooltip; right-click eats if the
# resource is edible. Left-press-and-drag initiates a slot swap via the
# Control drag-drop API forwarded to this CanvasLayer.
func _make_resource_slot(id: String, count: int, slot_idx: int) -> Control:
	var info: Dictionary = RESOURCE_DISPLAY.get(id, {
		"name": id.capitalize().replace("_", " "),
		"color": Color(0.40, 0.40, 0.44, 1),
		"glyph": "?",
	})
	var slot := _make_slot_panel(info["color"], false)
	slot.custom_minimum_size = SLOT_SIZE
	slot.tooltip_text = ""  # we use our own tooltip overlay
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	# Slot-index metadata + drag-drop wiring. Forwarding to this script
	# keeps the per-slot Panel anonymous (no need for a separate script
	# resource per icon). The Callables receive (at_position, ...) and
	# the slot index / id are closed over via bind().
	slot.set_meta("slot_idx", slot_idx)
	slot.set_meta("item_id", id)
	slot.set_drag_forwarding(
		_slot_get_drag_data.bind(slot),
		_slot_can_drop_data.bind(slot),
		_slot_drop_data.bind(slot))

	var glyph := Label.new()
	glyph.text = String(info["glyph"])
	glyph.add_theme_font_size_override("font_size", 22)
	glyph.add_theme_color_override("font_color", Color(0.05, 0.05, 0.07, 1))
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.anchor_right = 1.0
	glyph.anchor_bottom = 1.0
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(glyph)

	var count_lbl := Label.new()
	count_lbl.text = str(count)
	count_lbl.add_theme_font_size_override("font_size", 12)
	count_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	# Drop shadow for legibility over busy colors.
	count_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	count_lbl.add_theme_constant_override("outline_size", 3)
	count_lbl.anchor_left = 1.0
	count_lbl.anchor_top = 1.0
	count_lbl.anchor_right = 1.0
	count_lbl.anchor_bottom = 1.0
	count_lbl.offset_left = -22
	count_lbl.offset_top = -16
	count_lbl.offset_right = -3
	count_lbl.offset_bottom = -2
	count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count_lbl)

	var tooltip_text: String = String(info["name"])
	if BuffManager and BuffManager.is_edible(id):
		tooltip_text += "  (Edible — right-click to eat)"
	slot.mouse_entered.connect(_on_slot_hover.bind(slot, tooltip_text))
	slot.mouse_exited.connect(_on_slot_unhover)
	slot.gui_input.connect(_on_resource_slot_input.bind(id))
	return slot


# An empty slot: just the dim panel, no glyph or count. Still hoverable
# (no-op) so the grid looks uniform. If `droppable` is true the slot also
# accepts a drop from another grid slot (used for player-arranged empty
# squares — drag-and-drop happily moves a resource into them).
func _make_empty_slot(slot_idx: int, droppable: bool) -> Control:
	var slot := _make_slot_panel(Color(0.18, 0.18, 0.20, 1), true)
	slot.custom_minimum_size = SLOT_SIZE
	# Empty slots need mouse pickup so drops can land on them. We still
	# don't draw any glyph or count so they read as "empty" visually.
	slot.mouse_filter = Control.MOUSE_FILTER_STOP if droppable else Control.MOUSE_FILTER_IGNORE
	if droppable:
		slot.set_meta("slot_idx", slot_idx)
		slot.set_meta("item_id", "")
		slot.set_drag_forwarding(
			Callable(),  # empty slots have nothing to drag
			_slot_can_drop_data.bind(slot),
			_slot_drop_data.bind(slot))
	return slot


# Returns a Panel styled as a 56×56 slot. `dim` muddies the border for
# empty slots so they read as inactive without disappearing.
func _make_slot_panel(fill_color: Color, dim: bool) -> Panel:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill_color
	sb.border_color = Color(0.25, 0.22, 0.18, 1) if dim else Color(0.55, 0.45, 0.30, 1)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	p.add_theme_stylebox_override("panel", sb)
	return p


# A key-item row: small glyph slot + label. Slot is bright when owned,
# dim when not. Hovering shows the full name in the tooltip.
func _make_key_item_row(entry: Dictionary, owned: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var color: Color = entry["color"] if owned else Color(0.18, 0.18, 0.20, 1)
	var slot := _make_slot_panel(color, not owned)
	slot.custom_minimum_size = KEY_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP

	var glyph := Label.new()
	glyph.text = String(entry["glyph"])
	glyph.add_theme_font_size_override("font_size", 22)
	glyph.add_theme_color_override("font_color",
			Color(0.05, 0.05, 0.07, 1) if owned else Color(0.35, 0.33, 0.30, 1))
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.anchor_right = 1.0
	glyph.anchor_bottom = 1.0
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(glyph)

	var tip: String = String(entry["name"]) + ("" if owned else "  (not yet crafted)")
	slot.mouse_entered.connect(_on_slot_hover.bind(slot, tip))
	slot.mouse_exited.connect(_on_slot_unhover)
	row.add_child(slot)

	var lbl := Label.new()
	lbl.text = String(entry["name"])
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color",
			Color(0.92, 0.95, 0.78, 1) if owned else Color(0.50, 0.50, 0.46, 1))
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)
	return row


# A craft recipe row: label + cost summary (with ✓/✗ markers) + Craft
# button. The button's disabled state mirrors GameState.has_resources;
# pressing it fires Recipes.craft(id) and refreshes everything.
func _make_recipe_row(id: String, r: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var costs: Dictionary = r.get("cost", {})
	var have_all: bool = GameState.has_resources(costs)

	# Already-owned key items still show but the button is disabled so
	# the player can't waste resources re-crafting a one-of-a-kind tool.
	var is_key_item: bool = bool(r.get("key_item", false))
	var already_owned: bool = is_key_item and bool(GameState.inventory.get(id, false))

	var name_lbl := Label.new()
	name_lbl.text = String(r.get("display", id))
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color",
			Color(0.65, 0.65, 0.55, 1) if already_owned else Color(0.92, 0.90, 0.78, 1))
	name_lbl.custom_minimum_size = Vector2(140, 0)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	# Cost summary, colorized per ingredient.
	var cost_box := HBoxContainer.new()
	cost_box.add_theme_constant_override("separation", 6)
	cost_box.custom_minimum_size = Vector2(220, 0)
	for k in costs.keys():
		var ing_id := String(k)
		var need: int = int(costs[k])
		var have: int = GameState.resource_count(ing_id)
		var ok: bool = have >= need
		var info: Dictionary = RESOURCE_DISPLAY.get(ing_id, {"name": ing_id})
		var ing_lbl := Label.new()
		ing_lbl.text = "%s %s×%d" % ["✓" if ok else "✗", String(info.get("name", ing_id)), need]
		ing_lbl.add_theme_font_size_override("font_size", 12)
		ing_lbl.add_theme_color_override("font_color",
				Color(0.65, 0.90, 0.55, 1) if ok else Color(0.90, 0.50, 0.45, 1))
		cost_box.add_child(ing_lbl)
	row.add_child(cost_box)

	var btn := Button.new()
	btn.text = "Owned" if already_owned else "Craft"
	btn.custom_minimum_size = Vector2(80, 28)
	btn.disabled = already_owned or not have_all
	btn.pressed.connect(_on_craft_pressed.bind(id))
	row.add_child(btn)
	return row


# ---- Drag and drop -----------------------------------------------------
#
# Slots use Godot's built-in Control drag-drop pipeline. The per-slot
# Panel forwards _get_drag_data / _can_drop_data / _drop_data to this
# CanvasLayer via set_drag_forwarding(), so all three live below. Drag
# data shape: {"slot_idx": int, "item_id": String}. On a successful
# drop we swap the two slot_order entries (or move into a free slot)
# and trigger a full refresh — Godot rebuilds the dragging source's
# alpha automatically once it releases, so we don't have to undim by
# hand if the user cancels.

func _slot_get_drag_data(_at_position: Vector2, slot: Control) -> Variant:
	if slot == null or not slot.has_meta("item_id"):
		return null
	var id: String = String(slot.get_meta("item_id"))
	# Empty source slots have nothing to drag; bail so Godot doesn't
	# spawn a hollow drag preview.
	if id == "":
		return null
	var idx: int = int(slot.get_meta("slot_idx"))
	# Visually dim the source while the drag is in flight. Godot
	# automatically clears modulate on the next layout pass when we
	# rebuild the grid in _slot_drop_data; on a cancelled drag the slot
	# never refreshes, so we tie the restore to mouse_exited / notify.
	slot.modulate = Color(1, 1, 1, 0.35)
	# set_drag_preview is a Control method — call it on the source slot
	# (we can't call it on this CanvasLayer). The preview is parented
	# automatically by Godot to its internal drag layer.
	slot.set_drag_preview(_make_drag_preview(id))
	return {"slot_idx": idx, "item_id": id}


func _slot_can_drop_data(_at_position: Vector2, data: Variant, slot: Control) -> bool:
	if slot == null or typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data as Dictionary
	if not d.has("slot_idx") or not d.has("item_id"):
		return false
	# Don't accept the slot dropping onto itself — it's a no-op and the
	# refresh churn is wasteful.
	if int(d["slot_idx"]) == int(slot.get_meta("slot_idx")):
		return false
	return true


func _slot_drop_data(_at_position: Vector2, data: Variant, slot: Control) -> void:
	if slot == null or typeof(data) != TYPE_DICTIONARY:
		return
	var src_idx: int = int((data as Dictionary).get("slot_idx", -1))
	var dst_idx: int = int(slot.get_meta("slot_idx"))
	_swap_slot_order(src_idx, dst_idx)
	_refresh_grid()


# Pad slot_order out to dst+1 if the drop target sits past the populated
# region (a fresh grid where slot_order only has 3 entries but the
# player drops onto index 10 — fill the gap with empty markers so the
# arrangement persists). Then swap the two indexes; either or both may
# point at an empty marker, in which case it's effectively a move.
func _swap_slot_order(a: int, b: int) -> void:
	if a == b or a < 0 or b < 0:
		return
	var need: int = max(a, b) + 1
	while GameState.slot_order.size() < need:
		GameState.slot_order.append("")
	var tmp: String = GameState.slot_order[a]
	GameState.slot_order[a] = GameState.slot_order[b]
	GameState.slot_order[b] = tmp


# Drag preview = a miniature copy of the source slot (color square +
# glyph), built fresh so the user sees what they're carrying without
# fighting Godot to clone the live Panel. The control returned here is
# parented under the drag layer automatically by set_drag_preview.
func _make_drag_preview(id: String) -> Control:
	var info: Dictionary = RESOURCE_DISPLAY.get(id, {
		"name": id.capitalize().replace("_", " "),
		"color": Color(0.40, 0.40, 0.44, 1),
		"glyph": "?",
	})
	var preview := _make_slot_panel(info["color"], false)
	preview.custom_minimum_size = SLOT_SIZE
	preview.size = SLOT_SIZE
	preview.modulate = Color(1, 1, 1, 0.85)
	# Re-center under the cursor — set_drag_preview anchors its child to
	# (0,0) of the cursor by default, which feels off for a 56px square.
	preview.position = -SLOT_SIZE * 0.5
	var glyph := Label.new()
	glyph.text = String(info["glyph"])
	glyph.add_theme_font_size_override("font_size", 22)
	glyph.add_theme_color_override("font_color", Color(0.05, 0.05, 0.07, 1))
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.anchor_right = 1.0
	glyph.anchor_bottom = 1.0
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_child(glyph)
	# Wrap in a Control so the negative offset above takes effect without
	# clipping; set_drag_preview accepts any Control.
	var wrap := Control.new()
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(preview)
	return wrap


# ---- Slot interactions -------------------------------------------------

func _on_resource_slot_input(event: InputEvent, id: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		# Selection placeholder — slots don't drag-and-drop yet, but a
		# click should still acknowledge the player. No state change.
		pass
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		if BuffManager and BuffManager.is_edible(id) and BuffManager.eat(id):
			if SoundBank:
				SoundBank.play_2d("pebble_get")
			_refresh_inventory()


func _on_slot_hover(slot: Control, text: String) -> void:
	if _tooltip == null or _tooltip_label == null:
		return
	_tooltip_label.text = text
	_tooltip.visible = true
	# Park the tooltip just above-right of the slot. Clamped to the
	# panel's bounds so it never spills off-screen.
	var slot_rect: Rect2 = slot.get_global_rect()
	var pos: Vector2 = slot_rect.position + Vector2(slot_rect.size.x + 6, 0)
	_tooltip.position = pos
	# Force a layout pass so the panel actually sizes around the label
	# before we (re)read its size — otherwise the first hover after open
	# misses the clamp.
	_tooltip.reset_size()


func _on_slot_unhover() -> void:
	if _tooltip:
		_tooltip.visible = false


# ---- Craft button ------------------------------------------------------

func _on_craft_pressed(id: String) -> void:
	if Recipes == null:
		return
	if Recipes.craft(id):
		if SoundBank:
			SoundBank.play_2d("pebble_get")
		_refresh_inventory()
	# Failed crafts (somehow ran out between paint and click) just leave
	# the row in place; the next refresh will mark the button disabled.


# ---- Signal handlers ---------------------------------------------------

func _on_resource_changed(_id: String, _new_count: int) -> void:
	if _open:
		_refresh_grid()
		_refresh_craft_list()


func _on_item_acquired(_item_name: String) -> void:
	if _open:
		_refresh_key_items()
		# Crafting a key item also marks it owned, so the craft list
		# needs a re-render to disable that row's button.
		_refresh_craft_list()


func _on_quit() -> void:
	# Autosave before leaving so inventory, destroyed props, and any
	# placed build pieces survive into the next session. Slot is
	# whatever main_menu opened/created via last_slot.
	if GameState and GameState.has_method("save_game") \
			and "last_slot" in GameState and GameState.last_slot >= 0:
		GameState.save_game(GameState.last_slot)
	_close()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
