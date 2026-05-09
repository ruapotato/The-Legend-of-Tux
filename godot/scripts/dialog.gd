extends CanvasLayer

# Autoloaded dialog/textbox manager. Two surface APIs:
#
#   Dialog.show_message("...")
#       Single, blocking message — the original sign/chest API.
#       Internally a one-node tree. Multiple calls queue.
#
#   Dialog.show_tree({...})
#       Branching dialog graph. See `show_tree` below for schema.
#       Used by NPCs.
#
# In both cases the player controller checks Dialog.is_active() and
# zeros input while a message is open. Press the `interact` action
# (default E) — or click the choice button / press number key 1-4 —
# to advance.
#
# UI is built procedurally so we don't have to maintain a .tscn.

# Queue of pending presentations. Each entry is {"tree": ..., "node": id_or_null}
var _queue: Array = []
var _active: bool = false

# Live tree state.
var _tree: Dictionary = {}
var _current_node: String = ""
# Per-tree memory of which nodes already paid out their `give_item` so a
# repeat conversation doesn't re-grant the item.
var _given: Dictionary = {}

var _panel: PanelContainer
var _speaker_label: Label
var _label: Label
var _choices_box: VBoxContainer
var _prompt: Label
var _choice_buttons: Array = []   # array of Button — kept so number-key input can press them


func _ready() -> void:
    layer = 50
    visible = false

    _panel = PanelContainer.new()
    _panel.anchor_left = 0.05
    _panel.anchor_right = 0.95
    _panel.anchor_top = 0.62
    _panel.anchor_bottom = 0.97
    _panel.modulate = Color(1, 1, 1, 0.96)
    add_child(_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 20)
    margin.add_theme_constant_override("margin_right", 20)
    margin.add_theme_constant_override("margin_top", 12)
    margin.add_theme_constant_override("margin_bottom", 12)
    _panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 6)
    margin.add_child(vbox)

    _speaker_label = Label.new()
    _speaker_label.add_theme_font_size_override("font_size", 16)
    _speaker_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.55, 1))
    _speaker_label.visible = false
    vbox.add_child(_speaker_label)

    _label = Label.new()
    _label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _label.add_theme_font_size_override("font_size", 18)
    _label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 1))
    vbox.add_child(_label)

    _choices_box = VBoxContainer.new()
    _choices_box.add_theme_constant_override("separation", 2)
    vbox.add_child(_choices_box)

    _prompt = Label.new()
    _prompt.text = "[E] continue"
    _prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    _prompt.add_theme_font_size_override("font_size", 12)
    _prompt.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75, 1))
    vbox.add_child(_prompt)


# ---- public API --------------------------------------------------------

# Backwards-compatible single-line API for signs/chests.
func show_message(text: String) -> void:
    show_tree({
        "start": "msg",
        "nodes": {
            "msg": {"text": text},
        },
    })


# Convenience for callers that want to queue several messages back-to-back.
func show_messages(texts: Array) -> void:
    for t in texts:
        show_message(String(t))


# Show a branching dialog tree. Schema:
#
#   {
#     "start": "node_id",
#     "nodes": {
#       "node_id": {
#         "text": "what the NPC says",
#         "speaker": "Hearthold Elder",
#         "choices": [
#           {"label": "Tell me about the Source.",
#            "next": "source_node",
#            "requires": "<inventory_key>",     # optional gate
#            "sets":     "<flag>"               # optional flag write
#           },
#           ...
#         ],
#         "next": "auto_next_node",   # optional auto-advance
#         "give_item": "<item_name>"  # optional, calls GameState.acquire_item
#       },
#       ...
#     }
#   }
#
# Walks the graph until it lands on a node with no `choices` and no
# `next`, then closes. `requires` filters choices via GameState.inventory.
# `sets` writes a flag (true) into GameState.inventory so subsequent
# dialog can branch on it. `give_item` calls GameState.acquire_item; the
# per-tree visited set ensures it only fires once per conversation.
func show_tree(tree: Dictionary) -> void:
    _queue.append(tree)
    if not _active:
        _next_in_queue()


func is_active() -> bool:
    return _active


# ---- internals ---------------------------------------------------------

