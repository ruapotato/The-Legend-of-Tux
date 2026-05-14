extends Node

# In-game dev/admin console. Toggled with F5. Builds its own
# CanvasLayer + Panel + LineEdit + scrollback at runtime so no extra
# scene file is needed; the autoload alone is enough.
#
# Slash-prefix optional: `give wood 50` and `/give wood 50` are
# equivalent. Up/Down navigates the per-session history (50 entries).
# While open the game is paused, the mouse is visible, and Esc closes
# the console without falling through to the pause menu.
#
# Layout + command-loop UX inspired by the user's own AGPL project
# (hamberg/client/ui/debug_console.gd) — written fresh for Tux.

const HISTORY_MAX: int = 50
const CANVAS_LAYER: int = 100   # well above the pause menu (which sits at default)

var _layer: CanvasLayer
var _root: Control
var _panel: Panel
var _scroll: RichTextLabel
var _input: LineEdit

var _history: Array[String] = []
var _history_idx: int = -1     # -1 means "not browsing"
var _saved_mouse_mode: int = Input.MOUSE_MODE_VISIBLE
var _was_paused: bool = false
var _open: bool = false


func _ready() -> void:
	# Always-on so we can react to F5 / advance our UI while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_println("[color=#7fd3ff]Tux Dev Console[/color] — F5 to toggle, /help for commands.")


# --- UI construction --------------------------------------------------

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = CANVAS_LAYER
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)

	_root = Control.new()
	_root.name = "DevConsoleRoot"
	_root.process_mode = Node.PROCESS_MODE_ALWAYS
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	_layer.add_child(_root)

	_panel = Panel.new()
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_panel.anchor_left = 0.05
	_panel.anchor_top = 0.05
	_panel.anchor_right = 0.95
	_panel.anchor_bottom = 0.60
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.process_mode = Node.PROCESS_MODE_ALWAYS
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 10
	vbox.offset_top = 10
	vbox.offset_right = -10
	vbox.offset_bottom = -10
	_panel.add_child(vbox)

	var title: Label = Label.new()
	title.text = "Tux Dev Console (F5)"
	title.add_theme_color_override("font_color", Color(0.5, 0.83, 1.0))
	vbox.add_child(title)

	_scroll = RichTextLabel.new()
	_scroll.process_mode = Node.PROCESS_MODE_ALWAYS
	_scroll.bbcode_enabled = true
	_scroll.scroll_following = true
	_scroll.selection_enabled = true
	_scroll.focus_mode = Control.FOCUS_NONE
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_scroll)

	_input = LineEdit.new()
	_input.process_mode = Node.PROCESS_MODE_ALWAYS
	_input.placeholder_text = "Type a command... (try /help)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(_on_submit)
	_input.text_changed.connect(_on_text_changed)
	vbox.add_child(_input)


# --- Input ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.keycode
		if key == KEY_F5:
			toggle()
			get_viewport().set_input_as_handled()
			return
		if not _open:
			return
		if key == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
			return
		if key == KEY_UP:
			_history_prev()
			get_viewport().set_input_as_handled()
			return
		if key == KEY_DOWN:
			_history_next()
			get_viewport().set_input_as_handled()
			return


func _on_text_changed(_t: String) -> void:
	# Any free-form keystroke resets the history cursor so the next
	# Up doesn't surprise the user by jumping mid-edit.
	_history_idx = -1


# --- Open / close -----------------------------------------------------

func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open:
		return
	_open = true
	_saved_mouse_mode = Input.mouse_mode
	_was_paused = get_tree().paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true
	_root.visible = true
	_input.text = ""
	_input.grab_focus()


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	# Only thaw the tree if we were the ones who paused it. A pause menu
	# already running before F5 opened the console stays paused.
	if not _was_paused:
		get_tree().paused = false
	Input.mouse_mode = _saved_mouse_mode
	_history_idx = -1


# --- History ----------------------------------------------------------

func _push_history(line: String) -> void:
	if line.strip_edges() == "":
		return
	_history.push_front(line)
	if _history.size() > HISTORY_MAX:
		_history.resize(HISTORY_MAX)


func _history_prev() -> void:
	if _history.is_empty():
		return
	_history_idx = min(_history_idx + 1, _history.size() - 1)
	_input.text = _history[_history_idx]
	_input.caret_column = _input.text.length()


func _history_next() -> void:
	if _history_idx <= 0:
		_history_idx = -1
		_input.text = ""
		return
	_history_idx -= 1
	_input.text = _history[_history_idx]
	_input.caret_column = _input.text.length()


# --- Output -----------------------------------------------------------

func _println(line: String) -> void:
	_scroll.append_text(line + "\n")


func _ok(msg: String) -> void:
	_println("[color=#9fe09f]" + msg + "[/color]")


func _err(msg: String) -> void:
	_println("[color=#ff7676]" + msg + "[/color]")


