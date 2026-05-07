extends RefCounted

# Procedural skeletal animator for Tux. Drives the 7-bone Node3D rig
# (pelvis / torso / head / arm_l / arm_r / leg_l / leg_r) with per-tick
# Euler rotations computed from the current pose tag and a time cursor.
# Pose set is custom for stamina-melee combat (light combo, hold-block
# with parry window, roll dodge, sprint).

const ONE_SHOT_DURATION := {
    "swing_1":     0.45,
    "swing_2":     0.45,
    "swing_3":     0.55,
    "jab":         0.30,
    "jump_attack": 0.70,
    "spin":        0.45,
    "block_raise": 0.12,
    "parry":       0.20,
    "roll":        0.45,
    "land":        0.18,
    "hurt":        0.40,
}

var bones: Dictionary = {}
var rest_rotations: Dictionary = {}
var current_tag: String = "idle"
var speed: float = 1.0
var _time: float = 0.0
var _just_ended: bool = false


func setup(bone_dict: Dictionary) -> void:
    bones = bone_dict
    for key in bones.keys():
        var n: Node3D = bones[key]
        if n != null:
            rest_rotations[key] = n.rotation


func play(tag: String, speed_mult: float = 1.0, reset: bool = false) -> void:
    if tag != current_tag or reset:
        current_tag = tag
        _time = 0.0
        _just_ended = false
    speed = speed_mult


func tick(delta: float) -> void:
    _just_ended = false
    var dt: float = delta * speed
    var dur: float = ONE_SHOT_DURATION.get(current_tag, 0.0)
    if dur > 0.0:
        if _time < dur:
            _time += dt
            if _time >= dur:
                _just_ended = true
                _time = dur
    else:
        _time += dt
    _apply(current_tag, _time)


func is_at_end() -> bool:
    return _just_ended


# ---- Pose dispatch -----------------------------------------------------

func _apply(tag: String, t: float) -> void:
    for key in bones.keys():
        var n: Node3D = bones[key]
        if n != null:
            n.rotation = rest_rotations.get(key, Vector3.ZERO)
    match tag:
        "idle":           _pose_idle(t)
        "walk":           _pose_walk(t, 1.0)
        "run":            _pose_walk(t, 1.7)
        "sprint":         _pose_sprint(t)
        "swing_1":        _pose_swing(t, 1)
        "swing_2":        _pose_swing(t, 2)
        "swing_3":        _pose_swing(t, 3)
        "jab":            _pose_jab(t)
        "jump_attack":    _pose_jump_attack(t)
        "charging":       _pose_charging(t, false)
        "charging_full":  _pose_charging(t, true)
        "spin":           _pose_spin(t)
        "block_raise":    _pose_block(t, t / 0.12)
        "block_hold":     _pose_block(t, 1.0)
        "parry":          _pose_parry(t)
        "roll":           _pose_roll(t)
        "jump":           _pose_jump(t)
        "fall":           _pose_fall(t)
        "land":           _pose_land(t)
        "hurt":           _pose_hurt(t)
        "dead":           _pose_dead(t)
        _:                _pose_idle(t)


# ---- Poses -------------------------------------------------------------

func _pose_idle(t: float) -> void:
    _rot(bones.get("torso"), Vector3(sin(t * 1.5) * 0.015, 0, 0))
    _rot(bones.get("head"),  Vector3(0, sin(t * 0.7) * 0.08, 0))


func _pose_walk(t: float, intensity: float) -> void:
    var freq: float = 5.5 * intensity
    var amp_leg: float = 0.5 * clamp(intensity, 0.5, 1.8)
    var amp_arm: float = 0.4 * clamp(intensity, 0.5, 1.8)
    var phase: float = sin(t * freq)
    var phase_b: float = sin(t * freq + PI)
    _rot(bones.get("leg_l"), Vector3(phase * amp_leg, 0, 0))
    _rot(bones.get("leg_r"), Vector3(phase_b * amp_leg, 0, 0))
    _rot(bones.get("arm_l"), Vector3(phase_b * amp_arm, 0, 0))
    _rot(bones.get("arm_r"), Vector3(phase * amp_arm, 0, 0))
    _rot(bones.get("torso"), Vector3(0, phase * 0.07, 0))
    _rot(bones.get("pelvis"), Vector3(0, 0, phase * 0.04))


