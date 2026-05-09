extends StaticBody3D

# Cracked stone wall. Solid at first; takes damage via a child Area3D
# on the Hittable layer (32). Sword strikes register but don't crack
# it — only a bomb-grade explosion (≥3 dmg) shatters the cluster. The
# sword path is kept so combat tests still produce visible take_damage
# logs without needing to throw a bomb.

const SHATTER_DAMAGE_THRESHOLD: int = 3

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
@onready var collision: CollisionShape3D = $Collision

var _shattered: bool = false


func _ready() -> void:
    add_to_group("destructible_wall")
    collision_layer = 1
    collision_mask = 0
    if hitbox:
        hitbox.collision_layer = 32
        hitbox.collision_mask = 0
        hitbox.monitorable = true
        hitbox.monitoring = false


# Bomb explosion / sword hit dispatch path. `amount` is the magnitude of
# the hit; sword swings come in at 1, bombs at 4.
func take_damage(amount: int, _source_pos: Vector3 = Vector3.ZERO,
                 _attacker: Node3D = null) -> void:
    if _shattered:
        return
    if amount < SHATTER_DAMAGE_THRESHOLD:
        # Light hit — sparkle/shake but don't break. Keeping this path
        # in so the player gets feedback ("this is breakable, try
        # something stronger") on a sword swing.
        _shake()
        return
    _shatter()


func _shake() -> void:
    if not visual:
        return
    var t := create_tween()
    var orig: Vector3 = visual.position
    t.tween_property(visual, "position", orig + Vector3(0.05, 0, 0), 0.04)
    t.tween_property(visual, "position", orig + Vector3(-0.05, 0, 0), 0.06)
    t.tween_property(visual, "position", orig, 0.04)


func _shatter() -> void:
    _shattered = true
    SoundBank.play_3d("crystal_hit", global_position)
    # Disable physics + hitbox immediately so the player can pass and
    # subsequent blast waves don't double-hit.
    if collision:
        collision.set_deferred("disabled", true)
    if hitbox:
        hitbox.set_deferred("monitorable", false)
    if visual:
        var t := create_tween().set_parallel(true)
        t.tween_property(visual, "scale", Vector3(0.05, 0.05, 0.05), 0.35)
        t.tween_property(visual, "rotation:y", visual.rotation.y + 1.5, 0.35)
        t.chain().tween_callback(queue_free)
    else:
        queue_free()