func _info(msg: String) -> void:
	_println("[color=#cccccc]" + msg + "[/color]")


# --- Command dispatch -------------------------------------------------

func _on_submit(text: String) -> void:
	var raw: String = text.strip_edges()
	_input.text = ""
	_history_idx = -1
	# Re-grab focus so the player can fire successive commands without
	# closing and reopening the console. LineEdit drops focus when the
	# scrollback RichTextLabel receives BBCode and the panel relayouts.
	_input.call_deferred("grab_focus")
	if raw == "":
		return
	_push_history(raw)
	_println("[color=#888888]&gt; " + raw + "[/color]")

	# Slash prefix optional.
	if raw.begins_with("/"):
		raw = raw.substr(1)
	var parts: PackedStringArray = raw.split(" ", false)
	if parts.size() == 0:
		return
	var cmd: String = parts[0].to_lower()
	var args: Array = []
	for i in range(1, parts.size()):
		args.append(parts[i])

	match cmd:
		"give":     _cmd_give(args)
		"take":     _cmd_take(args)
		"grant":    _cmd_grant(args)
		"craft":    _cmd_craft(args)
		"weather":  _cmd_weather(args)
		"time":     _cmd_time(args)
		"tp":       _cmd_tp(args)
		"heal":     _cmd_heal(args)
		"hurt":     _cmd_hurt(args)
		"buff":     _cmd_buff(args)
		"clear":    _cmd_clear()
		"help", "?": _cmd_help()
		"list":     _cmd_list(args)
		_:
			_err("unknown command — try `help`")


# --- Commands ---------------------------------------------------------

func _cmd_give(args: Array) -> void:
	if args.size() < 1:
		_err("usage: give <resource_id> [count]")
		return
	var id: String = String(args[0])
	var n: int = _parse_int(args, 1, 1)
	if not (typeof(GameState) != TYPE_NIL and GameState.has_method("add_resource")):
		_err("GameState.add_resource unavailable")
		return
	GameState.add_resource(id, n)
	_ok("gave %d × %s (now %d)" % [n, id, _resource_count(id)])


func _cmd_take(args: Array) -> void:
	if args.size() < 1:
		_err("usage: take <resource_id> [count]")
		return
	var id: String = String(args[0])
	var n: int = _parse_int(args, 1, 1)
	if not GameState.has_method("consume_resource"):
		_err("GameState.consume_resource unavailable")
		return
	if GameState.consume_resource(id, n):
		_ok("took %d × %s (now %d)" % [n, id, _resource_count(id)])
	else:
		_err("not enough %s (have %d)" % [id, _resource_count(id)])


func _cmd_grant(args: Array) -> void:
	if args.size() < 1:
		_err("usage: grant <item_id>")
		return
	var id: String = String(args[0])
	# Prefer the canonical helper when available; fall back to a manual
	# inventory write + signal emit so the HUD still updates.
	if GameState.has_method("grant_item"):
		GameState.grant_item(id)
	elif GameState.has_method("acquire_item"):
		GameState.acquire_item(id)
	else:
		GameState.inventory[id] = true
		if GameState.has_signal("item_acquired"):
			GameState.emit_signal("item_acquired", id)
	_ok("granted item: %s" % id)


func _cmd_craft(args: Array) -> void:
	if args.size() < 1:
		_err("usage: craft <recipe_id>")
		return
	var id: String = String(args[0])
	if not (typeof(Recipes) != TYPE_NIL and Recipes.RECIPES.has(id)):
		_err("unknown recipe: %s" % id)
		return
	if Recipes.craft(id):
		_ok("crafted %s" % id)
	else:
		_err("craft failed (insufficient resources?)")


func _cmd_weather(args: Array) -> void:
	if args.size() < 1:
		_err("usage: weather <clear|rain|snow|storm>  (sun = clear)")
		return
	var name: String = String(args[0]).to_lower()
	# Casual aliases — "sun"/"sunny" reads naturally for "stop the rain".
	if name == "sun" or name == "sunny" or name == "fair":
		name = "clear"
	if not (typeof(Weather) != TYPE_NIL):
		_err("Weather autoload unavailable")
		return
	if Weather.has_method("force_state"):
		Weather.force_state(name)
		_ok("weather → %s" % name)
	else:
		_err("Weather.force_state not implemented")


func _cmd_time(args: Array) -> void:
	if args.size() < 1:
		_err("usage: time <0..1>")
		return
	var v: float = float(args[0])
	if not (typeof(TimeOfDay) != TYPE_NIL):
		_err("TimeOfDay autoload unavailable")
		return
	if TimeOfDay.has_method("set_time"):
		TimeOfDay.set_time(v)
	elif TimeOfDay.has_method("set_t"):
		TimeOfDay.set_t(v)
	else:
		TimeOfDay.t = clamp(v, 0.0, 1.0)
	_ok("time → %.3f" % clamp(v, 0.0, 1.0))


