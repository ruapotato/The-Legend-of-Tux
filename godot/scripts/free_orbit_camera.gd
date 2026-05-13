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

# Trauma-style screen shake. Owners call shake(amp, duration) to add
# kick on big events; per-frame the trauma decays linearly and offsets
# the camera position by a noise-driven jitter.
var _shake_amp: float = 0.0
var _shake_t: float = 0.0
var _shake_dur: float = 0.0

# Lock-on framing. While `_lock_target` is set, _process drives the
# camera node toward a position behind-and-above the player that frames
# both player and target, and yaw/pitch derive from that view direction
# instead of the mouse. Mouse motion is suppressed during lock so a
# stray drag can't fight the framing.
var _lock_target: Node3D = null
const LOCK_BEHIND_DIST: float = 3.0      # metres behind the player
const LOCK_HEIGHT_OFFSET: float = 1.5    # metres above the player
const LOCK_LOOK_HEIGHT: float = 0.6      # raise the look-midpoint slightly
const LOCK_LERP_RATE: float = 10.0       # how snappily the camera settles

# ---- First-person aim mode -------------------------------------------
# OoT-style: when the bow or slingshot is the active B-item and the
# AIM button is held, the camera collapses the spring arm, snaps the
# pivot to the player's head (~1.6m above the player root), and lets
# the mouse drive yaw/pitch with a wider pitch range so the player can
# aim at high targets. Position lerps over FP_ENTER_TIME on entry and
# the spring arm restores over FP_EXIT_TIME on exit so the camera
# doesn't snap.
#
# Owner contract: tux_player.gd calls enter_first_person(head_pos) and
# exit_first_person(). While in FP mode the lock-on path is suppressed
# entirely (you can't aim and lock-frame at the same time — the mouse
# is for aiming).
var _fp_active: bool = false
var _fp_head_pos: Vector3 = Vector3.ZERO
var _fp_blend: float = 0.0               # 0 = third-person, 1 = first-person
var _fp_target_blend: float = 0.0
const FP_ENTER_TIME: float = 0.18
const FP_EXIT_TIME: float = 0.18
const FP_PITCH_MIN: float = -1.2         # rad — look up at high archery targets
const FP_PITCH_MAX: float = 1.2          # rad — look down at scurrying things


func _ready() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    if arm:
        arm.spring_length = arm_length


func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        # Suppress free-look while locked — _process owns yaw/pitch then.
        # First-person aim DOES want mouse motion (it's the whole point),
        # so the FP mode is checked separately and uses a wider pitch
        # range so the player can crane up at archery targets.
        # Wheel zoom + escape still pass through below.
        if _fp_active:
            _yaw   -= event.relative.x * mouse_sensitivity
            _pitch -= event.relative.y * mouse_sensitivity
            _pitch = clamp(_pitch, FP_PITCH_MIN, FP_PITCH_MAX)
            return
        if _lock_target != null and is_instance_valid(_lock_target):
            return
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

    # ---- First-person aim ---------------------------------------------
    # FP mode wins over lock framing — you can't do both at once. The
    # spring arm collapses to 0 (so the camera sits exactly at the
    # pivot, i.e. the head), the pivot lerps to the player's head, and
    # rotation is driven straight from _yaw / _pitch updated by the
    # mouse handler above. On exit, the blend ramps back toward 0 and
    # the spring arm restores from 0 → arm_length so the third-person
    # view re-establishes smoothly.
    var blend_rate: float = (1.0 / FP_ENTER_TIME) if _fp_target_blend > _fp_blend else (1.0 / FP_EXIT_TIME)
    _fp_blend = move_toward(_fp_blend, _fp_target_blend, blend_rate * delta)

    if _fp_active or _fp_blend > 0.001:
        # Track the player's head every frame so head_pos chases the
        # body if the player moves/jumps mid-aim. tux_player calls
        # enter_first_person each tick aim is held, which refreshes
        # _fp_head_pos against the player's current global position.
        var head_target: Vector3 = _fp_head_pos
        # Lerp the spring arm length from arm_length down to 0 as the
        # blend rises. Position lerps from the third-person desired
        # position toward the head target by the same blend factor.
        if arm:
            arm.spring_length = lerp(arm_length, 0.0, _fp_blend)
        var third_person_pos: Vector3 = target_node.get_global_transform_interpolated().origin + look_offset
        var pos: Vector3 = third_person_pos.lerp(head_target, _fp_blend)
        # Settle quickly when actively in FP — the lerp above is from
        # third- to first-person; we still need a frame-smoothed follow
        # for the player's motion. Use a snappier follow rate while in
        # FP so the camera doesn't lag behind the head when the player
        # walks while aiming.
        global_position = global_position.lerp(pos, clamp(delta * follow_smooth * 2.0, 0.0, 1.0))
        rotation = Vector3(_pitch, _yaw, 0.0)
        _apply_shake(delta)
        return

    # ---- Lock-on framing -------------------------------------------------
    # While a lock target is set, position the pivot behind-and-above the
    # player on the player→target axis and aim at the midpoint between
    # the two. The yaw/pitch we derive here also feeds back into _yaw /
    # _pitch so when the lock releases the mouse picks up smoothly from
    # the camera's current orientation rather than snapping.
    if _lock_target != null and is_instance_valid(_lock_target):
        var pp: Vector3 = target_node.get_global_transform_interpolated().origin
        var tp: Vector3 = _lock_target.get_global_transform_interpolated().origin
        var to_t: Vector3 = tp - pp
        to_t.y = 0.0
        if to_t.length() > 0.001:
            var fwd: Vector3 = to_t.normalized()
            var desired_pos: Vector3 = pp - fwd * LOCK_BEHIND_DIST + Vector3.UP * LOCK_HEIGHT_OFFSET
            var look_at: Vector3 = (pp + tp) * 0.5 + Vector3.UP * LOCK_LOOK_HEIGHT
            var t: float = clamp(delta * LOCK_LERP_RATE, 0.0, 1.0)
            global_position = global_position.lerp(desired_pos, t)
            # Derive yaw/pitch from the desired look-direction. Same
            # convention as mouse-look: yaw rotates around Y, pitch is
            # the elevation from the horizontal.
            var look_dir: Vector3 = look_at - global_position
            if look_dir.length() > 0.001:
                var target_yaw: float = atan2(-look_dir.x, -look_dir.z)
                var horiz_len: float = Vector2(look_dir.x, look_dir.z).length()
                var target_pitch: float = atan2(look_dir.y, horiz_len)
                _yaw = lerp_angle(_yaw, target_yaw, t)
                _pitch = lerp(_pitch, target_pitch, t)
            rotation = Vector3(_pitch, _yaw, 0.0)
            # Skip the standard follow path while locked.
            _apply_shake(delta)
            return

    # Read the interpolated origin so the camera sees Tux smoothly
    # between physics steps. Without this, at high FPS (200+) the
    # camera renders at every frame but Tux's transform only updates
    # at the 60 Hz physics tick — visible as a forward "jitter" /
    # stagger on the player while sprinting.
    var desired := target_node.get_global_transform_interpolated().origin + look_offset
    global_position = global_position.lerp(desired, clamp(delta * follow_smooth, 0.0, 1.0))
    rotation = Vector3(_pitch, _yaw, 0.0)

    # Restore the arm length in case a fully-completed FP exit left it
    # at the lerped end-state (it should be arm_length already, but the
    # move_toward step can land 0.0001 short — be explicit).
    if arm and not is_equal_approx(arm.spring_length, arm_length):
        arm.spring_length = arm_length

    _apply_shake(delta)


