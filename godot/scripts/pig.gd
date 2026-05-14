extends CharacterBody3D

# Wandering pig. Same idle/walk/flee loop as deer/sheep, 4 HP, meat-only
# drop. Mesh layout adapted from hamberg's flying-pig minus the wings —
# pigs in Tux are strictly grounded. Bobs more bouncily than deer/sheep
# because the silhouette is rounder; reads as a trotting waddle.

const MeatPickup := preload("res://scenes/pickup_meat.tscn")

@export var max_hp: int = 4
@export var walk_speed: float = 2.0
@export var flee_speed: float = 5.0

const GRAVITY: float = 24.0
const FLEE_TIME: float = 3.0
const AI_RADIUS_SQ: float = 60.0 * 60.0

enum State { IDLE, WALK, FLEE }

var hp: int = 4
var state: int = State.IDLE
var state_time: float = 0.0
var state_duration: float = 0.0
var move_dir: Vector3 = Vector3.ZERO
var _player_ref: Node3D = null
var _bob_phase: float = 0.0

@onready var _visual: Node3D = $Visual


func _ready() -> void:
    hp = max_hp
    add_to_group("animal")
    _bob_phase = randf() * TAU
    _enter_idle()


func _physics_process(delta: float) -> void:
    if _player_ref == null or not is_instance_valid(_player_ref):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.is_empty():
            return
        _player_ref = ps[0] as Node3D
    if global_position.distance_squared_to(_player_ref.global_position) > AI_RADIUS_SQ:
        return
    state_time += delta

    match state:
        State.IDLE:
            velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
            if state_time >= state_duration:
                _enter_walk()
        State.WALK:
            velocity.x = move_dir.x * walk_speed
            velocity.z = move_dir.z * walk_speed
            if move_dir.length_squared() > 0.0001:
                rotation.y = atan2(-move_dir.x, -move_dir.z)
            if state_time >= state_duration:
                _enter_idle()
        State.FLEE:
            velocity.x = move_dir.x * flee_speed
            velocity.z = move_dir.z * flee_speed
            if move_dir.length_squared() > 0.0001:
                rotation.y = atan2(-move_dir.x, -move_dir.z)
            if state_time >= state_duration:
                _enter_idle()

    if not is_on_floor():
        velocity.y -= GRAVITY * delta
    else:
        velocity.y = -1.0

    move_and_slide()
    _update_bob(delta)


# Bigger amplitude than deer/sheep — pigs read as bouncy when they trot.
func _update_bob(delta: float) -> void:
    if _visual == null:
        return
    var speed_factor: float = 0.0
    if state == State.WALK:
        speed_factor = 7.0
    elif state == State.FLEE:
        speed_factor = 15.0
    _bob_phase += delta * speed_factor
    _visual.position.y = sin(_bob_phase) * (0.05 if state == State.FLEE else 0.025)


func _enter_idle() -> void:
    state = State.IDLE
    state_time = 0.0
    state_duration = randf_range(1.0, 3.0)
    move_dir = Vector3.ZERO


func _enter_walk() -> void:
    state = State.WALK
    state_time = 0.0
    state_duration = randf_range(2.0, 4.0)
    var ang := randf() * TAU
    move_dir = Vector3(sin(ang), 0.0, cos(ang))


# Hit comes in via the child Hitbox Area3D (layer 32) — sword_hitbox's
# area-side dispatch parent-fallbacks to this CharacterBody3D.
func take_damage(amount: int, source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    hp -= amount
    if hp <= 0:
        _die()
        return
    state = State.FLEE
    state_time = 0.0
    state_duration = FLEE_TIME
    var away: Vector3 = global_position - source_pos
    away.y = 0.0
    if away.length() > 0.001:
        move_dir = away.normalized()
    else:
        var ang := randf() * TAU
        move_dir = Vector3(sin(ang), 0.0, cos(ang))


func _die() -> void:
    if GameState and GameState.has_method("add_resource"):
        GameState.add_resource("meat_raw", 1)
    _mark_destroyed()
    SoundBank.play_3d("bush_cut", global_position)
    queue_free()


# Procedural-world persistence hook. Animals can wander far from their
# spawn position, so we don't use position to identify them — instead we
# read back the prop_id meta stamped at spawn by world_chunk.apply_data.
# Hand-placed pigs (no meta) silently no-op.
func _mark_destroyed() -> void:
    if not has_meta("prop_id"):
        return
    if GameState == null:
        return
    GameState.destroyed_props[String(get_meta("prop_id"))] = true