# Sprint: faster cadence, body leaned forward, arms tucked back.
func _pose_sprint(t: float) -> void:
    var freq: float = 9.5
    var phase: float = sin(t * freq)
    var phase_b: float = sin(t * freq + PI)
    _rot(bones.get("leg_l"), Vector3(phase * 0.7, 0, 0))
    _rot(bones.get("leg_r"), Vector3(phase_b * 0.7, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-0.5 + phase_b * 0.3, 0, -0.2))
    _rot(bones.get("arm_r"), Vector3(-0.5 + phase * 0.3, 0,  0.2))
    _rot(bones.get("torso"), Vector3(-0.4, phase * 0.08, 0))
    _rot(bones.get("head"),  Vector3(0.2, 0, 0))


# Sword swings — three variants for visual rhythm. swing_1 = R→L
# horizontal, swing_2 = L→R, swing_3 = overhead chop. The right wing
# does the cutting; left wing is held back for balance.
func _pose_swing(t: float, variant: int) -> void:
    var dur: float = 0.45
    if variant == 3:
        dur = 0.55
    var phase: float = clamp(t / dur, 0.0, 1.0)
    var s: float = ease(phase, 0.35)
    if variant == 1:
        var swing: float = lerpf(-1.1, 1.4, s)
        _rot(bones.get("arm_r"), Vector3(-1.5, swing, 0.2))
        _rot(bones.get("arm_l"), Vector3(-0.4, 0.0, -0.7))
        _rot(bones.get("torso"), Vector3(0.05, swing * 0.45, 0))
        _rot(bones.get("head"),  Vector3(0.0, swing * 0.25, 0))
    elif variant == 2:
        var swing2: float = lerpf(1.4, -1.1, s)
        _rot(bones.get("arm_r"), Vector3(-1.5, swing2, 0.2))
        _rot(bones.get("arm_l"), Vector3(-0.4, 0.0, -0.7))
        _rot(bones.get("torso"), Vector3(0.05, swing2 * 0.45, 0))
        _rot(bones.get("head"),  Vector3(0.0, swing2 * 0.25, 0))
    else:
        # Overhead chop: arm rises, then slams forward and down.
        var rise: float = clamp(s * 2.2, 0.0, 1.0)
        var fall: float = clamp(s * 2.2 - 1.2, 0.0, 1.0)
        var arm_x: float = lerpf(-0.4, -2.7, rise) + lerpf(0.0, 1.7, fall)
        _rot(bones.get("arm_r"), Vector3(arm_x, 0.0, 0.0))
        _rot(bones.get("arm_l"), Vector3(-0.6, 0.0, -0.6))
        _rot(bones.get("torso"), Vector3(lerpf(0.0, 0.4, fall), 0, 0))
        _rot(bones.get("head"),  Vector3(lerpf(0.0, 0.3, fall), 0, 0))


# Block: shield arm (left wing) raised UP and IN FRONT of the body — not
# out to the side. arm.x rotates the wing forward (lifts it from hanging
# at the side); arm.y rotates it inward across the chest so the shield
# sits at the body's centerline (12 o'clock) rather than at the
# shoulder (3 o'clock). arm.z stays small — extra Z lift would push the
# shield outward.
func _pose_block(_t: float, phase: float) -> void:
    var p: float = clamp(phase, 0.0, 1.0)
    _rot(bones.get("arm_l"), Vector3(-1.55 * p - 0.1, -0.55 * p, -0.20 * p))
    _rot(bones.get("arm_r"), Vector3(-0.4, -0.2, 0.6))
    _rot(bones.get("torso"), Vector3(0.05, 0.05, 0))
    _rot(bones.get("head"),  Vector3(0.05, -0.1, 0))


