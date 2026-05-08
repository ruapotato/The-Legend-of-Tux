extends CharacterBody3D

# Wisp Hunter — fast small enemy that darts in straight-line bursts.
# Looks like a glowing dark-blue mote with trailing wisps. Very low HP
# but EVASIVE — when it sees the player commit to a swing (action ==
# ACT_ATTACK / ACT_JAB / ACT_SPIN), it dodges sideways for ~0.4s before
# resuming its hunt.
#
# State machine:
#   IDLE     — drifts slowly, no player in range
#   STALK    — circles toward the player at hover height
#   CHARGE   — straight-line burst at the player; contact damage
#   RECOVER  — peels off, slows down for a moment
#   DODGE    — perpendicular evade (triggered by player swing)
#   HURT     — bounce when hit
#   DEAD     — fade out

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const TuxState = preload("res://scripts/tux_state.gd")

signal died

@export var max_hp: int = 2
@export var aggro_range: float = 12.0
@export var charge_range: float = 7.0
@export var stalk_speed: float = 3.5
@export var charge_speed: float = 11.0
@export var recover_speed: float = 2.5
@export var dodge_speed: float = 8.0
@export var attack_damage: int = 1
@export var pebble_reward: int = 1

const HOVER_HEIGHT: float = 1.4
const HOVER_AMP: float = 0.12
const CHARGE_DURATION: float = 0.55
const RECOVER_DURATION: float = 0.55
const DODGE_DURATION: float = 0.40
const HURT_DURATION: float = 0.20
const KNOCKBACK_SPEED: float = 6.0
const CHARGE_COOLDOWN: float = 1.0
# Range within which the hunter notices a player swing and reacts.
const REACT_RANGE: float = 5.0

enum State { IDLE, STALK, CHARGE, RECOVER, DODGE, HURT, DEAD }

var hp: int = 2
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _spawn_y: float = HOVER_HEIGHT
var _last_charge_at: float = -100.0
var _player_was_attacking: bool = false
var _dodge_dir: Vector3 = Vector3.ZERO
var _charge_dir: Vector3 = Vector3.FORWARD
var _contacted_this_charge: bool = false

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var attack_hitbox: Area3D = $AttackHitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    _spawn_y = global_position.y
    if _spawn_y < 0.5:
        _spawn_y = HOVER_HEIGHT
        global_position.y = _spawn_y
    attack_hitbox.body_entered.connect(_on_attack_overlap)
    attack_hitbox.monitoring = false


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta
    if state == State.DEAD:
        return
    _ensure_player()

    var to_player := Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        to_player.y = 0.0
        dist = to_player.length()

    # Reactive dodge: rising-edge of the player committing to a swing.
    var p_attack: bool = _player_is_attacking()
    var p_attack_started: bool = p_attack and not _player_was_attacking
    _player_was_attacking = p_attack
    if p_attack_started and dist < REACT_RANGE \
            and state in [State.IDLE, State.STALK, State.RECOVER]:
        _begin_dodge(to_player)

    var now: float = Time.get_ticks_msec() / 1000.0

    match state:
        State.IDLE:
            _bob_y()
            velocity.x = sin(state_time * 0.9) * 0.4
            velocity.z = cos(state_time * 0.7) * 0.4
            visual.rotation.y += delta * 4.0
            if dist < aggro_range:
                _set_state(State.STALK)
        State.STALK:
            _bob_y()
            visual.rotation.y += delta * 6.0
            if dist > aggro_range * 1.4:
                _set_state(State.IDLE)
            else:
                # Strafe slightly so it doesn't just fly straight in.
                if to_player.length() > 0.01:
                    var n: Vector3 = to_player.normalized()
                    var perp := Vector3(-n.z, 0.0, n.x)
                    var weave := perp * sin(state_time * 3.0) * 0.6
                    var v := n * stalk_speed + weave
                    velocity.x = v.x
                    velocity.z = v.z
                    rotation.y = atan2(-n.x, -n.z)
                if dist < charge_range and (now - _last_charge_at) > CHARGE_COOLDOWN:
                    _begin_charge(to_player)
        State.CHARGE:
            _bob_y_charge()
            visual.rotation.y += delta * 14.0
            attack_hitbox.monitoring = true
            velocity.x = _charge_dir.x * charge_speed
            velocity.z = _charge_dir.z * charge_speed
            if state_time >= CHARGE_DURATION:
                _set_state(State.RECOVER)
        State.RECOVER:
            _bob_y()
            visual.rotation.y += delta * 4.0
            # Drift away from player to give a "peel-off" feel.
            if to_player.length() > 0.01:
                var away: Vector3 = -to_player.normalized()
                velocity.x = away.x * recover_speed
                velocity.z = away.z * recover_speed
            if state_time >= RECOVER_DURATION:
                _set_state(State.STALK if dist < aggro_range else State.IDLE)
        State.DODGE:
            _bob_y()
            visual.rotation.y += delta * 16.0
            velocity.x = _dodge_dir.x * dodge_speed
            velocity.z = _dodge_dir.z * dodge_speed
            if state_time >= DODGE_DURATION:
                _set_state(State.STALK if dist < aggro_range else State.IDLE)
        State.HURT:
            _bob_y()
            velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
            if state_time >= HURT_DURATION:
                _set_state(State.STALK if dist < aggro_range else State.IDLE)

    move_and_slide()


