extends CharacterBody3D

# Tomato Giant — a slow lumbering brute. Telegraphs a heavy slam for ~0.6s
# (parry window), then sweeps both arms forward in a hit that pushes the
# player back hard. High HP, generous loot drop.
#
# State machine:
#   IDLE     — standing in place, idle wobble
#   CHASE    — waddling toward the player, swaying side to side
#   WIND_UP  — arms raised overhead, body crouches; long telegraph
#   SLAM     — arms swing forward, brief active hitbox window
#   RECOVER  — arms hang, brief vulnerability window
#   HURT     — knockback bounce
#   DEAD     — flatten + despawn

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const HeartPickup = preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 18
@export var sight_range: float = 12.0
@export var attack_range: float = 3.0
@export var move_speed: float = 1.6
@export var attack_damage: int = 3
@export var pebble_reward_min: int = 4
@export var pebble_reward_max: int = 6
@export var heart_drop_count: int = 2

const KNOCKBACK_SPEED: float = 6.0
const PLAYER_PUSH_SPEED: float = 5.0
const GRAVITY: float = 24.0
const WIND_UP_TIME: float = 0.6
const SLAM_DURATION: float = 0.30
const SLAM_HIT_WINDOW: Vector2 = Vector2(0.05, 0.20)
const RECOVER_TIME: float = 0.65
const HURT_TIME: float = 0.30
# Direct-hit cone for the slam — Area3D overlap can be unreliable when
# the body is wider than the active window, so we backstop with a
# distance + facing test like the bone knight.
const ATTACK_REACH: float = 3.4
const ATTACK_CONE_DOT: float = 0.25

enum State { IDLE, CHASE, WIND_UP, SLAM, RECOVER, HURT, DEAD }

var hp: int = 18
var state: int = State.IDLE
var state_time: float = 0.0
var player: Node3D = null
var _slam_landed: bool = false

@onready var visual: Node3D = $Visual
@onready var arm_l: Node3D = $Visual/ArmL
@onready var arm_r: Node3D = $Visual/ArmR
@onready var stem: Node3D = $Visual/Stem
@onready var attack_hitbox: Area3D = $AttackHitbox
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
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
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            visual.scale = Vector3(1.0, 1.0 + sin(state_time * 1.4) * 0.03, 1.0)
            _animate_idle_arms(delta)
            if dist < sight_range:
                _set_state(State.CHASE)
        State.CHASE:
            if dist < attack_range:
                _set_state(State.WIND_UP)
            elif dist > sight_range * 1.5:
                _set_state(State.IDLE)
            else:
                var dir := to_player.normalized()
                velocity.x = dir.x * move_speed
                velocity.z = dir.z * move_speed
                rotation.y = atan2(-dir.x, -dir.z)
                # Waddle: lean L/R as we walk.
                visual.rotation.z = sin(state_time * 4.0) * 0.10
                _animate_idle_arms(delta)
        State.WIND_UP:
            velocity.x = move_toward(velocity.x, 0.0, 12.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 12.0 * delta)
            if to_player.length_squared() > 1e-6:
                var dir2 := to_player.normalized()
                rotation.y = atan2(-dir2.x, -dir2.z)
            var t: float = clampf(state_time / WIND_UP_TIME, 0.0, 1.0)
            # Crouch + raise arms.
            visual.scale = Vector3(1.0 + t * 0.10, 1.0 - t * 0.20, 1.0 + t * 0.10)
            visual.rotation.z = 0.0
            arm_l.rotation.x = lerpf(0.0, -2.4, t)
            arm_r.rotation.x = lerpf(0.0, -2.4, t)
            if state_time >= WIND_UP_TIME:
                _set_state(State.SLAM)
        State.SLAM:
            velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
            var u: float = clampf(state_time / SLAM_DURATION, 0.0, 1.0)
            # Arms slam from overhead down past horizontal.
            arm_l.rotation.x = lerpf(-2.4, 0.6, u)
            arm_r.rotation.x = lerpf(-2.4, 0.6, u)
            visual.scale = Vector3.ONE.lerp(Vector3(1.10, 0.92, 1.10), 1.0 - u)
            if state_time >= SLAM_HIT_WINDOW.x and state_time <= SLAM_HIT_WINDOW.y:
                attack_hitbox.monitoring = true
                _direct_slam_check()
            else:
                attack_hitbox.set_deferred("monitoring", false)
            if state_time >= SLAM_DURATION:
                _set_state(State.RECOVER)
        State.RECOVER:
            velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)
            visual.scale = Vector3.ONE
            arm_l.rotation.x = lerpf(0.6, 0.0, clampf(state_time / RECOVER_TIME, 0.0, 1.0))
            arm_r.rotation.x = lerpf(0.6, 0.0, clampf(state_time / RECOVER_TIME, 0.0, 1.0))
            if state_time >= RECOVER_TIME:
                _set_state(State.CHASE if dist < sight_range else State.IDLE)
        State.HURT:
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            visual.scale = Vector3(1.10, 0.90, 1.10)
            if state_time >= HURT_TIME:
                visual.scale = Vector3.ONE
                _set_state(State.CHASE if dist < sight_range else State.IDLE)

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0
    move_and_slide()


