extends Node3D

# Third-person mouse-look camera. Mouse motion drives yaw/pitch around
# a pivot that follows the player. A SpringArm3D with a Camera3D inside
# keeps the camera from clipping through walls.
#
# Owner contract: this Node3D's `target_node` should be the player. The
# camera is a sibling of the player at the scene root, not its child,
# so the player's rotation never tugs the camera around.

@export var target_node: Node3D
@export var follow_smooth: float = 12.0
@export var look_offset: Vector3 = Vector3(0, 1.4, 0)
@export var arm_length: float = 4.5
@export var arm_min: float = 1.5
@export var arm_max: float = 7.0
@export var pitch_min_deg: float = -65.0
@export var pitch_max_deg: float = 60.0
@export var mouse_sensitivity: float = 0.0025

@onready var arm: SpringArm3D = $SpringArm
@onready var cam: Camera3D = $SpringArm/Camera

var _yaw: float = 0.0
var _pitch: float = -0.25       # slight downward tilt by default


func _ready() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    if arm:
        arm.spring_length = arm_length


func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        _yaw   -= event.relative.x * mouse_sensitivity
        _pitch -= event.relative.y * mouse_sensitivity
        _pitch = clamp(_pitch, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
    elif event is InputEventMouseButton and event.pressed:
        # Scroll = zoom. Wheel up shortens the arm; wheel down lengthens.
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            arm_length = clamp(arm_length - 0.4, arm_min, arm_max)
            if arm:
                arm.spring_length = arm_length
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            arm_length = clamp(arm_length + 0.4, arm_min, arm_max)
            if arm:
                arm.spring_length = arm_length
    elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
    if not target_node:
        return
    var desired := target_node.global_position + look_offset
    global_position = global_position.lerp(desired, clamp(delta * follow_smooth, 0.0, 1.0))
    rotation = Vector3(_pitch, _yaw, 0.0)


func get_yaw() -> float:
    return _yaw


# Camera-forward in world space, flattened to XZ. Owner uses this to
# build camera-relative input vectors.
func get_flat_forward() -> Vector3:
    var f := -global_transform.basis.z
    f.y = 0.0
    if f.length_squared() < 0.0001:
        return Vector3(0, 0, -1)
    return f.normalized()
