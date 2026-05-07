extends Area3D

# Sword hit volume. Disabled by default; the player controller turns it
# on during the active window of a swing animation and listens for
# overlaps. The collision mask filters which layers count as "hittable"
# so we don't need a group check here.
#
# When an overlap fires, we call take_damage on the area first (for
# self-contained Area3D switches like hit_switch.gd) and fall back to
# the area's parent (for nested setups like Practice/Hitbox where the
# parent owns the HP).

signal target_hit(target: Node)

@export var damage: int = 1

var _enabled: bool = false
var _already_hit: Array = []


func _ready() -> void:
    monitoring = false


func arm() -> void:
    if _enabled:
        return
    _enabled = true
    _already_hit.clear()
    monitoring = true


func disarm() -> void:
    _enabled = false
    monitoring = false


func _physics_process(_delta: float) -> void:
    if not _enabled:
        return
    for area in get_overlapping_areas():
        if area in _already_hit:
            continue
        var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
        if not receiver or not receiver.has_method("take_damage"):
            continue
        _already_hit.append(area)
        receiver.take_damage(damage, global_position)
        target_hit.emit(receiver)
