extends Control

# Title-screen menu. Procedurally builds the UI so we don't have to
# author and maintain a tscn for the buttons; the only scene we need
# is the parent that hosts this script.

@export var dungeon_path: String = "res://scenes/dungeon_first.tscn"
@export var sandbox_path: String = "res://scenes/combat_arena.tscn"

var _title: Label
var _subtitle: Label


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
    box.add_theme_constant_override("separation", 14)
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
    spacer.custom_minimum_size = Vector2(0, 24)
    box.add_child(spacer)

    box.add_child(_make_button("Enter the Dungeon",  _on_play))
    box.add_child(_make_button("Combat Sandbox",     _on_sandbox))
    box.add_child(_make_button("Quit",               _on_quit))


func _make_button(label: String, on_pressed: Callable) -> Button:
    var b := Button.new()
    b.text = label
    b.custom_minimum_size = Vector2(280, 44)
    b.add_theme_font_size_override("font_size", 20)
    b.pressed.connect(on_pressed)
    return b


func _on_play() -> void:
    get_tree().change_scene_to_file(dungeon_path)


func _on_sandbox() -> void:
    get_tree().change_scene_to_file(sandbox_path)


func _on_quit() -> void:
    get_tree().quit()
