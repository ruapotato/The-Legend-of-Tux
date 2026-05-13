extends CharacterBody3D

# Wandering deer. Idle/walk loop with a flee response when hit. Drops
# meat (always) and antler (50%) on death. Modeled after enemy_blob.gd
# but lighter — no chase, no attack, no targeting; it just exists.

const MeatPickup   := preload("res://scenes/pickup_meat.tscn")
const AntlerPickup := preload("res://scenes/pickup_antler.tscn")

@export var max_hp: int = 5
@export var walk_speed: float = 2.0
@export var flee_speed: float = 5.0
@export var antler_chance: float = 0.5

const GRAVITY: float = 24.0
const FLEE_TIME: float = 3.0

# Only run AI within this radius of the player. Beyond, _physics_process
# returns immediately — without this, 70+ active animals tanked FPS
# into single digits since every one ran move_and_slide each frame.
const AI_RADIUS_SQ: float = 60.0 * 60.0

enum State { IDLE, WALK, FLEE }

var hp: int = 5
var state: int = State.IDLE
var state_time: float = 0.0
var state_duration: float = 0.0
var move_dir: Vector3 = Vector3.ZERO
var _player_ref: Node3D = null


func _ready() -> void:
    hp = max_hp
    add_to_group("animal")
    _enter_idle()


func _physics_process(delta: float) -> void:
    # Distance-throttle: skip all AI + physics when the player is
    # outside the active radius. Saves ~95% of the per-frame cost
    # across the full streaming ring.
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


# Sword / arrow hits funnel through here — same signature as enemy_blob's
# take_damage so existing weapon code (which only knows the two-arg form)
# stays compatible.
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
        # Hit from dead-overhead — pick any horizontal direction so the
        # deer still bolts instead of standing still mid-flee.
        var ang := randf() * TAU
        move_dir = Vector3(sin(ang), 0.0, cos(ang))


func _die() -> void:
    var parent: Node = get_parent()
    if parent:
        var meat := MeatPickup.instantiate()
        meat.position = global_position + Vector3(0, 0.5, 0)
        parent.call_deferred("add_child", meat)
        if randf() < antler_chance:
            var antler := AntlerPickup.instantiate()
            antler.position = global_position + Vector3(0.3, 0.5, 0)
            parent.call_deferred("add_child", antler)
    queue_free()
