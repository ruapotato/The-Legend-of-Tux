extends Area3D

# Sword hit volume. Pure signal-driven: no _physics_process, no calls
# to get_overlapping_* anywhere — the script literally cannot trip
# Godot's "monitoring is off" guard because it never queries physics
# state directly.
#
# Trade-off: if a body is ALREADY inside the volume when arm() flips
# monitoring on, area_entered/body_entered won't fire (the contact
# didn't "enter" — it was already there). For sword swings this is
# almost never an issue because the blade is sweeping through space
# during the active window, so each contact happens during arm.

signal target_hit(target: Node)

@export var damage: int = 1

var _already_hit: Array = []


func _ready() -> void:
    monitoring = false
    set_physics_process(false)
    area_entered.connect(_on_area_entered)
    body_entered.connect(_on_body_entered)


func arm() -> void:
    _already_hit.clear()
    monitoring = true


func disarm() -> void:
    set_deferred("monitoring", false)


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