# Forward thrust: arm jabs straight ahead in a quick poke, body weight
# leaning into the strike, then snapping back.
func _pose_jab(t: float) -> void:
    var phase: float = clamp(t / 0.30, 0.0, 1.0)
    var poke: float = sin(phase * PI)
    _rot(bones.get("arm_r"), Vector3(-2.0 - poke * 0.6, -0.1, 0.1))
    _rot(bones.get("arm_l"), Vector3(-0.5, 0.0, -0.7))
    _rot(bones.get("torso"), Vector3(0.15 + poke * 0.25, 0.05, 0))
    _rot(bones.get("leg_r"), Vector3(-0.3 - poke * 0.25, 0, 0))
    _rot(bones.get("leg_l"), Vector3(0.1, 0, 0))


# Aerial down-strike: blade extended STRAIGHT FORWARD (arm horizontal,
# 90° from torso), free wing tucked back for balance. Pose is mostly
# static — the trail FX spawned by tux_player sells the motion. The
# brief lerp from -1.0 → -1.55 is just a tiny wind-up so the strike
# isn't a stiff snap to the final pose.
func _pose_jump_attack(t: float) -> void:
    var phase: float = clamp(t / 0.70, 0.0, 1.0)
    var thrust_in: float = clamp(phase * 4.0, 0.0, 1.0)
    var arm_x: float = lerpf(-1.00, -1.55, thrust_in)   # ends at exactly 90° forward
    _rot(bones.get("arm_r"), Vector3(arm_x, -0.15, 0.0))
    _rot(bones.get("arm_l"), Vector3(-0.7, 0.25, -0.5))
    _rot(bones.get("torso"), Vector3(0.10, 0, 0))
    _rot(bones.get("head"),  Vector3(0.15, 0, 0))
    _rot(bones.get("leg_l"), Vector3(-0.5, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.25, 0, 0))


# Charging wind-up. Sword stays extended forward — we wanted "straight
# out or slightly back from the player" rather than wound-back-by-the-
# shoulder. The blade drops a touch through the charge to read as
# weight gathering, but stays roughly in the plane of the swing. When
# `full` is true the pose adds a tremor sine for the ready-to-go feel.
func _pose_charging(t: float, full: bool) -> void:
    var blend: float = clamp(t / 0.18, 0.0, 1.0)
    # "swing-end" arm pose (extended forward, slightly to the right) →
    # charge-ready pose (arm slightly back from straight-forward, dropped
    # a hair so the blade reads as gathering weight).
    var arm_r_start := Vector3(-1.5, 0.6, 0.15)
    var arm_r_end   := Vector3(-1.30, 0.10, 0.10)
    var arm_r_now: Vector3 = arm_r_start.lerp(arm_r_end, blend)
    if full:
        var tremor: float = sin(t * 30.0) * 0.04
        arm_r_now += Vector3(tremor, 0.0, tremor)
    _rot(bones.get("arm_r"), arm_r_now)

    _rot(bones.get("torso"),  Vector3(0.05, 0.0, 0.0))
    _rot(bones.get("arm_l"),  Vector3(-0.5, 0.1, -0.7))
    _rot(bones.get("leg_l"),  Vector3(-0.1, 0, 0))
    _rot(bones.get("leg_r"),  Vector3(-0.1, 0, 0))
    _rot(bones.get("head"),   Vector3(0.05, 0.0, 0.0))


# Spin attack: arm stays at the swing-end position (blade extended
# forward-and-out) while the pelvis rotates a full 360 around Y. The
# arm pose is held constant — what you see is the body whirling under
# the planted sword, not the sword whipping into a new position.
func _pose_spin(t: float) -> void:
    var phase: float = clamp(t / 0.45, 0.0, 1.0)
    var spin: float = phase * TAU
    _rot(bones.get("pelvis"), Vector3(0, spin, 0))
    _rot(bones.get("arm_r"),  Vector3(-1.5, 0.6, 0.15))   # matches swing-end
    _rot(bones.get("arm_l"),  Vector3(-0.6, 0.0, -0.8))
    _rot(bones.get("torso"),  Vector3(0.05, 0, 0))
    _rot(bones.get("head"),   Vector3(0.10, 0, 0))


