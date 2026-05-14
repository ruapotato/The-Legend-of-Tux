extends Control

# Title-screen menu. Procedurally builds the UI so we don't have to
# author and maintain a tscn for the buttons; the only scene we need
# is the parent that hosts this script.
#
# The slot picker shows three save rows. Each row carries Load (if a
# save exists) and New (always). New initializes a fresh GameState,
# writes the slot, then loads it so the player drops straight into
# Wyrdkin Glade with the slot bound for autosave.

const NUM_SLOTS: int = 3
const START_SCENE_ID: String = "world_disc"

@export var sandbox_path: String = "res://scenes/combat_arena.tscn"
@export var editor_path: String = "res://scenes/world_disc.tscn"

var _title: Label
var _subtitle: Label
var _slots_box: VBoxContainer
var _confirm_dialog: ConfirmationDialog
var _pending_delete_slot: int = -1
var _ip_field: LineEdit


func _ready() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    anchor_right = 1.0
    anchor_bottom = 1.0

    var bg := ColorRect.new()
    bg.color = Color(0.06, 0.07, 0.10, 1)
    bg.anchor_right = 1.0
    bg.anchor_bottom = 1.0
    add_child(bg)

    var center := CenterContainer.new()
    center.anchor_right = 1.0
    center.anchor_bottom = 1.0
    add_child(center)

    var box := VBoxContainer.new()
    box.alignment = BoxContainer.ALIGNMENT_CENTER
    box.add_theme_constant_override("separation", 12)
    center.add_child(box)

    _title = Label.new()
    _title.text = "The Legend of Tux"
    _title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _title.add_theme_font_size_override("font_size", 56)
    _title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1))
    box.add_child(_title)

    _subtitle = Label.new()
    _subtitle.text = "the courage to share"
    _subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _subtitle.add_theme_font_size_override("font_size", 18)
    _subtitle.add_theme_color_override("font_color", Color(0.65, 0.65, 0.55, 1))
    box.add_child(_subtitle)

    var spacer := Control.new()
    spacer.custom_minimum_size = Vector2(0, 16)
    box.add_child(spacer)

    _slots_box = VBoxContainer.new()
    _slots_box.add_theme_constant_override("separation", 6)
    box.add_child(_slots_box)
    _rebuild_slots()

    var spacer2 := Control.new()
    spacer2.custom_minimum_size = Vector2(0, 16)
    box.add_child(spacer2)

    box.add_child(_make_button("Combat Sandbox", _on_sandbox))

    # Multiplayer MVP — bare-bones IP/port row + Host/Join buttons.
    # Host listens on NetManager.DEFAULT_PORT and drops into the
    # procedural world; Join connects to whatever's in the IP field
    # and then loads the same scene as a client. Disconnected =
    # single-player, so leaving the network state alone here keeps
    # the existing slot-picker flow working exactly as before.
    var net_spacer := Control.new()
    net_spacer.custom_minimum_size = Vector2(0, 12)
    box.add_child(net_spacer)
    box.add_child(_build_network_row())

    box.add_child(_make_button("Quit",           _on_quit))

    _confirm_dialog = ConfirmationDialog.new()
    _confirm_dialog.dialog_text = "Delete this save? This cannot be undone."
    _confirm_dialog.confirmed.connect(_on_delete_confirmed)
    add_child(_confirm_dialog)


func _rebuild_slots() -> void:
    for child in _slots_box.get_children():
        child.queue_free()
    for slot in range(NUM_SLOTS):
        _slots_box.add_child(_build_slot_row(slot))


func _build_slot_row(slot: int) -> Control:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)

    var summary: Dictionary = GameState.save_summary(slot)
    var label_text: String
    if summary.get("exists", false):
        var scene_id := String(summary.get("scene", "?"))
        var pebbles := int(summary.get("pebbles", 0))
        label_text = "Slot %d  -  %s  -  %d pebbles" % [slot + 1, scene_id, pebbles]
    else:
        label_text = "Slot %d  -  Empty" % (slot + 1)

    var lbl := Label.new()
    lbl.text = label_text
    lbl.custom_minimum_size = Vector2(360, 36)
    lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    lbl.add_theme_font_size_override("font_size", 18)
    lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.86, 1))
    row.add_child(lbl)

    if summary.get("exists", false):
        row.add_child(_make_small_button("Load", func(): _on_load(slot)))
        row.add_child(_make_small_button("Delete", func(): _on_delete(slot)))
    row.add_child(_make_small_button("New", func(): _on_new(slot)))

    return row


func _make_button(label: String, on_pressed: Callable) -> Button:
    var b := Button.new()
    b.text = label
    b.custom_minimum_size = Vector2(280, 40)
    b.add_theme_font_size_override("font_size", 20)
    b.pressed.connect(on_pressed)
    return b


func _make_small_button(label: String, on_pressed: Callable) -> Button:
    var b := Button.new()
    b.text = label
    b.custom_minimum_size = Vector2(80, 36)
    b.add_theme_font_size_override("font_size", 16)
    b.pressed.connect(on_pressed)
    return b


# ---- Slot actions -------------------------------------------------------

