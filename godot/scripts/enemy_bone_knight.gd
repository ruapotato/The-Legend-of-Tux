extends CharacterBody3D

# Bone Knight — a giant skeleton-penguin warrior. Mirrors the player's
# combat: sword + shield, swings with a wind-up, raises shield when the
# player commits to an attack, takes knockback when its block fails.
#
# AI states:
#   IDLE        — standing in place, looking around
#   APPROACH    — walking toward the player (shield down, normal stance)
#   CIRCLE      — at attack range, strafing around the player to look for
#                 an opening
#   TELEGRAPH   — committing to a swing, sword wound up overhead
#   SLASH       — lunge forward, sword hitbox active during the active
#                 window of the swing
#   RECOVER     — post-swing pause, vulnerable
#   DEFEND      — reactive shield raise when the player attacks within
#                 range; blocks only the FRONT arc (hits from behind go
#                 through). Times out after DEFEND_TIME.
#   HURT        — knockback when a hit lands. Brief, then back to fighting.
#   DEAD        — flatten + despawn

const TuxAnim = preload("res://scripts/tux_anim.gd")
const TuxState = preload("res://scripts/tux_state.gd")
const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const HeartPickup = preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 8
@export var detect_range: float = 12.0
@export var attack_range: float = 2.5
@export var circle_range: float = 3.6
@export var move_speed: float = 2.5
@export var lunge_speed: float = 9.0
@export var attack_damage: int = 2
@export var pebble_reward: int = 5

const KNOCKBACK_SPEED: float = 6.0
const GRAVITY: float = 24.0
const TELEGRAPH_TIME: float = 0.55
# Aligned with the new TuxAnim swing_1 duration (0.32s). Previously the
# state held the slash for 0.45s while the anim finished in 0.32s —
# the sword was frozen at the end pose for the back half of the
# active window, so the hitbox sat motionless instead of sweeping.
const SLASH_DURATION: float = 0.32
const SLASH_HIT_WINDOW: Vector2 = Vector2(0.07, 0.22)
const RECOVER_TIME: float = 0.55
const DEFEND_TIME: float = 0.55
const HURT_TIME: float = 0.32
# Block only counts when the attack source is roughly in front of the
# knight. dot(forward, to_source) > this threshold = inside the front
# arc. 0.3 is roughly a 70° cone.
const DEFEND_FACE_DOT: float = 0.3

enum State { IDLE, APPROACH, CIRCLE, TELEGRAPH, SLASH, RECOVER, DEFEND, HURT, DEAD }

var hp: int = 8
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var circle_dir: int = 1
var circle_remaining: float = 0.0
var anim: RefCounted
var bones: Dictionary = {}
var _player_was_attacking: bool = false
# Direct hit-check state. The Area3D-based sword_hitbox kept failing to
# register the knight's slash hits despite obvious visual overlap with
# the player. Backstop: explicitly check distance + facing-cone during
# the active window and call player.take_damage directly. One-shot per
# slash via _slash_landed.
const ATTACK_REACH: float = 2.6
const ATTACK_CONE_DOT: float = 0.35
var _slash_landed: bool = false

@onready var rig: Node3D = $Rig
@onready var sword: Node3D = $Sword
@onready var shield_node: Node3D = $Shield
@onready var sword_hitbox: Area3D = $Sword/SwordHitbox
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")

    anim = TuxAnim.new()
    bones = {
        "pelvis": rig.get_node("pelvis"),
        "torso":  rig.get_node("pelvis/torso"),
        "head":   rig.get_node("pelvis/torso/head"),
        "arm_l":  rig.get_node("pelvis/torso/arm_l"),
        "arm_r":  rig.get_node("pelvis/torso/arm_r"),
        "leg_l":  rig.get_node("pelvis/leg_l"),
        "leg_r":  rig.get_node("pelvis/leg_r"),
    }
    anim.setup(bones)

    # Reparent weapons under the wing pivots so they ride the animation.
    var arm_r: Node3D = bones["arm_r"]
    var arm_l: Node3D = bones["arm_l"]
    remove_child(sword)
    arm_r.add_child(sword)
    sword.transform = Transform3D(Basis.IDENTITY, Vector3(-0.07, -0.32, 0))
    remove_child(shield_node)
    arm_l.add_child(shield_node)
    shield_node.transform = Transform3D(Basis(Vector3(1, 0, 0), PI / 2), Vector3(0.07, -0.30, 0))

    _apply_bone_materials()

    sword_hitbox.target_hit.connect(_on_sword_hit)
    sword_hitbox.disarm()


