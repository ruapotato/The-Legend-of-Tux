extends Area3D

# Sword hit volume. Signal-driven so we never poll get_overlapping_*
# while monitoring is in transition (the prior _physics_process polling
# tripped Godot's internal "monitoring is off" guard whenever an
# enemy's _set_state deferred a monitoring=false on the same hitbox).
#
#   arm()    : clear hit set, enable monitoring, schedule a deferred
#              one-shot pass over already-overlapping objects (entries
#              that happened BEFORE we armed don't fire body_entered)
#   disarm() : monitoring → false (deferred)
#
# area_entered / body_entered fire as new contacts come in while armed.
# Every receiver is dispatched at most once per arm cycle.

signal target_hit(target: Node)

@export var damage: int = 1

var _already_hit: Array = []


func _ready() -> void:
    monitoring = false
    area_entered.connect(_on_area_entered)
    body_entered.connect(_on_body_entered)
    # Nothing to do in physics_process anymore.
    set_physics_process(false)


func arm() -> void:
    _already_hit.clear()
    monitoring = true
    # Anything that was inside our volume BEFORE we armed won't fire
    # the entry signals. Defer one frame so the engine has registered
    # the monitoring switch, then sweep the existing overlaps.
    call_deferred("_initial_overlap_pass")


func disarm() -> void:
    set_deferred("monitoring", false)


func _initial_overlap_pass() -> void:
    if not monitoring:
        return
    for area in get_overlapping_areas():
        _on_area_entered(area)
    for body in get_overlapping_bodies():
        _on_body_entered(body)


func _on_area_entered(area: Area3D) -> void:
    if not monitoring:
        return
    if area in _already_hit:
        return
    var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
    if not receiver or not receiver.has_method("take_damage"):
        return
    _already_hit.append(area)
    receiver.take_damage(damage, global_position, _find_attacker())
    target_hit.emit(receiver)


func _on_body_entered(body: Node) -> void:
    if not monitoring:
        return
    if body in _already_hit:
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
