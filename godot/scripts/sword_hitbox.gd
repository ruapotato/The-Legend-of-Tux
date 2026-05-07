extends Area3D

# Sword hit volume. Disabled by default; the owner turns it on during
# the active window of a swing animation and listens for overlaps.
#
# Used by both the player (hits enemies / hittable areas) and enemies
# (hits the player). Checks BOTH overlapping areas (e.g., the practice
# target's child Hitbox) AND overlapping bodies (e.g., the player's
# CharacterBody3D), calling take_damage on whichever responds.
#
# Guards against the "monitoring is off" race that fires when an owner
# disables monitoring via set_deferred — we now gate _physics_process
# on the live `monitoring` property, not on a script-side flag.

signal target_hit(target: Node)

@export var damage: int = 1

var _already_hit: Array = []


func _ready() -> void:
    monitoring = false


func arm() -> void:
    if monitoring:
        return
    _already_hit.clear()
    monitoring = true


func disarm() -> void:
    set_deferred("monitoring", false)


func _physics_process(_delta: float) -> void:
    if not monitoring:
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
    for body in get_overlapping_bodies():
        if body in _already_hit:
            continue
        if not body.has_method("take_damage"):
            continue
        _already_hit.append(body)
        body.take_damage(damage, global_position, _find_attacker())
        target_hit.emit(body)


# Walk up the tree to whichever ancestor is the actual fighter (player
# or enemy CharacterBody3D). The hitbox is typically a few levels deep
# (e.g., Knight/Sword/SwordHitbox) so we crawl until we find a node
# with a `velocity` property — the universal sign of a movable body.
func _find_attacker() -> Node:
    var n: Node = get_parent()
    while n:
        if n is CharacterBody3D:
            return n
        n = n.get_parent()
    return null