# Enemies enter the tree before the player in our generated dungeons,
# so _ready can't find Tux in the "player" group yet. Lazy-fetch each
# frame until valid.
func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta

    if state == State.DEAD:
        if not is_on_floor():
            velocity.y -= GRAVITY * delta
            move_and_slide()
        return
    _ensure_player()

    var to_player := Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        to_player.y = 0.0
        dist = to_player.length()

    # Reactive shield: when the player COMMITS to an attack within range
    # and the knight is already facing them, raise the shield. Only fires
    # on the rising edge of "is attacking" so a held attack doesn't lock
    # the knight into perma-defend.
    var p_attack: bool = _player_is_attacking()
    var p_attack_started: bool = p_attack and not _player_was_attacking
    _player_was_attacking = p_attack

    if p_attack_started and dist < attack_range * 1.6 and _facing_player(to_player) \
            and state in [State.IDLE, State.APPROACH, State.CIRCLE, State.RECOVER]:
        _set_state(State.DEFEND)

    match state:
        State.IDLE:           _do_idle(delta, to_player, dist)
        State.APPROACH:       _do_approach(delta, to_player, dist)
        State.CIRCLE:         _do_circle(delta, to_player, dist)
        State.TELEGRAPH:      _do_telegraph(delta, to_player, dist)
        State.SLASH:          _do_slash(delta)
        State.RECOVER:        _do_recover(delta, dist)
        State.DEFEND:         _do_defend(delta, to_player, dist)
        State.HURT:           _do_hurt(delta, dist)

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0
    move_and_slide()
    anim.tick(delta)


# ---- Per-state handlers ------------------------------------------------

func _do_idle(delta: float, to_player: Vector3, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 8.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 8.0 * delta)
    anim.play("idle")
    if dist < detect_range:
        _set_state(State.APPROACH)


func _do_approach(delta: float, to_player: Vector3, dist: float) -> void:
    if dist > detect_range * 1.5:
        _set_state(State.IDLE)
        return
    if dist < circle_range:
        _begin_circle()
        return
    var dir: Vector3 = to_player.normalized()
    velocity.x = dir.x * move_speed
    velocity.z = dir.z * move_speed
    rotation.y = atan2(-dir.x, -dir.z)
    anim.play("walk")


func _do_circle(delta: float, to_player: Vector3, dist: float) -> void:
    circle_remaining -= delta
    var to_p: Vector3 = to_player.normalized() if to_player.length_squared() > 1e-6 else Vector3.FORWARD
    # Strafe perpendicular to player direction.
    var strafe: Vector3 = Vector3(-to_p.z, 0, to_p.x) * float(circle_dir)
    velocity.x = strafe.x * move_speed * 0.85
    velocity.z = strafe.z * move_speed * 0.85
    rotation.y = atan2(-to_p.x, -to_p.z)
    anim.play("walk")
    if circle_remaining <= 0.0:
        # Mostly attack, occasionally re-approach. Keeps fights varied.
        if randf() < 0.65:
            _set_state(State.TELEGRAPH)
        else:
            _set_state(State.APPROACH)
    elif dist > circle_range * 1.4:
        _set_state(State.APPROACH)


