extends CanvasLayer

# Autoloaded dialog/textbox manager. Anything that wants to show a
# blocking message just calls Dialog.show_message("..."). Multiple
# calls queue. The player controller checks Dialog.is_active() and
# zeros input while a message is open. Press the `interact` action
# (default E) to advance / dismiss.
#
# UI is built procedurally so we don't have to maintain a .tscn.

var _queue: Array = []
var _active: bool = false
var _panel: PanelContainer
var _label: Label
var _prompt: Label


func _ready() -> void:
    layer = 50
    visible = false

    _panel = PanelContainer.new()
    _panel.anchor_left = 0.05
    _panel.anchor_right = 0.95
    _panel.anchor_top = 0.70
    _panel.anchor_bottom = 0.95
    _panel.modulate = Color(1, 1, 1, 0.96)
    add_child(_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 20)
    margin.add_theme_constant_override("margin_right", 20)
    margin.add_theme_constant_override("margin_top", 14)
    margin.add_theme_constant_override("margin_bottom", 14)
    _panel.add_child(margin)

    var vbox := VBoxContainer.new()
    margin.add_child(vbox)

    _label = Label.new()
    _label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _label.add_theme_font_size_override("font_size", 18)
    _label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 1))
    vbox.add_child(_label)

    _prompt = Label.new()
    _prompt.text = "[E] continue"
    _prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _prompt.add_theme_font_size_override("font_size", 12)
    _prompt.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75, 1))
    vbox.add_child(_prompt)


func show_message(text: String) -> void:
    _queue.append(text)
    if not _active:
        _next()


func show_messages(texts: Array) -> void:
    _queue.append_array(texts)
    if not _active:
        _next()


func is_active() -> bool:
    return _active


func _next() -> void:
    if _queue.is_empty():
        _active = false
        visible = false
        return
    _active = true
    visible = true
    _label.text = _queue.pop_front()


func _unhandled_input(event: InputEvent) -> void:
    if not _active:
        return
    if event.is_action_pressed("interact") or event.is_action_pressed("attack"):
        get_viewport().set_input_as_handled()
        _next()
