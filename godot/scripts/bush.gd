extends Node3D

# Cuttable shrub. Sword hits destroy it, with a percentage chance of
# dropping a pebble or a fish (heart). Modeled on the OoT bush — they
# don't fight back, they just give you free pickups when chopped.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")
const HeartPickup  := preload("res://scenes/pickup_heart.tscn")

@export var drop_chance:    float = 0.55
@export var pebble_weight:  float = 0.70   # share of drops that are pebbles
@export var fish_weight:    float = 0.30   # remainder = fish (heart)
@export var pebble_amount:  int   = 1

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox

var _destroyed: bool = false


func _ready() -> void:
    add_to_group("ground_snap")
    # Sit on layer 32 (same as enemies) so the sword's collision_mask=32
    # picks us up. Deferred because some _ready paths reach here from
    # inside an area-overlap signal callback.
    hitbox.set_deferred("collision_layer", 32)
    hitbox.set_deferred("collision_mask", 0)
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", true)


func take_damage(_amount: int = 1, _source_pos: Vector3 = Vector3.ZERO,
                 _attacker: Node3D = null) -> void:
    if _destroyed:
        return
    _destroyed = true
    if Engine.has_singleton("SoundBank") or get_tree().root.has_node("SoundBank"):
        SoundBank.play_3d("bush_cut", global_position)
    hitbox.set_deferred("monitorable", false)
    _drop_loot()
    _mark_destroyed()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3(1.0, 0.05, 1.0), 0.18)
    t.tween_callback(queue_free)


# Procedural-world persistence hook — see wood_bush.gd. The prop_id meta
# is stamped at spawn by world_chunk.apply_data; hand-placed bushes have
# no meta and this is a silent no-op.
func _mark_destroyed() -> void:
    if not has_meta("prop_id"):
        return
    if GameState == null:
        return
    GameState.destroyed_props[String(get_meta("prop_id"))] = true


func _drop_loot() -> void:
    if randf() > drop_chance:
        return
    var here: Vector3 = global_position
    var parent: Node = get_parent()
    if parent == null:
        return
    var roll: float = randf() * (pebble_weight + fish_weight)
    var p: Node3D
    if roll < pebble_weight:
        p = PebblePickup.instantiate()
        if "pebble_amount" in p:
            p.pebble_amount = pebble_amount
    else:
        p = HeartPickup.instantiate()
    # Set local position before deferring add — parent (dungeon root)
    # is at origin so local == global, and reading our transform after
    # queue_free fires would warn.
    p.position = here + Vector3(0, 0.35, 0)
    parent.call_deferred("add_child", p)
