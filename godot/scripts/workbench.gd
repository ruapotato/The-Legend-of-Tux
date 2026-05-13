extends StaticBody3D

# Crafting station. Walk up, press E, the craft UI opens listing every
# recipe whose station == "workbench". The UI itself lives in a child
# CanvasLayer that's hidden until interaction.

@export var prompt_text: String = "[E] Craft"

var _player_in_range: bool = false
var _ui_open: bool = false

@onready var _trigger: Area3D = $Trigger
@onready var _hint: Label3D = $Hint
@onready var _craft_ui: CanvasLayer = $CraftUI


func _ready() -> void:
	add_to_group("workbench")
	collision_layer = 1
	collision_mask = 0
	_hint.text = prompt_text
	_hint.visible = false
	_trigger.body_entered.connect(_on_player_enter)
	_trigger.body_exited.connect(_on_player_exit)
	_craft_ui.visible = false


func _on_player_enter(body: Node) -> void:
	if body.is_in_group("player"):
		_player_in_range = true
		_hint.visible = true


func _on_player_exit(body: Node) -> void:
	if body.is_in_group("player"):
		_player_in_range = false
		_hint.visible = false
		if _ui_open:
			_close_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if not _player_in_range:
		return
	if ke.keycode == KEY_E and not _ui_open:
		_open_ui()
		get_viewport().set_input_as_handled()
	elif ke.keycode == KEY_ESCAPE and _ui_open:
		_close_ui()
		get_viewport().set_input_as_handled()


func _open_ui() -> void:
	_ui_open = true
	_craft_ui.visible = true
	_hint.visible = false
	# Hand control to the panel so it can populate itself with the
	# workbench's station id.
	if _craft_ui.has_method("open_for_station"):
		_craft_ui.open_for_station("workbench")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_ui() -> void:
	_ui_open = false
	_craft_ui.visible = false
	_hint.visible = _player_in_range
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