func _pose_parry(t: float) -> void:
    # Parry is the same as a fully-raised block, but with a quick wobble
    # that distinguishes it visually. The "flash" should be on the shield
    # mesh material — handled by the player script, not here.
    var p: float = 1.0
    var wobble: float = sin(t * 30.0) * 0.05
    _rot(bones.get("arm_l"), Vector3(-1.6 + wobble, 0.2, -1.3))
    _rot(bones.get("arm_r"), Vector3(-0.4, -0.2, 0.6))
    _rot(bones.get("torso"), Vector3(0.05, 0.0, 0))


# Forward roll: pelvis tumbles through one full revolution around X.
# The tucked arm/leg pose blends BACK to neutral over the last ~0.10s
# of the roll so the recovery doesn't end on a frozen ball-pose for a
# couple of frames before the idle takes over.
func _pose_roll(t: float) -> void:
    var dur: float = 0.45
    var phase: float = clamp(t / dur, 0.0, 1.0)
    var spin: float = phase * TAU
    var blend: float = clamp((dur - t) / 0.10, 0.0, 1.0)   # 1 → 0 over last 0.10s
    _rot(bones.get("pelvis"), Vector3(spin, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-1.6 * blend, 0, -0.4 * blend))
    _rot(bones.get("arm_r"), Vector3(-1.6 * blend, 0,  0.4 * blend))
    _rot(bones.get("leg_l"), Vector3(-1.2 * blend, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-1.2 * blend, 0, 0))


func _pose_jump(_t: float) -> void:
    _rot(bones.get("arm_l"), Vector3(-1.8, 0, -0.5))
    _rot(bones.get("arm_r"), Vector3(-1.8, 0,  0.5))
    _rot(bones.get("leg_l"), Vector3(-0.5, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.7, 0, 0))
    _rot(bones.get("torso"), Vector3(-0.15, 0, 0))


func _pose_fall(t: float) -> void:
    var sway: float = sin(t * 4.0) * 0.1
    _rot(bones.get("arm_l"), Vector3(-1.1 + sway, 0, -0.6))
    _rot(bones.get("arm_r"), Vector3(-1.1 - sway, 0,  0.6))
    _rot(bones.get("leg_l"), Vector3(-0.2 - sway, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.4 + sway, 0, 0))


func _pose_land(t: float) -> void:
    var phase: float = clamp(t / 0.18, 0.0, 1.0)
    var depth: float = sin(phase * PI) * 0.7
    _rot(bones.get("torso"), Vector3(0.6 * depth, 0, 0))
    _rot(bones.get("leg_l"), Vector3(-0.6 * depth, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.6 * depth, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-0.4, 0, -0.5))
    _rot(bones.get("arm_r"), Vector3(-0.4, 0,  0.5))


func _pose_hurt(t: float) -> void:
    var phase: float = clamp(t / 0.40, 0.0, 1.0)
    var jolt: float = sin(phase * PI) * 0.5
    _rot(bones.get("torso"), Vector3(-0.4 - jolt, 0, 0))
    _rot(bones.get("head"),  Vector3(-0.3, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-0.5, 0, -1.4))
    _rot(bones.get("arm_r"), Vector3(-0.5, 0,  1.4))


func _pose_dead(_t: float) -> void:
    _rot(bones.get("pelvis"), Vector3(0, 0, PI / 2))
    _rot(bones.get("arm_l"), Vector3(-0.3, 0, -0.4))
    _rot(bones.get("arm_r"), Vector3(-0.3, 0,  0.4))


static func _rot(node: Node3D, euler: Vector3) -> void:
    if node != null:
        node.rotation = euler
