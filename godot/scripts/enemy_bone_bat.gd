extends CharacterBody3D

# Bone bat — small flying enemy. Hovers in place, swoops at the player
# when in range, then climbs back to its perch. One-shot kill from any
# sword hit. Wings flap visually but the rig is static — flight is
# driven by velocity, not animation.

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")

signal died

@export var max_hp: int = 1
@export var pebble_reward: int = 1

const DETECT_RANGE: float = 9.0
const SWOOP_SPEED: float = 9.0
const RECOVER_SPEED: float = 4.5
const ATTACK_DAMAGE: int = 1
const KNOCKBACK_SPEED: float = 5.5
const SWOOP_DURATION: float = 0.65
const HURT_DURATION: float = 0.30
const SWOOP_END_DIST: float = 0.8     # finish swoop when this close to target

enum State { HOVER, SWOOP, RECOVER, HURT, DEAD }

var hp: int = 1
var state: int = State.HOVER
var state_time: float = 0.0
var player: Node3D = null
var swoop_target: Vector3 = Vector3.ZERO
var perch_y: float = 2.8

@onready var visual: Node3D = $Visual
@onready var wing_l: Node3D = $Visual/WingL
@onready var wing_r: Node3D = $Visual/WingR
@onready var hitbox: Area3D = $Hitbox
@onready var attack_hitbox: Area3D = $AttackHitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    perch_y = global_position.y
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0:
        player = ps[0]
    attack_hitbox.body_entered.connect(_on_attack_overlap)
    attack_hitbox.monitoring = false


func _physics_process(delta: float) -> void:
    state_time += delta
    if state == State.DEAD:
        velocity.y -= 24.0 * delta
        move_and_slide()
        return

    var to_player := Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        dist = to_player.length()

    match state:
        State.HOVER:
            _do_hover(delta, to_player, dist)
        State.SWOOP:
            _do_swoop(delta, dist)
        State.RECOVER:
            _do_recover(delta)
        State.HURT:
            _do_hurt(delta)

    _flap_wings(delta)
    move_and_slide()


func _do_hover(_delta: float, to_player: Vector3, dist: float) -> void:
    # Slow drift + altitude bob to keep it alive when player isn't close.
    velocity.x = sin(state_time * 0.7) * 1.0
    velocity.z = cos(state_time * 0.5) * 1.0
    var target_y: float = perch_y + sin(state_time * 1.5) * 0.2
    velocity.y = (target_y - global_position.y) * 4.0
    if dist < DETECT_RANGE and player:
        swoop_target = player.global_position + Vector3(0, 0.4, 0)
        _set_state(State.SWOOP)
        SoundBank.play_3d("blob_alert", global_position)


func _do_swoop(_delta: float, dist: float) -> void:
    attack_hitbox.monitoring = true
    var dir: Vector3 = swoop_target - global_position
    if dir.length_squared() > 1e-6:
        var n: Vector3 = dir.normalized()
        velocity = n * SWOOP_SPEED
        rotation.y = atan2(-n.x, -n.z)
    if state_time > SWOOP_DURATION or dist < SWOOP_END_DIST:
        _set_state(State.RECOVER)


func _do_recover(_delta: float) -> void:
    attack_hitbox.set_deferred("monitoring", false)
    var rise: Vector3 = Vector3(global_position.x, perch_y, global_position.z) - global_position
    if rise.length_squared() > 0.01:
        velocity = rise.normalized() * RECOVER_SPEED
    else:
        velocity = Vector3.ZERO
    if abs(global_position.y - perch_y) < 0.3:
        _set_state(State.HOVER)


func _do_hurt(delta: float) -> void:
    velocity = velocity.lerp(Vector3.ZERO, clamp(delta * 4.0, 0.0, 1.0))
    if state_time >= HURT_DURATION:
        _set_state(State.HOVER)


func _flap_wings(delta: float) -> void:
    var freq: float = 18.0 if state == State.SWOOP else 9.0
    var amp: float = 0.7
    var a: float = sin(state_time * freq) * amp
    if wing_l:
        wing_l.rotation.z = -0.4 + a
    if wing_r:
        wing_r.rotation.z = 0.4 - a


func take_damage(amount: int, source_pos: Vector3) -> void:
    if hp <= 0:
        return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    if away.length_squared() < 1e-6:
        away = Vector3(0, 0, 1)
    away = away.normalized()
    velocity = away * KNOCKBACK_SPEED + Vector3(0, 2.0, 0)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


# Mirrors the blob/knight signature so player parry/block can shove
# the bat the same way.
func get_knockback(direction: Vector3, force: float) -> void:
    velocity = direction * force + Vector3(0, 4.0, 0)
    _set_state(State.HURT)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.monitoring = false
    hitbox.monitorable = false
    attack_hitbox.set_deferred("monitoring", false)
    SoundBank.play_3d("blob_die", global_position)
    var parent: Node = get_parent()
    if parent:
        for i in range(pebble_reward):
            var p := PebblePickup.instantiate()
            parent.add_child(p)
            p.global_position = global_position + Vector3(randf_range(-0.4, 0.4), -1.0, randf_range(-0.4, 0.4))
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ZERO, 0.30)
    t.tween_callback(queue_free)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0
    if state != State.SWOOP:
        attack_hitbox.set_deferred("monitoring", false)


func _on_attack_overlap(body: Node) -> void:
    if body.is_in_group("player") and body.has_method("take_damage"):
        body.take_damage(ATTACK_DAMAGE, global_position, self)