func _next_in_queue() -> void:
    if _queue.is_empty():
        _active = false
        visible = false
        _tree = {}
        _current_node = ""
        _given.clear()
        _clear_choices()
        return
    _active = true
    visible = true
    _tree = _queue.pop_front()
    _given.clear()
    var start := String(_tree.get("start", ""))
    _goto(start)


func _goto(node_id: String) -> void:
    _current_node = node_id
    var nodes_dict: Dictionary = _tree.get("nodes", {})
    if not nodes_dict.has(node_id):
        # Fell off the graph. End the conversation.
        _next_in_queue()
        return
    var node: Dictionary = nodes_dict[node_id]

    # Speaker line.
    var spk := String(node.get("speaker", ""))
    if spk == "":
        _speaker_label.visible = false
    else:
        _speaker_label.text = spk
        _speaker_label.visible = true

    _label.text = String(node.get("text", ""))

    # Optional give_item / give_pebbles — fire once per visit per tree.
    if not _given.get(node_id, false):
        var paid := false
        if node.has("give_item"):
            var item_name := String(node["give_item"])
            if item_name != "" and GameState.has_method("acquire_item"):
                GameState.acquire_item(item_name)
                paid = true
        if node.has("give_pebbles"):
            var n := int(node["give_pebbles"])
            if n > 0 and GameState.has_method("add_pebbles"):
                GameState.add_pebbles(n)
                paid = true
        if paid:
            _given[node_id] = true

    # Build choices if any are visible (after `requires` filtering).
    _clear_choices()
    var choices: Array = node.get("choices", [])
    var visible_choices: Array = []
    for c in choices:
        if typeof(c) != TYPE_DICTIONARY:
            continue
        if c.has("requires"):
            var key := String(c["requires"])
            if key != "" and not GameState.inventory.has(key):
                continue
        if c.has("requires_not"):
            var nkey := String(c["requires_not"])
            if nkey != "" and GameState.inventory.has(nkey):
                continue
        visible_choices.append(c)

    if visible_choices.size() > 0:
        _prompt.text = "[1-%d] choose" % visible_choices.size()
        for i in range(visible_choices.size()):
            var ch: Dictionary = visible_choices[i]
            var btn := Button.new()
            btn.text = "%d. %s" % [i + 1, String(ch.get("label", "..."))]
            btn.add_theme_font_size_override("font_size", 16)
            btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
            btn.focus_mode = Control.FOCUS_NONE
            var captured := ch
            btn.pressed.connect(func(): _take_choice(captured))
            _choices_box.add_child(btn)
            _choice_buttons.append(btn)
    else:
        _prompt.text = "[E] continue"


func _clear_choices() -> void:
    for btn in _choice_buttons:
        if is_instance_valid(btn):
            btn.queue_free()
    _choice_buttons.clear()


func _take_choice(ch: Dictionary) -> void:
    if ch.has("sets"):
        var flag := String(ch["sets"])
        if flag != "":
            GameState.inventory[flag] = true
    var nxt := String(ch.get("next", ""))
    if nxt == "":
        _next_in_queue()
    else:
        _goto(nxt)


func _advance_no_choices() -> void:
    var nodes_dict: Dictionary = _tree.get("nodes", {})
    var node: Dictionary = nodes_dict.get(_current_node, {})
    var nxt := String(node.get("next", ""))
    if nxt == "":
        _next_in_queue()
    else:
        _goto(nxt)


func _unhandled_input(event: InputEvent) -> void:
    if not _active:
        return
    # Number keys select choices when present.
    if _choice_buttons.size() > 0:
        if event is InputEventKey and event.pressed and not event.echo:
            var k: int = event.keycode
            var idx := -1
            if k >= KEY_1 and k <= KEY_9:
                idx = k - KEY_1
            elif k >= KEY_KP_1 and k <= KEY_KP_9:
                idx = k - KEY_KP_1
            if idx >= 0 and idx < _choice_buttons.size():
                get_viewport().set_input_as_handled()
                _choice_buttons[idx].pressed.emit()
                return
        return
    # No choices — interact/attack advances.
    if event.is_action_pressed("interact") or event.is_action_pressed("attack"):
        get_viewport().set_input_as_handled()
        _advance_no_choices()
