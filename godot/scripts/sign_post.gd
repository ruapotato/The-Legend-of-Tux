extends Area3D

# Wooden sign you can read by walking up and pressing E. Holds a single
# message; chains multiple by separating with double-newlines and
# Dialog will queue them across advances if you call show_messages
# instead. Kept single-line for now since most signs are one-and-done.

@export_multiline var message: String = "A weathered wooden sign."
@export var hint_label: String = "[E] Read"

var _player_inside: bool = false
var _hint: Label


func _ready() -> void:
    add_to_group("ground_snap")
    collision_layer = 64
    collision_mask = 2
    monitoring = true
    body_entered.connect(_on_enter)
    body_exited.connect(_on_exit)

    # Build a small floating prompt so the player knows interact is
    # available without us authoring a scene tree of UI.
    _hint = Label.new()
    _hint.text = hint_label
    _hint.add_theme_font_size_override("font_size", 14)
    _hint.add_theme_color_override("font_outline_color", Color.BLACK)
    _hint.add_theme_constant_override("outline_size", 4)
    _hint.visible = false
    _hint.position = Vector2(-30, 10)
    _hint.size = Vector2(60, 20)
    _hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

    var label3d := Label3D.new()
    label3d.text = hint_label
    label3d.font_size = 32
    label3d.outline_size = 8
    label3d.modulate = Color(1, 1, 1, 1)
    label3d.position = Vector3(0, 1.5, 0)
    label3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label3d.no_depth_test = true
    label3d.visible = false
    label3d.name = "Hint"
    add_child(label3d)


func _on_enter(body: Node) -> void:
    if body.is_in_group("player"):
        _player_inside = true
        var h := get_node_or_null("Hint")
        if h:
            h.visible = true


func _on_exit(body: Node) -> void:
    if body.is_in_group("player"):
        _player_inside = false
        var h := get_node_or_null("Hint")
        if h:
            h.visible = false


func _unhandled_input(event: InputEvent) -> void:
    if not _player_inside:
        return
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        Dialog.show_message(message)
