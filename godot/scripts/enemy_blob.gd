extends CharacterBody3D

# Simple "blob" enemy: a wobbling slime that idles in place, gives chase
# when the player crosses its sight range, and lunges into a contact
# attack at melee range. Knockback on hit, ragdoll-flat on death.
#
# State machine is inline — small enough that pulling it into a separate
# RefCounted (as we did for Tux) would just be overhead.

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const HeartPickup = preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 3
@export var sight_range: float = 8.0
@export var attack_range: float = 1.7
@export var move_speed: float = 3.0
@export var lunge_speed: float = 7.0
@export var attack_damage: int = 1
@export var pebble_reward: int = 2
@export var heart_drop_chance: float = 0.25

const KNOCKBACK_SPEED: float = 8.0
const GRAVITY: float = 24.0
const WIND_UP_TIME: float = 0.45
const ATTACK_LUNGE_TIME: float = 0.22
const RECOVER_TIME: float = 0.40
const HURT_TIME: float = 0.28

enum State { IDLE, CHASE, WIND_UP, ATTACK, RECOVER, HURT, DEAD }

var hp: int = 3
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null

@onready var visual: Node3D = $Visual
@onready var attack_hitbox: Area3D = $AttackHitbox
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    attack_hitbox.body_entered.connect(_on_attack_overlap)
    attack_hitbox.monitoring = false


# Enemies are added to the tree before the player in our generated
# dungeons, so _ready can't find Tux in the "player" group yet — Tux
# adds himself there in HIS _ready, which runs later in the cascade.
# Lazy-fetch each frame until we get a valid reference.
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
            visual.scale = Vector3(1.0, 1.0 + sin(state_time * 2.0) * 0.04, 1.0)
            if dist < sight_range:
                _set_state(State.CHASE)
        State.CHASE:
            visual.scale = Vector3.ONE
            if dist < attack_range:
                _set_state(State.WIND_UP)
            elif dist > sight_range * 1.6:
                _set_state(State.IDLE)
            else:
                var dir := to_player.normalized()
                velocity.x = dir.x * move_speed
                velocity.z = dir.z * move_speed
                rotation.y = atan2(-dir.x, -dir.z)
        State.WIND_UP:
            velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
            # Compress as we wind up — telegraphs the lunge.
            var sq: float = clamp(state_time / WIND_UP_TIME, 0.0, 1.0)
            visual.scale = Vector3(1.0 + sq * 0.25, 1.0 - sq * 0.30, 1.0 + sq * 0.25)
            if state_time >= WIND_UP_TIME:
                _set_state(State.ATTACK)
        State.ATTACK:
            if state_time < ATTACK_LUNGE_TIME:
                attack_hitbox.monitoring = true
                var fwd := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
                velocity.x = fwd.x * lunge_speed
                velocity.z = fwd.z * lunge_speed
                visual.scale = Vector3(0.85, 1.30, 0.85)
            else:
                attack_hitbox.monitoring = false
                _set_state(State.RECOVER)
        State.RECOVER:
            visual.scale = Vector3.ONE
            velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
            if state_time >= RECOVER_TIME:
                _set_state(State.CHASE if dist < sight_range else State.IDLE)
        State.HURT:
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            visual.scale = Vector3(0.85, 1.20, 0.85)
            if state_time >= HURT_TIME:
                visual.scale = Vector3.ONE
                _set_state(State.CHASE if dist < sight_range else State.IDLE)

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0

    move_and_slide()


# Sword hits and other Hittable-layer damage funnel through here.
func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0.0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
        velocity.y = 4.0
    _hit_punch()
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


# Brief scale "punch" on the visual when hit — the physics knockback
# alone doesn't read as a hit unless the body squashes.
func _hit_punch() -> void:
    if not visual:
        return
    visual.scale = Vector3(1.20, 0.85, 1.20)
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    # Deferred — _die reaches us from inside an area_entered signal
    # (sword hits the blob's hitbox), and direct monitoring/monitorable
    # writes are blocked while the signal is in flight.
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    attack_hitbox.set_deferred("monitoring", false)
    SoundBank.play_3d("blob_die", global_position)
    _drop_loot()
    died.emit()
    # Flatten into a puddle then disappear.
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3(1.5, 0.05, 1.5), 0.20)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        parent.call_deferred("add_child", p)
        var off := Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
        p.global_position = global_position + off
    if randf() < heart_drop_chance:
        var h := HeartPickup.instantiate()
        parent.call_deferred("add_child", h)
        h.global_position = global_position + Vector3(0, 0.0, 0)


func _set_state(new_state: int) -> void:
    var prev := state
    state = new_state
    state_time = 0.0
    if state != State.ATTACK:
        # Deferred — _set_state can be called inside the attack hitbox's
        # body_entered signal (player blocks → get_knockback → HURT),
        # and Godot disallows toggling monitoring during the in/out
        # signal of that very Area3D.
        attack_hitbox.set_deferred("monitoring", false)
    # Audio cues for state transitions worth hearing.
    if state == State.CHASE and prev == State.IDLE:
        SoundBank.play_3d("blob_alert", global_position)
    elif state == State.ATTACK and prev == State.WIND_UP:
        SoundBank.play_3d("blob_attack", global_position)


func _on_attack_overlap(body: Node) -> void:
    if body.is_in_group("player") and body.has_method("take_damage"):
        body.take_damage(attack_damage, global_position, self)


# Called by the player when their shield deflects this enemy's attack.
# The blob is shoved away with vertical lift, then drops into HURT so
# it can't immediately re-lunge.
func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 4.0
    _set_state(State.HURT)
