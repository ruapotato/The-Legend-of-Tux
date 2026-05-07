extends CanvasLayer

# Pause overlay. Esc toggles pause + visibility. While paused the menu
# offers Resume and Quit to Title. process_mode = ALWAYS so the menu
# itself keeps running; everything else in the scene tree pauses.

@export var menu_scene: String = "res://scenes/main_menu.tscn"

var _root: Control
var _was_mouse_captured: bool = false


func _ready() -> void:
    layer = 80
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    _root.visible = false


func _input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_cancel"):
        get_viewport().set_input_as_handled()
        if _root.visible:
            _resume()
        else:
            _pause()


func _pause() -> void:
    _root.visible = true
    get_tree().paused = true
    _was_mouse_captured = (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resume() -> void:
    _root.visible = false
    get_tree().paused = false
    if _was_mouse_captured:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_quit_to_title() -> void:
    get_tree().paused = false
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().change_scene_to_file(menu_scene)


func _build_ui() -> void:
    _root = Control.new()
    _root.anchor_right = 1.0
    _root.anchor_bottom = 1.0
    _root.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_root)

    var dim := ColorRect.new()
    dim.color = Color(0, 0, 0, 0.6)
    dim.anchor_right = 1.0
    dim.anchor_bottom = 1.0
    _root.add_child(dim)

    var center := CenterContainer.new()
    center.anchor_right = 1.0
    center.anchor_bottom = 1.0
    _root.add_child(center)

    var box := VBoxContainer.new()
    box.alignment = BoxContainer.ALIGNMENT_CENTER
    box.add_theme_constant_override("separation", 14)
    center.add_child(box)

    var title := Label.new()
    title.text = "Paused"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 42)
    title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78, 1))
    box.add_child(title)

    var spacer := Control.new()
    spacer.custom_minimum_size = Vector2(0, 16)
    box.add_child(spacer)

    var resume := Button.new()
    resume.text = "Resume"
    resume.custom_minimum_size = Vector2(240, 40)
    resume.add_theme_font_size_override("font_size", 18)
    resume.pressed.connect(_resume)
    box.add_child(resume)

    var quit := Button.new()
    quit.text = "Quit to Title"
    quit.custom_minimum_size = Vector2(240, 40)
    quit.add_theme_font_size_override("font_size", 18)
    quit.pressed.connect(_on_quit_to_title)
    box.add_child(quit)