# Trauma decay + per-frame jitter. Applied as a position offset post-
# lerp so the shake is purely visual and doesn't poison the smoothed
# follow target. Pulled out of _process so the lock-on path can call
# it too without duplicating the body.
func _apply_shake(delta: float) -> void:
    if _shake_t > 0.0:
        _shake_t = max(0.0, _shake_t - delta)
        var k: float = _shake_t / max(_shake_dur, 0.001)
        var amp: float = _shake_amp * k
        global_position += Vector3(
            randf_range(-1.0, 1.0) * amp,
            randf_range(-1.0, 1.0) * amp * 0.6,
            randf_range(-1.0, 1.0) * amp
        )
        if _shake_t == 0.0:
            _shake_amp = 0.0


# Engage lock framing on `target`. Owner (tux_player) calls this on
# acquisition and refreshes it each tick — _process reads `_lock_target`
# to drive the framing.
func lock_to(target: Node3D) -> void:
    _lock_target = target


func unlock() -> void:
    _lock_target = null


func get_yaw() -> float:
    return _yaw


# Snap the camera to a specific yaw (used by DungeonRoot on scene load
# so the camera lands behind the player instead of pointing at the
# load-zone wall they just stepped through).
func set_yaw(new_yaw: float) -> void:
    _yaw = new_yaw


# Apply a kick to the camera. Multiple calls stack — the larger
# amplitude + longer duration win.
func shake(amplitude: float, duration: float) -> void:
    if amplitude > _shake_amp:
        _shake_amp = amplitude
    if duration > _shake_t:
        _shake_t = duration
        _shake_dur = duration


# Camera-forward in world space, flattened to XZ. Owner uses this to
# build camera-relative input vectors.
func get_flat_forward() -> Vector3:
    var f := -global_transform.basis.z
    f.y = 0.0
    if f.length_squared() < 0.0001:
        return Vector3(0, 0, -1)
    return f.normalized()


# ---- First-person aim API --------------------------------------------
# tux_player calls these when the player holds AIM with the bow or
# slingshot equipped. enter_first_person() is safe to call every frame
# while aim is held — it just refreshes the head position so the camera
# tracks a moving / jumping player. exit_first_person() flips the
# target blend back to 0; the camera lerps out of FP over FP_EXIT_TIME.

func enter_first_person(player_head_pos: Vector3) -> void:
    _fp_head_pos = player_head_pos
    _fp_active = true
    _fp_target_blend = 1.0
    # If we were locked-on, drop the lock so the FP framing isn't
    # fighting it. (tux_player should also have unlocked, but this is
    # cheap insurance against a stale ref.)
    if _lock_target != null:
        _lock_target = null


func exit_first_person() -> void:
    _fp_active = false
    _fp_target_blend = 0.0


func is_first_person() -> bool:
    return _fp_active


# Camera-forward in world space (full 3D, includes pitch). Used by
# arrow / seed firing in aim mode so projectiles fly along the line of
# sight instead of along the player's flat facing.
func get_aim_forward() -> Vector3:
    var f := -global_transform.basis.z
    if f.length_squared() < 0.0001:
        return Vector3(0, 0, -1)
    return f.normalized()