func _cmd_tp(args: Array) -> void:
	if args.size() < 2:
		_err("usage: tp <x> <y|_> <z>  (y optional: tp <x> <z>)")
		return
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null:
		_err("no player in group 'player'")
		return
	var cur: Vector3 = Vector3.ZERO
	if "global_position" in player:
		cur = player.global_position
	var pos: Vector3 = cur
	if args.size() == 2:
		# 2-arg form: x, z (keep current y).
		pos = Vector3(float(args[0]), cur.y, float(args[1]))
	else:
		pos = Vector3(float(args[0]), float(args[1]), float(args[2]))
	if "global_position" in player:
		player.global_position = pos
		_ok("teleported to %s" % pos)
	else:
		_err("player has no global_position")


func _cmd_heal(args: Array) -> void:
	var n: int = 0
	if args.size() >= 1 and String(args[0]).is_valid_int():
		n = int(args[0])
	else:
		# Default = top off to max.
		var max_hp: int = 999
		if "max_fish" in GameState and "HP_PER_FISH" in GameState:
			max_hp = int(GameState.max_fish) * int(GameState.HP_PER_FISH)
		n = max_hp
	if GameState.has_method("heal"):
		GameState.heal(n)
		_ok("healed %d" % n)
	else:
		_err("GameState.heal unavailable")


func _cmd_hurt(args: Array) -> void:
	if args.size() < 1:
		_err("usage: hurt <n>")
		return
	var n: int = int(args[0])
	if GameState.has_method("damage"):
		GameState.damage(n)
		_ok("damaged %d" % n)
	else:
		_err("GameState.damage unavailable")


func _cmd_buff(args: Array) -> void:
	if args.size() < 1:
		_err("usage: buff <id>")
		return
	var id: String = String(args[0])
	if not (typeof(BuffManager) != TYPE_NIL):
		_err("BuffManager autoload unavailable")
		return
	if not BuffManager.BUFF_DEFS.has(id):
		_err("unknown buff: %s (try: %s)" % [id, ", ".join(BuffManager.BUFF_DEFS.keys())])
		return
	BuffManager.apply_buff(id)
	_ok("applied buff: %s" % id)


func _cmd_clear() -> void:
	_scroll.clear()


func _cmd_help() -> void:
	_println("[color=#7fd3ff]commands[/color] (slash optional):")
	_info("  give <resource_id> [count]   — add stackable resource")
	_info("  take <resource_id> [count]   — consume stackable resource")
	_info("  grant <item_id>              — add inventory item (key item)")
	_info("  craft <recipe_id>            — run Recipes.craft")
	_info("  weather <clear|rain|snow|storm>")
	_info("  time <0..1>                  — set TimeOfDay.t")
	_info("  tp <x> <y> <z>               — teleport (or `tp x z` keeps y)")
	_info("  heal [n]                     — heal n (default = full)")
	_info("  hurt <n>                     — damage n")
	_info("  buff <id>                    — BuffManager.apply_buff")
	_info("  list <resources|items|recipes|buffs>")
	_info("  clear                        — clear scrollback")
	_info("  help                         — this list")


func _cmd_list(args: Array) -> void:
	if args.size() < 1:
		_err("usage: list <resources|items|recipes|buffs>")
		return
	var what: String = String(args[0]).to_lower()
	match what:
		"resources":
			var keys: Array = GameState.resources.keys() if "resources" in GameState else []
			if keys.is_empty():
				_info("(no resources held)")
				return
			for k in keys:
				_info("  %s × %d" % [String(k), int(GameState.resources[k])])
		"items":
			var inv: Dictionary = GameState.inventory if "inventory" in GameState else {}
			if inv.is_empty():
				_info("(empty inventory)")
				return
			for k in inv.keys():
				if bool(inv[k]):
					_info("  %s" % String(k))
		"recipes":
			if typeof(Recipes) == TYPE_NIL:
				_err("Recipes autoload unavailable")
				return
			for id in Recipes.RECIPES.keys():
				var r: Dictionary = Recipes.RECIPES[id]
				_info("  %s — %s" % [String(id), String(r.get("display", id))])
		"buffs":
			if typeof(BuffManager) == TYPE_NIL:
				_err("BuffManager autoload unavailable")
				return
			for id in BuffManager.BUFF_DEFS.keys():
				var d: Dictionary = BuffManager.BUFF_DEFS[id]
				_info("  %s — %s" % [String(id), String(d.get("label", id))])
		_:
			_err("unknown catalog: %s" % what)


# --- Helpers ----------------------------------------------------------

func _parse_int(args: Array, idx: int, fallback: int) -> int:
	if idx >= args.size():
		return fallback
	var s: String = String(args[idx])
	return int(s) if s.is_valid_int() else fallback


func _resource_count(id: String) -> int:
	if GameState.has_method("resource_count"):
		return int(GameState.resource_count(id))
	if "resources" in GameState:
		return int(GameState.resources.get(id, 0))
	return 0
