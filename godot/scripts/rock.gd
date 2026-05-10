extends RigidBody3D

# Pickup-and-throw rock. Press the interact key while standing next to
# one to lift it overhead, press again to throw it. While carried it
# follows the player; on throw it launches forward and on impact with
# anything other than the player it shatters into a pebble pickup.
#
# Sword can also break a stationary rock without picking it up — same
# take_damage path the bushes use.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")

@export var pebble_chance: float = 0.45
@export var carry_offset: Vector3 = Vector3(0, 1.6, -0.1)
@export var throw_speed: float = 12.0

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var prompt_area: Area3D = $PromptArea

var _carrier: Node3D = null
var _is_carried: bool = false
var _has_been_thrown: bool = false
var _shattered: bool = false


func _ready() -> void:
    add_to_group("ground_snap")
    add_to_group("rock")
    hitbox.set_deferred("collision_layer", 32)
    hitbox.set_deferred("collision_mask", 0)
    hitbox.set_deferred("monitorable", true)
    hitbox.set_deferred("monitoring", false)
    prompt_area.body_entered.connect(_on_prompt_enter)
    prompt_area.body_exited.connect(_on_prompt_exit)
    contact_monitor = true
    max_contacts_reported = 4
    body_entered.connect(_on_body_entered)


func _physics_process(_delta: float) -> void:
    if _is_carried and is_instance_valid(_carrier):
        var t: Transform3D = _carrier.global_transform
        global_position = t.origin + t.basis * carry_offset
        linear_velocity = Vector3.ZERO
        angular_velocity = Vector3.ZERO


func _on_prompt_enter(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    _carrier = body
    if body.has_method("set_carry_target"):
        body.set_carry_target(self)


func _on_prompt_exit(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    if _carrier == body and not _is_carried:
        _carrier = null
        if body.has_method("set_carry_target"):
            body.set_carry_target(null)


func pick_up(by: Node3D) -> void:
    if _is_carried or _shattered: return
    _carrier = by
    _is_carried = true
    freeze = true
    collision_layer = 0  # don't block the carrier while carried
    collision_mask = 0


func throw(direction: Vector3) -> void:
    if not _is_carried: return
    _is_carried = false
    freeze = false
    collision_layer = 1
    collision_mask = 1
    _has_been_thrown = true
    var d: Vector3 = direction
    d.y = 0.0
    if d.length() < 0.01:
        d = Vector3(0, 0, -1)
    d = d.normalized()
    linear_velocity = d * throw_speed + Vector3(0, 4.0, 0)


func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
                 _attacker: Node3D = null) -> void:
    _shatter()


func _on_body_entered(body: Node) -> void:
    if not _has_been_thrown or _shattered:
        return
    if body == _carrier:
        return
    _shatter()


func _shatter() -> void:
    if _shattered: return
    _shattered = true
    hitbox.set_deferred("monitorable", false)
    SoundBank.play_3d("rock_break", global_position)
    var here: Vector3 = global_position
    if randf() < pebble_chance:
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(0, 0.2, 0)
        var parent: Node = get_parent()
        if parent:
            parent.call_deferred("add_child", p)
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ZERO, 0.15)
    t.tween_callback(queue_free)
