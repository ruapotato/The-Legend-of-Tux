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
const START_SCENE_ID: String = "wyrdkin_glade"

@export var sandbox_path: String = "res://scenes/combat_arena.tscn"
@export var editor_path: String = "res://scenes/editor.tscn"

var _title: Label
var _subtitle: Label
var _slots_box: VBoxContainer
var _confirm_dialog: ConfirmationDialog
var _pending_delete_slot: int = -1


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
    box.add_child(_make_button("Level Editor",   _on_editor))
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
    # New-game only: route through the opening cutscene. The intro scene
    # reads `show_intro`, plays its storyboard, then hops to the start
    # scene. Loaded saves bypass this entirely (they go through
    # _on_load → GameState.load_game → change_scene_to_file).
    GameState.show_intro = true
    get_tree().change_scene_to_file("res://scenes/intro.tscn")


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
    get_tree().change_scene_to_file(editor_path)


func _on_quit() -> void:
    get_tree().quit()
