extends Area3D

# Sword hit volume. Per-physics-tick polling approach: each frame
# while armed, sweep get_overlapping_areas() and get_overlapping_bodies()
# and dispatch each new contact through the same code path as
# area_entered / body_entered. This catches the case where the player
# is standing close enough that the sword is already overlapping the
# enemy on the very first tick of the active window — signal-only
# detection misses those because no "enter" event ever fires.
#
# Two-flag arm tracking:
#   _wants_armed : script-side intent, set immediately by arm()/disarm()
#   monitoring   : engine state, set via set_deferred to dodge the
#                  "Function blocked during in/out signal" guard
#
# _physics_process bails unless BOTH flags are true. So the brief
# window where monitoring trails _wants_armed (or vice versa) never
# trips the engine's get_overlapping_* "monitoring is off" check.
#
# Set DEBUG = false once tuning is done. Right now it prints every
# arm / disarm and every hit dispatch so combat issues are diagnosable.

const DEBUG: bool = true

signal target_hit(target: Node)

@export var damage: int = 1

var _already_hit: Array = []
var _wants_armed: bool = false


func _ready() -> void:
    monitoring = false
    set_physics_process(false)
    area_entered.connect(_on_area_entered)
    body_entered.connect(_on_body_entered)


func arm() -> void:
    if _wants_armed:
        return
    _wants_armed = true
    _already_hit.clear()
    monitoring = true
    set_physics_process(true)
    if DEBUG:
        print("[%s] ARM" % _label())


func disarm() -> void:
    if not _wants_armed:
        return
    _wants_armed = false
    set_deferred("monitoring", false)
    if DEBUG:
        print("[%s] DISARM" % _label())


func _physics_process(_delta: float) -> void:
    if not _wants_armed or not monitoring:
        return
    var areas := get_overlapping_areas()
    var bodies := get_overlapping_bodies()
    if DEBUG and (areas.size() > 0 or bodies.size() > 0):
        var anames: Array = []
        var bnames: Array = []
        for a in areas: anames.append(a.name)
        for b in bodies: bnames.append(b.name)
        print("[%s] poll areas=%s bodies=%s already=%d"
              % [_label(), anames, bnames, _already_hit.size()])
    for area in areas:
        if not monitoring:
            return
        _on_area_entered(area)
    for body in bodies:
        if not monitoring:
            return
        _on_body_entered(body)


func _on_area_entered(area: Area3D) -> void:
    if not monitoring or area in _already_hit:
        return
    var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
    if not receiver or not receiver.has_method("take_damage"):
        if DEBUG:
            print("[%s] area %s skipped (no take_damage on %s or parent)"
                  % [_label(), area.name, area.name])
        return
    _already_hit.append(area)
    if DEBUG:
        print("[%s] HIT area=%s receiver=%s" % [_label(), area.name, receiver.name])
    receiver.take_damage(damage, global_position, _find_attacker())
    target_hit.emit(receiver)


func _on_body_entered(body: Node) -> void:
    if not monitoring or body in _already_hit:
        return
    if not body.has_method("take_damage"):
        if DEBUG:
            print("[%s] body %s skipped (no take_damage)" % [_label(), body.name])
        return
    _already_hit.append(body)
    if DEBUG:
        print("[%s] HIT body=%s" % [_label(), body.name])
    body.take_damage(damage, global_position, _find_attacker())
    target_hit.emit(body)


func _find_attacker() -> Node:
    var n: Node = get_parent()
    while n:
        if n is CharacterBody3D:
            return n
        n = n.get_parent()
    return null


# A reasonably descriptive identifier for log lines. Walks up the tree
# until the scene root so you can tell which knight/player a hitbox
# belongs to.
func _label() -> String:
    var parts: Array = []
    var n: Node = self
    var depth: int = 0
    while n and depth < 4:
        parts.push_front(n.name)
        n = n.get_parent()
        depth += 1
    return "/".join(parts)