func _on_new(slot: int) -> void:
    GameState.reset()
    GameState.current_spawn_id = "default"
    GameState.next_spawn_id = "default"
    GameState.last_slot = slot
    # Snapshot the fresh state pointing at Wyrdkin Glade. We don't yet
    # have the scene loaded so we write the JSON directly with the
    # known scene id, then change the scene.
    var data: Dictionary = {
        "version": GameState.SAVE_VERSION,
        "hp": GameState.hp,
        "max_fish": GameState.max_fish,
        "stamina": GameState.stamina,
        "pebbles": GameState.pebbles,
        "keys": GameState.keys,
        "inventory": GameState.inventory.duplicate(true),
        "active_b_item": GameState.active_b_item,
        "current_scene_id": START_SCENE_ID,
        "current_spawn_id": "default",
    }
    var f := FileAccess.open("user://save_%d.json" % slot, FileAccess.WRITE)
    if f != null:
        f.store_string(JSON.stringify(data, "  "))
        f.close()
    # New game goes straight into the procedural world — the intro
    # cutscene is retired for now (will revisit when there's a real
    # narrative pass). Loaded saves already bypass this path.
    GameState.show_intro = false
    get_tree().change_scene_to_file("res://scenes/world_disc.tscn")


func _on_load(slot: int) -> void:
    GameState.last_slot = slot
    if not GameState.load_game(slot):
        push_warning("Failed to load slot %d" % slot)
        GameState.last_slot = -1


func _on_delete(slot: int) -> void:
    _pending_delete_slot = slot
    _confirm_dialog.popup_centered()


func _on_delete_confirmed() -> void:
    if _pending_delete_slot < 0:
        return
    GameState.delete_save(_pending_delete_slot)
    _pending_delete_slot = -1
    _rebuild_slots()


# ---- Other modes --------------------------------------------------------

func _on_sandbox() -> void:
    GameState.last_slot = -1
    get_tree().change_scene_to_file(sandbox_path)


func _on_editor() -> void:
    GameState.last_slot = -1
    # Land directly in edit mode — the integrated editor lives inside
    # every level scene, so we just deep-flag it before the scene swap.
    var em: Node = get_node_or_null("/root/EditorMode")
    if em:
        em.set("_pending_edit_on_load", true)
    get_tree().change_scene_to_file(editor_path)


func _on_quit() -> void:
    get_tree().quit()


# ---- Network MVP --------------------------------------------------------

func _build_network_row() -> Control:
    # Two-line block: a labelled IP field on top, Host + Join buttons
    # below. Kept narrow so it tucks neatly under the main mode
    # buttons without dominating the screen.
    var col := VBoxContainer.new()
    col.add_theme_constant_override("separation", 6)

    var ip_row := HBoxContainer.new()
    ip_row.add_theme_constant_override("separation", 6)

    var ip_lbl := Label.new()
    ip_lbl.text = "Host IP:Port"
    ip_lbl.custom_minimum_size = Vector2(110, 32)
    ip_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    ip_lbl.add_theme_font_size_override("font_size", 16)
    ip_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.78, 1))
    ip_row.add_child(ip_lbl)

    _ip_field = LineEdit.new()
    _ip_field.text = "127.0.0.1:%d" % NetManager.DEFAULT_PORT
    _ip_field.custom_minimum_size = Vector2(220, 32)
    _ip_field.placeholder_text = "127.0.0.1:%d" % NetManager.DEFAULT_PORT
    ip_row.add_child(_ip_field)
    col.add_child(ip_row)

    var btn_row := HBoxContainer.new()
    btn_row.add_theme_constant_override("separation", 8)
    btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
    btn_row.add_child(_make_button("Host Game", _on_host))
    btn_row.add_child(_make_button("Join Game", _on_join))
    col.add_child(btn_row)

    return col


func _on_host() -> void:
    # Slot binding off — multiplayer doesn't save to a slot in MVP.
    # GameState defaults are fine; the procedural world is fully
    # determined by WorldGen.world_seed.
    GameState.last_slot = -1
    if not NetManager.host(NetManager.DEFAULT_PORT):
        push_warning("Host failed")
        return
    GameState.show_intro = false
    get_tree().change_scene_to_file("res://scenes/world_disc.tscn")


func _on_join() -> void:
    var parsed: Dictionary = _parse_endpoint(_ip_field.text)
    var ip: String = parsed.get("ip", "127.0.0.1")
    var port: int = int(parsed.get("port", NetManager.DEFAULT_PORT))
    GameState.last_slot = -1
    if not NetManager.join(ip, port):
        push_warning("Join failed")
        return
    GameState.show_intro = false
    get_tree().change_scene_to_file("res://scenes/world_disc.tscn")


# "127.0.0.1:24847" → {ip, port}. Tolerates a bare hostname (uses
# the default port) and trims whitespace. Doesn't validate further —
# ENet will surface a connect error if the address is bogus.
func _parse_endpoint(s: String) -> Dictionary:
    var trimmed := s.strip_edges()
    if trimmed == "":
        return {"ip": "127.0.0.1", "port": NetManager.DEFAULT_PORT}
    var colon := trimmed.rfind(":")
    if colon < 0:
        return {"ip": trimmed, "port": NetManager.DEFAULT_PORT}
    var ip := trimmed.substr(0, colon)
    var port_s := trimmed.substr(colon + 1)
    var port := port_s.to_int() if port_s.is_valid_int() else NetManager.DEFAULT_PORT
    if port <= 0 or port > 65535:
        port = NetManager.DEFAULT_PORT
    return {"ip": ip, "port": port}