func _animate_idle_arms(_delta: float) -> void:
    var sway := sin(state_time * 2.0) * 0.15
    arm_l.rotation.x = sway
    arm_r.rotation.x = -sway


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
    _hit_punch()
    SoundBank.play_3d("hurt", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func _hit_punch() -> void:
    if not visual:
        return
    visual.scale = Vector3(1.20, 0.85, 1.20)
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# When the slam hitbox or direct-cone test catches the player, push them
# back along the attack vector rather than just damaging in place.
func _push_player(target: Node) -> void:
    if not target.is_in_group("player"):
        return
    var away: Vector3 = target.global_position - global_position
    away.y = 0.0
    if away.length() > 0.01:
        away = away.normalized()
        if "velocity" in target:
            target.velocity.x = away.x * PLAYER_PUSH_SPEED
            target.velocity.z = away.z * PLAYER_PUSH_SPEED
            target.velocity.y = 3.5


func _direct_slam_check() -> void:
    if _slam_landed or not player or not is_instance_valid(player):
        return
    var to_p: Vector3 = player.global_position - global_position
    to_p.y = 0.0
    var d := to_p.length()
    if d <= 0.05 or d >= ATTACK_REACH:
        return
    var fwd := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
    if fwd.dot(to_p / d) < ATTACK_CONE_DOT:
        return
    _slam_landed = true
    if player.has_method("take_damage"):
        player.take_damage(attack_damage, global_position, self)
    _push_player(player)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    attack_hitbox.set_deferred("monitoring", false)
    SoundBank.play_3d("death", global_position)
    _drop_loot()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3(1.6, 0.05, 1.6), 0.35)
    t.tween_callback(queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    var n := randi_range(pebble_reward_min, pebble_reward_max)
    for i in range(n):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-1.2, 1.2), 0.0, randf_range(-1.2, 1.2))
        parent.call_deferred("add_child", p)
    for i in range(heart_drop_count):
        var h := HeartPickup.instantiate()
        h.position = here + Vector3(randf_range(-0.6, 0.6), 0.0, randf_range(-0.6, 0.6))
        parent.call_deferred("add_child", h)


func _set_state(new_state: int) -> void:
    var prev := state
    state = new_state
    state_time = 0.0
    if state != State.SLAM:
        attack_hitbox.set_deferred("monitoring", false)
        _slam_landed = false
    if state == State.CHASE and prev == State.IDLE:
        SoundBank.play_3d("blob_alert", global_position)
    elif state == State.SLAM:
        SoundBank.play_3d("blob_attack", global_position)


func _on_attack_overlap(body: Node) -> void:
    if _slam_landed:
        return
    if body.is_in_group("player") and body.has_method("take_damage"):
        _slam_landed = true
        body.take_damage(attack_damage, global_position, self)
        _push_player(body)


# Mirrors the other enemies — lets the player parry/block shove the
# tomato away with vertical lift.
func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    velocity.y = 4.0
    _set_state(State.HURT)
