extends Camera3D

# Free-fly editor camera. WASD = horizontal, Q/E = down/up, RMB-drag =
# mouse look. Shift = 3x speed boost. Mouse mode is captured when RMB
# is held and visible otherwise — so the user can interact with the UI
# overlay without dragging an invisible cursor.
#
# This camera is the one and only Camera3D active during edit mode; the
# orbit camera is demoted by EditorMode while edit is on.

const SPEED: float = 8.0
const SPEED_BOOST: float = 3.0
const MOUSE_SENS: float = 0.003

var _yaw: float = 0.0
var _pitch: float = -0.25
var _looking: bool = false


func _ready() -> void:
	# Start invisible — EditorMode flips us on entry to edit mode.
	visible = false
	current = false
	rotation = Vector3(_pitch, _yaw, 0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_looking = mb.pressed
			Input.mouse_mode = (
				Input.MOUSE_MODE_CAPTURED if _looking
				else Input.MOUSE_MODE_VISIBLE
			)
	elif event is InputEventMouseMotion and _looking:
		var mm := event as InputEventMouseMotion
		_yaw   -= mm.relative.x * MOUSE_SENS
		_pitch -= mm.relative.y * MOUSE_SENS
		_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(_pitch, _yaw, 0)


func _process(delta: float) -> void:
	# Build movement vector in camera-local space; rotate into world via
	# the current basis. WASD on the XZ plane (camera-relative forward),
	# Q/E vertical. Sprint multiplies by SPEED_BOOST.
	var fwd: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	# Flatten forward to keep WASD truly horizontal regardless of pitch;
	# Q/E owns vertical.
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
	if move.length() > 1.0:
		move = move.normalized()
	position += move * speed * delta


func get_forward_xz() -> Vector3:
	var f: Vector3 = -global_transform.basis.z
	f.y = 0
	if f.length() < 0.001:
		return Vector3.FORWARD
	return f.normalized()