func _do_telegraph(delta: float, to_player: Vector3, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 12.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 12.0 * delta)
    if to_player.length_squared() > 1e-6:
        var dir: Vector3 = to_player.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    anim.play("swing_3")     # overhead chop wind-up
    if state_time >= TELEGRAPH_TIME:
        _set_state(State.SLASH)


func _do_slash(delta: float) -> void:
    var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
    if state_time >= SLASH_HIT_WINDOW.x and state_time <= SLASH_HIT_WINDOW.y:
        sword_hitbox.arm()
        velocity.x = fwd.x * lunge_speed
        velocity.z = fwd.z * lunge_speed
        # Direct hit backstop. The Area3D path was unreliable during
        # the rig's scaled fast-swing transforms; this tests "is the
        # player in front of me and within sword range?" each tick.
        if not _slash_landed and player and is_instance_valid(player):
            var to_p: Vector3 = player.global_position - global_position
            to_p.y = 0
            var d: float = to_p.length()
            if d > 0.05 and d < ATTACK_REACH:
                var to_p_n: Vector3 = to_p / d
                if fwd.dot(to_p_n) > ATTACK_CONE_DOT:
                    _slash_landed = true
                    if player.has_method("take_damage"):
                        SoundBank.play_3d("sword_hit", global_position)
                        player.take_damage(attack_damage, global_position, self)
                        print("[Knight %s] DIRECT HIT dist=%.2f" % [name, d])
    else:
        sword_hitbox.set_deferred("monitoring", false)
        velocity.x = move_toward(velocity.x, 0, 18.0 * delta)
        velocity.z = move_toward(velocity.z, 0, 18.0 * delta)
    anim.play("swing_1")
    if state_time >= SLASH_DURATION:
        _set_state(State.RECOVER)


func _do_recover(delta: float, dist: float) -> void:
    sword_hitbox.set_deferred("monitoring", false)
    velocity.x = move_toward(velocity.x, 0, 14.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 14.0 * delta)
    anim.play("idle")
    if state_time >= RECOVER_TIME:
        if dist < detect_range:
            _begin_circle()
        else:
            _set_state(State.IDLE)


func _do_defend(delta: float, to_player: Vector3, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 14.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 14.0 * delta)
    if to_player.length_squared() > 1e-6:
        var dir: Vector3 = to_player.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    anim.play("block_hold")
    if state_time >= DEFEND_TIME:
        if dist < attack_range * 1.5:
            _set_state(State.TELEGRAPH)   # counter-attack after a successful guard
        elif dist < detect_range:
            _begin_circle()
        else:
            _set_state(State.IDLE)


func _do_hurt(delta: float, dist: float) -> void:
    velocity.x = move_toward(velocity.x, 0, 6.0 * delta)
    velocity.z = move_toward(velocity.z, 0, 6.0 * delta)
    anim.play("hurt")
    if state_time >= HURT_TIME:
        _set_state(State.APPROACH if dist < detect_range else State.IDLE)


# ---- Damage in / out ---------------------------------------------------

