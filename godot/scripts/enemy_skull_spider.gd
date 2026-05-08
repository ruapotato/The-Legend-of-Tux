extends CharacterBody3D

# Skull Spider — small, crouched, leaping ambusher. Telegraphs briefly
# then arcs through the air at the player's last known position. Lands,
# pauses, leaps again. Inspired by the OoT Skullwalltula/Skulltula:
# easy to kill but the leap range and arc punish standing still.
#
# State machine:
#   IDLE     — perched, subtle bob, watching for the player
#   TELEG    — pre-leap crouch (0.3s), legs splay outward
#   LEAP     — airborne; gravity-driven parabola toward the leap target
#   RECOVER  — landed; brief pause before re-engaging
#   HURT     — knockback bounce
#   DEAD     — flatten + despawn

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const HeartPickup = preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 4
@export var aggro_range: float = 6.0
@export var pebble_reward: int = 2
@export var heart_drop_chance: float = 0.30
@export var contact_damage: int = 1

const TELEG_TIME: float = 0.30
const RECOVER_TIME: float = 0.60
const HURT_TIME: float = 0.25
const LEAP_UP_VEL: float = 6.0
const LEAP_HORIZ_SPEED: float = 4.5
const LEAP_MAX_HORIZ: float = 6.5      # cap horizontal leap distance
const LEAP_TIME_CAP: float = 1.2       # safety cap so an off-arc leap still ends
const CONTACT_RADIUS: float = 1.2
const KNOCKBACK_SPEED: float = 5.0
const GRAVITY: float = 24.0

enum State { IDLE, TELEG, LEAP, RECOVER, HURT, DEAD }

var hp: int = 4
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _leap_landed: bool = false

@onready var visual: Node3D = $Visual
@onready var body_mesh: Node3D = $Visual/BodyMesh
@onready var legs_root: Node3D = $Visual/Legs
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")


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

    match state:
        State.IDLE:
            velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
            # Gentle bob so it's not totally static.
            visual.scale = Vector3(1.0, 1.0 + sin(state_time * 2.4) * 0.05, 1.0)
            if dist < aggro_range and player:
                _set_state(State.TELEG)
        State.TELEG:
            velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
            # Crouch + splay legs.
            var t: float = clampf(state_time / TELEG_TIME, 0.0, 1.0)
            visual.scale = Vector3(1.0 + t * 0.20, 1.0 - t * 0.30, 1.0 + t * 0.20)
            _splay_legs(t)
            # Face the player while telegraphing.
            if to_player.length_squared() > 1e-6:
                var n := to_player.normalized()
                rotation.y = atan2(-n.x, -n.z)
            if state_time >= TELEG_TIME:
                _begin_leap()
        State.LEAP:
            velocity.y -= GRAVITY * delta
            # Wiggle legs while airborne for life.
            var w: float = sin(state_time * 18.0) * 0.30
            if legs_root:
                legs_root.rotation.x = w * 0.5
                legs_root.rotation.z = w
            _check_leap_contact()
            if (is_on_floor() and state_time > 0.10) or state_time >= LEAP_TIME_CAP:
                _set_state(State.RECOVER)
        State.RECOVER:
            velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
            visual.scale = Vector3.ONE
            if legs_root:
                legs_root.rotation = Vector3.ZERO
            if state_time >= RECOVER_TIME:
                _set_state(State.IDLE)
        State.HURT:
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            visual.scale = Vector3(1.20, 0.85, 1.20)
            if state_time >= HURT_TIME:
                visual.scale = Vector3.ONE
                _set_state(State.IDLE)

    if state != State.LEAP:
        if not is_on_floor():
            velocity.y -= GRAVITY * delta
        else:
            velocity.y = -1.0

    move_and_slide()


func _splay_legs(t: float) -> void:
    if not legs_root:
        return
    legs_root.scale = Vector3(1.0 + t * 0.25, 1.0, 1.0 + t * 0.25)


func _begin_leap() -> void:
    _leap_landed = false
    var target_xz: Vector3 = Vector3.ZERO
    if player and is_instance_valid(player):
        target_xz = player.global_position - global_position
        target_xz.y = 0.0
    if target_xz.length() < 0.01:
        target_xz = Vector3(0, 0, -1)
    var d: float = min(target_xz.length(), LEAP_MAX_HORIZ)
    var dir: Vector3 = target_xz.normalized()
    velocity.x = dir.x * LEAP_HORIZ_SPEED * (d / max(LEAP_MAX_HORIZ, 0.01) + 0.5)
    velocity.z = dir.z * LEAP_HORIZ_SPEED * (d / max(LEAP_MAX_HORIZ, 0.01) + 0.5)
    velocity.y = LEAP_UP_VEL
    SoundBank.play_3d("blob_attack", global_position)
    _set_state(State.LEAP)


func _check_leap_contact() -> void:
    if _leap_landed or not player or not is_instance_valid(player):
        return
    var to_p: Vector3 = player.global_position - global_position
    if to_p.length() > CONTACT_RADIUS:
        return
    _leap_landed = true
    if player.has_method("take_damage"):
        player.take_damage(contact_damage, global_position, self)
    if "velocity" in player:
        var away: Vector3 = player.global_position - global_position
        away.y = 0.0
        if away.length() > 0.01:
            away = away.normalized()
            player.velocity.x = away.x * 4.0
            player.velocity.z = away.z * 4.0
            player.velocity.y = 2.5


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
        velocity.y = 3.0
    if visual:
        visual.scale = Vector3(1.20, 0.85, 1.20)
        var t := create_tween()
        t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    SoundBank.play_3d("hurt", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 3.0
    _set_state(State.HURT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    SoundBank.play_3d("blob_die", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3(1.4, 0.05, 1.4), 0.25)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-0.4, 0.4), 0.0, randf_range(-0.4, 0.4))
        parent.call_deferred("add_child", p)
    if randf() < heart_drop_chance:
        var h := HeartPickup.instantiate()
        h.position = here + Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3))
        parent.call_deferred("add_child", h)


func _set_state(new_state: int) -> void:
    var prev := state
    state = new_state
    state_time = 0.0
    if state == State.TELEG and prev == State.IDLE:
        SoundBank.play_3d("blob_alert", global_position)
