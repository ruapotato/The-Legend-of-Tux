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
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("npc_talk_blip")
    # Terminal-corner narration. NPC dialog lines are pushed as
    # OUTPUT (yellow) rather than commands — they read as the
    # echo'd response rather than something Tux ran. We truncate to
    # a sensible width so a long monologue doesn't blow out the
    # 320px corner panel; the player still has the dialog box itself
    # for the full text.
    _push_dialog_output_line(_label.text)

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
        if node.has("learns_song"):
            var sid := String(node["learns_song"])
            if sid != "" and GameState.has_method("learn_song"):
                GameState.learn_song(sid)
                paid = true
        if node.has("sets_flag"):
            var qf := String(node["sets_flag"])
            if qf != "" and GameState.has_method("set_flag"):
                GameState.set_flag(qf, true)
                paid = true
        if paid:
            _given[node_id] = true

    # Build choices if any are visible (after `requires` filtering).
    _clear_choices()
    var choices: Array = node.get("choices", [])
    var visible_choices: Array = []
    # Track the first hidden gate so we can synthesize a "Permission
    # denied" fallback when EVERY choice filters out — otherwise the
    # dialog would dead-end with no way to advance (v2.5 reframe).
    var first_hidden_hint: String = ""
    for c in choices:
        if typeof(c) != TYPE_DICTIONARY:
            continue
        if c.has("requires"):
            var key := String(c["requires"])
            if key != "" and not GameState.inventory.has(key):
                if first_hidden_hint == "":
                    first_hidden_hint = "item:%s" % key
                continue
        if c.has("requires_not"):
            var nkey := String(c["requires_not"])
            if nkey != "" and GameState.inventory.has(nkey):
                continue
        if c.has("requires_flag"):
            var rf := String(c["requires_flag"])
            if rf != "" and not GameState.has_flag(rf):
                if first_hidden_hint == "":
                    first_hidden_hint = _perm_hint_for_flag(rf)
                continue
        if c.has("requires_flag_not"):
            var rfn := String(c["requires_flag_not"])
            if rfn != "" and GameState.has_flag(rfn):
                continue
        if c.has("requires_song"):
            var rs := String(c["requires_song"])
            if rs != "" and not GameState.has_song(rs):
                if first_hidden_hint == "":
                    first_hidden_hint = "song:%s" % rs
                continue
        visible_choices.append(c)

    # If the node DECLARED choices but every one of them filtered out,
    # synthesize a single "Permission denied" continue-line so the
    # player isn't stranded on a node with no way forward. The fallback
    # advances via `next` (or ends the conversation) just like a
    # normal continue node would.
    if choices.size() > 0 and visible_choices.size() == 0 and first_hidden_hint != "":
        _label.text = "%s\n(Permission denied — needs %s.)" % [
            String(node.get("text", "")), first_hidden_hint,
        ]

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
    # Sword upgrade hook (run first so a failed cost check can short-
    # circuit before any sets/sets_flag side-effects fire).
    # `upgrades_sword: N` (with optional `costs_pebbles`) advances the
    # sword tier exactly once per choice. Three gates apply:
    #   1. The player must be at tier N-1 (otherwise the upgrade either
    #      already happened or is being skipped over — both no-ops).
    #   2. If `costs_pebbles` is set, the player must have enough; the
    #      cost is deducted before the upgrade fires.
    #   3. Optional `fails_to: <node_id>` reroutes the dialog when the
    #      cost can't be paid (e.g. "you can't afford that"). If absent
    #      the choice silently no-ops on failure and proceeds to `next`.
    if ch.has("upgrades_sword"):
        var want_tier := int(ch["upgrades_sword"])
        var eligible: bool = (want_tier == GameState.sword_tier + 1)
        if eligible and ch.has("costs_pebbles"):
            var cost := int(ch["costs_pebbles"])
            if not GameState.spend_pebbles(cost):
                # Couldn't pay — abort the choice entirely. We do NOT
                # apply sets / sets_flag / learns_song here; the player
                # gets to try again.
                var fail_to := String(ch.get("fails_to", ""))
                if fail_to != "":
                    _goto(fail_to)
                else:
                    _next_in_queue()
                return
        if eligible:
            GameState.upgrade_sword(want_tier)
    if ch.has("sets"):
        var flag := String(ch["sets"])
        if flag != "":
            GameState.inventory[flag] = true
    if ch.has("sets_flag"):
        var qf := String(ch["sets_flag"])
        if qf != "":
            GameState.set_flag(qf, true)
    if ch.has("learns_song"):
        var sid := String(ch["learns_song"])
        if sid != "":
            GameState.learn_song(sid)
    # `opens_shop`: end the conversation and hand off to Shop.open. The
    # ware list is taken straight from the choice; the speaker is looked
    # up on the current node (so the shop heading reads "Shop — <NPC>").
    # Either form is allowed:
    #   {"opens_shop": ["heart","arrow","bomb"]}            # ids only
    #   {"opens_shop": [{"label":"Cake","price":99,         # inline
    #                    "effect":"heart"}]}
    if ch.has("opens_shop"):
        var wares: Variant = ch["opens_shop"]
        if typeof(wares) == TYPE_ARRAY:
            var nodes_dict: Dictionary = _tree.get("nodes", {})
            var cur_node: Dictionary = nodes_dict.get(_current_node, {})
            var speaker: String = String(ch.get("shop_speaker",
                cur_node.get("speaker", "")))
            # Terminal-corner narration. Per the lore table a shop
            # open is `apt list` — the package-manager metaphor for
            # browsing wares. Pushed BEFORE the conversation drain so
            # the corner reads "I asked for the catalog" right as the
            # shop overlay appears.
            var tl: Node = get_node_or_null("/root/TerminalLog")
            if tl:
                tl.cmd("apt list")
            # Drain this conversation before opening the shop so the
            # dialog box doesn't sit underneath the shop overlay.
            _next_in_queue()
            if get_tree().root.has_node("Shop"):
                Shop.open(speaker, wares as Array)
        return
    # `opens_minigame`: drain the conversation, then dispatch into the
    # named minigame autoload. Currently the only supported value is
    # "target_practice" (the Old Plays Sharpshooter range). The optional
    # `minigame_radius` choice field overrides the default ring size;
    # the start position falls back to the player position via the
    # `player` group lookup so the targets ring around the shooter.
    if ch.has("opens_minigame"):
        var game: String = String(ch["opens_minigame"])
        var radius: float = float(ch.get("minigame_radius", 12.0))
        _next_in_queue()
        if game == "target_practice":
            if get_tree().root.has_node("TargetPractice"):
                var origin: Vector3 = Vector3.ZERO
                var p: Node = get_tree().get_first_node_in_group("player")
                if p is Node3D:
                    origin = (p as Node3D).global_position
                TargetPractice.start(origin, radius)
        else:
            push_warning("dialog: unknown opens_minigame value '%s'" % game)
        return
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


