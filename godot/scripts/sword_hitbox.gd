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

const DEBUG: bool = false

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
        var p: Vector3 = global_position
        var enemy_info: Array = []
        for e in get_tree().get_nodes_in_group("enemy"):
            if e is Node3D:
                var ep: Vector3 = e.global_position
                var d: float = p.distance_to(ep)
                enemy_info.append("%s @ (%.2f,%.2f,%.2f) dist=%.2f"
                                  % [e.name, ep.x, ep.y, ep.z, d])
        print("[%s] ARM pos=(%.2f,%.2f,%.2f) | enemies: %s"
              % [_label(), p.x, p.y, p.z, ", ".join(enemy_info) if enemy_info.size() > 0 else "(none)"])


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
    if DEBUG:
        # Always print on poll so we can confirm polling is running and
        # see what the hitbox sees each tick (even when nothing — that
        # tells us whether it's a reach issue vs a dispatch issue).
        var anames: Array = []
        var bnames: Array = []
        for a in areas: anames.append(a.name)
        for b in bodies: bnames.append(b.name)
        var p: Vector3 = global_position
        print("[%s] tick pos=(%.2f,%.2f,%.2f) areas=%s bodies=%s already=%d"
              % [_label(), p.x, p.y, p.z, anames, bnames, _already_hit.size()])
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
    _push_kill_cmd(receiver)
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
    _push_kill_cmd(body)
    target_hit.emit(body)


# Terminal-corner hook. Only the player's hitbox should narrate kills
# in the live shell — enemy sword_hitboxes (bone knights, etc.) share
# this script and must NOT push commands as if Tux ran them. We gate
# on the owning CharacterBody3D being in the "player" group.
func _push_kill_cmd(target: Object) -> void:
    var attacker: Node = _find_attacker()
    if attacker == null or not attacker.is_in_group("player"):
        return
    var tl: Node = get_node_or_null("/root/TerminalLog")
    if tl == null or target == null or not (target is Object):
        return
    var pid: int = target.get_instance_id() if target.has_method("get_instance_id") else 0
    var label: String = String(target.get("name")) if "name" in target else "PID%d" % pid
    if label == "":
        label = "PID%d" % pid
    tl.cmd("kill %s" % label)


func _find_attacker() -> Node:
    var n: Node = get_parent()
    while n:
        if n is CharacterBody3D:
            return n
        n = n.get_parent()
    return null


# Identifier for log lines. Walks up to the owning CharacterBody3D so
# you can tell whether a print is from the player's hitbox or one of
# the knights' (otherwise both share the path arm_r/Sword/SwordHitbox
# and the prints are indistinguishable).
func _label() -> String:
    var owner: String = "?"
    var n: Node = get_parent()
    while n:
        if n is CharacterBody3D:
            owner = n.name
            break
        n = n.get_parent()
    return "%s/SwordHitbox" % owner
