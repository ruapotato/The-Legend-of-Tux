extends Camera3D

# Free-fly editor camera with Unreal/Unity-style continuous mouse-look.
#
# Default: cursor captured while the camera is active. Mouse motion
# always rotates (no RMB requirement). Alt or F1 toggles cursor
# release so the user can click UI widgets. The owning EditorUI flips
# `manual_release` via release_mouse()/capture_mouse() when the user
# clicks into / out of UI panels.
#
# Movement: WASD horizontal, Q/E vertical. Shift = 3x speed, Ctrl =
# 0.3x. Mouse wheel adjusts FOV between 40°-90° for precision work
# (PageUp/PageDown resets FOV to 70°).
#
# Numpad views: 7 top, 1 front, 3 side, 5 perspective, 0 reset.
# T = top (alias for 7) per spec. Bookmarks (Shift+1..9 save, 1..9
# jump) are handled by editor_ui.gd and applied via apply_bookmark().

const SPEED: float = 8.0
const SPEED_BOOST: float = 3.0
const SPEED_FINE: float = 0.3
const MOUSE_SENS: float = 0.0025
const FOV_MIN: float = 40.0
const FOV_MAX: float = 90.0
const FOV_DEFAULT: float = 70.0

var _yaw: float = 0.0
var _pitch: float = -0.25
# Whether the user has explicitly asked the cursor to be visible (Alt
# toggle). When true we do *not* re-capture on motion. EditorUI flips
# this when focus moves to a UI panel.
var manual_release: bool = false
# Whether the cursor is currently captured. Tracked locally because
# Input.mouse_mode is shared across the project.
var _captured: bool = false

# Orthographic mode flag — set when the user picks numpad 7/1/3.
var _ortho: bool = false


func _ready() -> void:
	visible = false
	current = false
	rotation = Vector3(_pitch, _yaw, 0)
	fov = FOV_DEFAULT


# EditorMode calls set_process_input/process_unhandled_input on mode
# flips. When we lose focus (Tab → play), release the cursor so the
# player gets it back.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PROCESS:
		pass
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not visible:
			_release_capture()


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	_release_capture()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# Only consume motion when the cursor is captured. Otherwise
		# the user is interacting with UI; do not rotate.
		if _captured:
			_yaw   -= mm.relative.x * MOUSE_SENS
			_pitch -= mm.relative.y * MOUSE_SENS
			_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
			rotation = Vector3(_pitch, _yaw, 0)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# Wheel = FOV zoom (precision).
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_fov_delta(-2.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_fov_delta(2.0)
	elif event is InputEventKey:
		var ke := event as InputEventKey
		if not ke.pressed or ke.echo:
			return
		match ke.keycode:
			KEY_ALT, KEY_F1:
				_toggle_capture()
				get_viewport().set_input_as_handled()
			KEY_PAGEUP, KEY_PAGEDOWN:
				fov = FOV_DEFAULT
				get_viewport().set_input_as_handled()
			KEY_KP_7:
				view_top()
				get_viewport().set_input_as_handled()
			KEY_KP_1:
				view_front()
				get_viewport().set_input_as_handled()
			KEY_KP_3:
				view_side()
				get_viewport().set_input_as_handled()
			KEY_KP_5:
				toggle_ortho()
				get_viewport().set_input_as_handled()
			KEY_KP_0:
				view_reset()
				get_viewport().set_input_as_handled()


# Allow EditorMode / EditorUI to script capture/release.
func capture_mouse() -> void:
	manual_release = false
	_set_capture(true)


func release_mouse() -> void:
	manual_release = true
	_set_capture(false)


func _toggle_capture() -> void:
	if _captured:
		release_mouse()
	else:
		capture_mouse()


func _set_capture(want: bool) -> void:
	_captured = want
	Input.mouse_mode = (
		Input.MOUSE_MODE_CAPTURED if want
		else Input.MOUSE_MODE_VISIBLE
	)


func _release_capture() -> void:
	if _captured:
		_set_capture(false)
	manual_release = false


func is_mouse_captured() -> bool:
	return _captured


func set_fov_delta(delta: float) -> void:
	fov = clamp(fov + delta, FOV_MIN, FOV_MAX)


func _process(delta: float) -> void:
	# Always-on capture if we're the active camera and the user hasn't
	# manually released. This is what makes the editor feel like UE/Unity.
	if not manual_release and not _captured and current and visible:
		_set_capture(true)

	var fwd: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	fwd.y = 0
	if fwd.length() > 0.001:
		fwd = fwd.normalized()
	right.y = 0
	if right.length() > 0.001:
		right = right.normalized()
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move += fwd
	if Input.is_key_pressed(KEY_S): move -= fwd
	if Input.is_key_pressed(KEY_D): move += right
	if Input.is_key_pressed(KEY_A): move -= right
	if Input.is_key_pressed(KEY_E): move += Vector3.UP
	if Input.is_key_pressed(KEY_Q): move -= Vector3.UP
	var speed: float = SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= SPEED_BOOST
	if Input.is_key_pressed(KEY_CTRL):
		speed *= SPEED_FINE
	if move.length() > 1.0:
		move = move.normalized()
	position += move * speed * delta


func get_forward_xz() -> Vector3:
	var f: Vector3 = -global_transform.basis.z
	f.y = 0
	if f.length() < 0.001:
		return Vector3.FORWARD
	return f.normalized()


# ---- Views ------------------------------------------------------------

func view_top() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = 40.0
	_ortho = true
	position = Vector3(position.x, 40, position.z)
	_yaw = 0
	_pitch = -PI * 0.5
	rotation = Vector3(_pitch, _yaw, 0)


func view_front() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = 40.0
	_ortho = true
	position = Vector3(position.x, 6, 40)
	_yaw = 0
	_pitch = 0
	rotation = Vector3(_pitch, _yaw, 0)


func view_side() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = 40.0
	_ortho = true
	position = Vector3(40, 6, position.z)
	_yaw = PI * 0.5
	_pitch = 0
	rotation = Vector3(_pitch, _yaw, 0)


func toggle_ortho() -> void:
	if projection == PROJECTION_ORTHOGONAL:
		projection = PROJECTION_PERSPECTIVE
		_ortho = false
	else:
		projection = PROJECTION_ORTHOGONAL
		_ortho = true


func view_reset() -> void:
	projection = PROJECTION_PERSPECTIVE
	fov = FOV_DEFAULT
	_ortho = false
	position = Vector3(0, 8, 8)
	_yaw = 0
	_pitch = deg_to_rad(-30)
	rotation = Vector3(_pitch, _yaw, 0)


# Bookmarks ------------------------------------------------------------

func capture_bookmark() -> Dictionary:
	return {
		"position": position,
		"rotation": rotation,
		"fov": fov,
		"projection": projection,
		"size": size,
	}


func apply_bookmark(b: Dictionary) -> void:
	if b.is_empty():
		return
	if b.has("position"):
		position = b["position"]
	if b.has("rotation"):
		rotation = b["rotation"]
		_pitch = rotation.x
		_yaw = rotation.y
	if b.has("fov"):
		fov = b["fov"]
	if b.has("projection"):
		projection = b["projection"]
	if b.has("size"):
		size = b["size"]