# Map a `requires_flag` string into the same permission-bit hint that
# treasure_chest.gd surfaces, so dialog dead-end fallbacks read in the
# same vocabulary as chest refusals (v2.5 reframe). Unknown flags fall
# back to the bare flag name; trade-quest steps fall back to a softer
# "prior step" line.
func _perm_hint_for_flag(flag: String) -> String:
    var map := {
        "wyrdking_defeated":      "r:var",
        "codex_knight_defeated":  "w:etc",
        "gale_roost_defeated":    "x:bin/cd",
        "cinder_tomato_defeated": "x:bin/rm",
        "forge_wyrm_defeated":    "rwx:dev",
        "backwater_maw_defeated": "x:usr/bin/chroot",
        "censor_defeated":        "r:hidden",
        "triglyph_assembled":     "sudo",
    }
    if map.has(flag):
        return String(map[flag])
    if flag.begins_with("trade_step_"):
        return "prior step"
    return "flag:%s" % flag


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


# ---- Terminal-corner narration -----------------------------------------

# Push an NPC line as `echo "..." > /dev/tty` into the corner buffer.
# We send it as OUTPUT (yellow) rather than CMD because it reads as
# the shell's response, not as something Tux ran. Trims long lines to
# keep the 320px corner panel readable; the dialog box still has the
# full text. Skipped silently if the autoload isn't registered.
const _TERMINAL_OUTPUT_MAX: int = 48

func _push_dialog_output_line(text: String) -> void:
    var tl: Node = get_node_or_null("/root/TerminalLog")
    if tl == null:
        return
    var trimmed: String = text.replace("\n", " ").strip_edges()
    if trimmed == "":
        return
    if trimmed.length() > _TERMINAL_OUTPUT_MAX:
        trimmed = trimmed.substr(0, _TERMINAL_OUTPUT_MAX - 1) + "…"
    tl.output('echo "%s" > /dev/tty' % trimmed)