func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    # Front-arc shield block: if defending and the hit came from the
    # front, deflect with no HP loss.
    if state == State.DEFEND:
        var to_src: Vector3 = source_pos - global_position
        to_src.y = 0
        if to_src.length() > 0.001:
            var to_src_dir: Vector3 = to_src.normalized()
            var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
            if fwd.dot(to_src_dir) > DEFEND_FACE_DOT:
                SoundBank.play_3d("shield_block", global_position)
                return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
        velocity.y = 3.0
    _hit_punch()
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func _hit_punch() -> void:
    if not rig:
        return
    var base_scale: Vector3 = rig.scale
    rig.scale = base_scale * Vector3(1.10, 0.90, 1.10)
    var t := create_tween()
    t.tween_property(rig, "scale", base_scale, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Called by tux_player when the player parries/blocks the knight's
# attack. Cancels the knight's swing and tips it backward.
func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 4.0
    _set_state(State.HURT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    # Deferred — _die can be reached from inside the player's sword
    # area_entered signal; direct monitoring writes are blocked there.
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    sword_hitbox.set_deferred("monitoring", false)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(rig, "scale", rig.scale * Vector3(1, 0.05, 1), 0.45)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        parent.call_deferred("add_child", p)
        var off := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
        p.global_position = global_position + off
    var h := HeartPickup.instantiate()
    parent.call_deferred("add_child", h)
    h.global_position = global_position + Vector3(0, 0.0, 0.4)


# ---- Helpers -----------------------------------------------------------

func _set_state(new_state: int) -> void:
    var prev := state
    state = new_state
    state_time = 0.0
    if state != State.SLASH:
        sword_hitbox.set_deferred("monitoring", false)
        # Re-arm direct-hit gate when leaving SLASH; cleared so the
        # next slash can land.
        _slash_landed = false
    # Audio cues.
    if state == State.APPROACH and prev == State.IDLE:
        SoundBank.play_3d("blob_alert", global_position)
    elif state == State.TELEGRAPH:
        SoundBank.play_3d("sword_charge", global_position)
    elif state == State.SLASH:
        SoundBank.play_3d("sword_swing", global_position)
    elif state == State.DEFEND:
        SoundBank.play_3d("shield_raise", global_position)


func _begin_circle() -> void:
    circle_remaining = randf_range(0.7, 1.4)
    circle_dir = 1 if randf() > 0.5 else -1
    _set_state(State.CIRCLE)


func _on_sword_hit(_target: Node) -> void:
    SoundBank.play_3d("sword_hit", global_position)


func _player_is_attacking() -> bool:
    if not player or not is_instance_valid(player):
        return false
    if not "state" in player or player.state == null:
        return false
    var act: int = player.state.action
    return act == TuxState.ACT_ATTACK or act == TuxState.ACT_JAB \
            or act == TuxState.ACT_JUMP_ATTACK or act == TuxState.ACT_SPIN


func _facing_player(to_player: Vector3) -> bool:
    if to_player.length_squared() < 1e-6:
        return true
    var fwd: Vector3 = Vector3(-sin(rotation.y), 0, -cos(rotation.y))
    return fwd.dot(to_player.normalized()) > -0.3   # generous: not turned away


# Override the rig's default penguin colors with a bone palette. We keep
# the rig instance shared with the player so we don't duplicate the
# scene; runtime material overrides handle the visual variant.
func _apply_bone_materials() -> void:
    var bone := StandardMaterial3D.new()
    bone.albedo_color = Color(0.86, 0.84, 0.76, 1)
    bone.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
    bone.roughness = 0.85
    var bone_dark := StandardMaterial3D.new()
    bone_dark.albedo_color = Color(0.55, 0.52, 0.46, 1)
    bone_dark.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
    bone_dark.roughness = 0.85
    var eye := StandardMaterial3D.new()
    eye.albedo_color = Color(0.95, 0.20, 0.10, 1)
    eye.emission_enabled = true
    eye.emission = Color(1.0, 0.30, 0.15)
    eye.emission_energy_multiplier = 1.8
    var pupil := StandardMaterial3D.new()
    pupil.albedo_color = Color(0.05, 0.00, 0.00, 1)

    for n in _all_meshes(rig):
        var nm: String = n.name
        if nm in ["EyeL", "EyeR"]:
            n.material_override = eye
        elif nm in ["PupilL", "PupilR"]:
            n.material_override = pupil
        elif nm in ["Beak", "Beak2", "Foot", "LegMesh"]:
            n.material_override = bone_dark
        else:
            n.material_override = bone


func _all_meshes(root: Node) -> Array:
    var out: Array = []
    if root is MeshInstance3D:
        out.append(root)
    for child in root.get_children():
        out.append_array(_all_meshes(child))
    return out
