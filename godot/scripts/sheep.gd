extends CharacterBody3D

# Wandering sheep. Same idle/walk/flee loop as the deer, lower HP, no
# antler drop. Kept as a separate script (rather than parameterising
# deer.gd) so each species can diverge later — sheep get sheared, deer
# don't.

const MeatPickup := preload("res://scenes/pickup_meat.tscn")

@export var max_hp: int = 3
@export var walk_speed: float = 2.0
@export var flee_speed: float = 5.0

const GRAVITY: float = 24.0
const FLEE_TIME: float = 3.0

enum State { IDLE, WALK, FLEE }

var hp: int = 3
var state: int = State.IDLE
var state_time: float = 0.0
var state_duration: float = 0.0
var move_dir: Vector3 = Vector3.ZERO


func _ready() -> void:
    hp = max_hp
    add_to_group("animal")
    _enter_idle()


func _physics_process(delta: float) -> void:
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
    var parent: Node = get_parent()
    if parent:
        var meat := MeatPickup.instantiate()
        meat.position = global_position + Vector3(0, 0.5, 0)
        parent.call_deferred("add_child", meat)
    queue_free()
