extends Area3D

# Sword hit volume. Mostly signal-driven (area_entered + body_entered),
# but with a one-shot deferred sweep on arm() to catch contacts that
# were already inside the volume when monitoring turned on. Without
# the sweep, horizontal slashes whiffed against any enemy you were
# standing close enough to overlap on the very first tick of the
# active window — they were already inside, no "enter" event ever
# fired, and only the overhead chop (which moves into the enemy from
# above) registered.
#
# arm()    : clear hit set, monitoring → true, queue a sweep
# disarm() : monitoring → false (deferred)
#
# The sweep awaits one physics_frame so the area's overlap state is
# accurate after we just toggled monitoring on, and re-checks
# monitoring before each query so a disarm() in flight can't trip
# Godot's "monitoring is off" guard.

signal target_hit(target: Node)

@export var damage: int = 1

var _already_hit: Array = []
var _arm_cycle: int = 0


func _ready() -> void:
    monitoring = false
    set_physics_process(false)
    area_entered.connect(_on_area_entered)
    body_entered.connect(_on_body_entered)


func arm() -> void:
    _already_hit.clear()
    monitoring = true
    _arm_cycle += 1
    _initial_overlap_pass(_arm_cycle)


func disarm() -> void:
    set_deferred("monitoring", false)


func _initial_overlap_pass(cycle: int) -> void:
    # One physics tick has to elapse before the engine's overlap data
    # reflects the monitoring change.
    await get_tree().physics_frame
    if cycle != _arm_cycle:
        return                # superseded by a newer arm()
    if not is_inside_tree() or not monitoring:
        return
    for area in get_overlapping_areas():
        _on_area_entered(area)
    if not monitoring:
        return
    for body in get_overlapping_bodies():
        _on_body_entered(body)


func _on_area_entered(area: Area3D) -> void:
    if not monitoring or area in _already_hit:
        return
    var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
    if not receiver or not receiver.has_method("take_damage"):
        return
    _already_hit.append(area)
    receiver.take_damage(damage, global_position, _find_attacker())
    target_hit.emit(receiver)


func _on_body_entered(body: Node) -> void:
    if not monitoring or body in _already_hit:
        return
    if not body.has_method("take_damage"):
        return
    _already_hit.append(body)
    body.take_damage(damage, global_position, _find_attacker())
    target_hit.emit(body)


func _find_attacker() -> Node:
    var n: Node = get_parent()
    while n:
        if n is CharacterBody3D:
            return n
        n = n.get_parent()
    return null