func _bob_y() -> void:
    var target_y := _spawn_y + sin(state_time * 3.0) * HOVER_AMP
    velocity.y = (target_y - global_position.y) * 6.0


# During a charge, hold altitude steady — bobbing during the dart looks
# wrong (the line breaks).
func _bob_y_charge() -> void:
    velocity.y = (_spawn_y - global_position.y) * 4.0


func _begin_charge(to_player: Vector3) -> void:
    var n: Vector3 = to_player
    if n.length() < 0.01:
        n = Vector3.FORWARD
    n = n.normalized()
    _charge_dir = n
    _last_charge_at = Time.get_ticks_msec() / 1000.0
    _contacted_this_charge = false
    rotation.y = atan2(-n.x, -n.z)
    SoundBank.play_3d("blob_alert", global_position)
    _set_state(State.CHARGE)


func _begin_dodge(to_player: Vector3) -> void:
    var n: Vector3 = to_player
    if n.length() < 0.01:
        n = Vector3.FORWARD
    n = n.normalized()
    var perp := Vector3(-n.z, 0.0, n.x)
    if randf() < 0.5:
        perp = -perp
    _dodge_dir = perp
    _set_state(State.DODGE)


func take_damage(amount: int, source_pos: Vector3, _attacker: Node3D = null) -> void:
    if hp <= 0:
        return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0.0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
    if visual:
        visual.scale = Vector3(1.30, 0.85, 1.30)
        var t := create_tween()
        t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    SoundBank.play_3d("enemy_squish", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    _set_state(State.HURT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    attack_hitbox.set_deferred("monitoring", false)
    SoundBank.play_3d("blob_die", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ZERO, 0.25)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-0.3, 0.3), -0.8, randf_range(-0.3, 0.3))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
    if state != State.CHARGE:
        attack_hitbox.set_deferred("monitoring", false)


func _on_attack_overlap(body: Node) -> void:
    if _contacted_this_charge:
        return
    if body.is_in_group("player") and body.has_method("take_damage"):
        _contacted_this_charge = true
        body.take_damage(attack_damage, global_position, self)


# Peeks at tux_player.state.action to detect a committed swing. Falls
# back gracefully if the player exposes no state machine (e.g. test rig).
func _player_is_attacking() -> bool:
    if not player or not is_instance_valid(player):
        return false
    if not "state" in player or player.state == null:
        return false
    var act: int = player.state.action
    return act == TuxState.ACT_ATTACK or act == TuxState.ACT_JAB or act == TuxState.ACT_SPIN
