extends RigidBody3D

# Throwable / placeable bomb. Once spawned, a 2.5 s fuse ticks down with
# a sparking light on top; on detonation a brief Area3D opens, deals 4
# damage to enemies in a 3 m radius (with knockback away from the blast)
# and 1 damage to the player if they're caught in the blast. Then frees.
#
# The bomb has no input handling of its own — Tux throws/places it from
# tux_state.gd; bomb_flower.gd also instantiates one of these once its
# fuse logic decides the picked bomb has cooked off.
#
# `damage_amount` is exposed so destructible_wall.gd can branch on the
# magnitude (≥3 = bomb-grade explosion; weaker hits don't crack stone).

const FUSE_TIME: float          = 2.5
const EXPLOSION_RADIUS: float   = 3.0
const ENEMY_DAMAGE: int         = 4
const PLAYER_DAMAGE: int        = 1
const ENEMY_KNOCKBACK: float    = 9.0
const PLAYER_KNOCKBACK: float   = 6.0
const EXPLOSION_LIFETIME: float = 0.18

@onready var visual: Node3D = $Visual
@onready var fuse_light: OmniLight3D = $Visual/FuseLight

var _fuse_time_left: float = FUSE_TIME
var _exploded: bool = false


func _ready() -> void:
    add_to_group("bomb")
    contact_monitor = true
    max_contacts_reported = 4
    mass = 4.0
    physics_material_override = PhysicsMaterial.new()
    physics_material_override.bounce = 0.15
    physics_material_override.friction = 0.85


func _process(delta: float) -> void:
    if _exploded:
        return
    _fuse_time_left -= delta
    if _fuse_time_left <= 0.0:
        _explode()
        return
    # Sparking pulse — base flicker + ramp brighter as detonation nears.
    var t_remaining: float = clamp(_fuse_time_left / FUSE_TIME, 0.0, 1.0)
    var base: float = lerp(2.6, 0.8, t_remaining)
    if fuse_light:
        fuse_light.light_energy = base + randf() * 0.6
    # Last-half-second visual: scale-pulse the body so the player can
    # tell the moment is imminent.
    if visual and _fuse_time_left < 0.6:
        var pulse: float = 1.0 + sin(_fuse_time_left * 40.0) * 0.10
        visual.scale = Vector3(pulse, pulse, pulse)
    elif visual:
        visual.scale = Vector3.ONE


# Explodes immediately, regardless of fuse — used by bomb_flower when the
# player carries the picked bomb past its fuse, or by bomb-on-bomb chain.
func detonate_now() -> void:
    if _exploded:
        return
    _fuse_time_left = 0.0
    _explode()


func _explode() -> void:
    if _exploded:
        return
    _exploded = true
    SoundBank.play_3d("crystal_hit", global_position)

    var here: Vector3 = global_position
    # Build a transient Area3D for the blast and let it sweep its
    # overlaps for one tick so we catch enemies/walls already inside
    # the radius. layer=0, mask=32+2 (Hittable + Player).
    var blast := Area3D.new()
    blast.collision_layer = 0
    blast.collision_mask = 32 | 2
    blast.monitoring = true
    blast.monitorable = false
    var shape := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = EXPLOSION_RADIUS
    shape.shape = sphere
    blast.add_child(shape)
    var scene_root: Node = get_tree().current_scene
    if scene_root == null:
        queue_free()
        return
    scene_root.add_child(blast)
    blast.global_position = here

    # Hide the body visual and disable collision so the explosion
    # graphic can play on top of where it sat.
    if visual:
        visual.visible = false
    set_deferred("freeze", true)

    # Spawn a quick flash + expanding sphere as the visual.
    _spawn_blast_visual(scene_root, here)

    # Defer the overlap sweep one frame so the area can register, then
    # one more frame to free.
    blast.call_deferred("set", "name", "BombBlast")
    var sweeper := Timer.new()
    sweeper.one_shot = true
    sweeper.wait_time = 0.05
    blast.add_child(sweeper)
    sweeper.timeout.connect(func() -> void:
        _apply_blast_to_overlaps(blast, here))
    sweeper.start()

    var killer := Timer.new()
    killer.one_shot = true
    killer.wait_time = EXPLOSION_LIFETIME
    blast.add_child(killer)
    killer.timeout.connect(func() -> void:
        if is_instance_valid(blast):
            blast.queue_free())
    killer.start()

    queue_free()


func _apply_blast_to_overlaps(blast: Area3D, here: Vector3) -> void:
    if not is_instance_valid(blast):
        return
    var areas: Array = blast.get_overlapping_areas()
    var bodies: Array = blast.get_overlapping_bodies()
    var hit_set: Array = []
    for area in areas:
        var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
        if not receiver or not (receiver is Node) or hit_set.has(receiver):
            continue
        if receiver.has_method("take_damage"):
            hit_set.append(receiver)
            receiver.take_damage(ENEMY_DAMAGE, here, null)
            _apply_knockback(receiver, here, ENEMY_KNOCKBACK)
    for body in bodies:
        if hit_set.has(body):
            continue
        if body.is_in_group("player") and body.has_method("take_damage"):
            hit_set.append(body)
            body.take_damage(PLAYER_DAMAGE, here, null)
            _apply_knockback(body, here, PLAYER_KNOCKBACK)
        elif body.has_method("take_damage"):
            hit_set.append(body)
            body.take_damage(ENEMY_DAMAGE, here, null)
            _apply_knockback(body, here, ENEMY_KNOCKBACK)


func _apply_knockback(target: Object, blast_pos: Vector3, force: float) -> void:
    if not (target is Node3D):
        return
    if not target.has_method("get_knockback"):
        return
    var dir: Vector3 = (target as Node3D).global_position - blast_pos
    dir.y = 0.0
    if dir.length() < 0.001:
        dir = Vector3(1, 0, 0)
    dir = dir.normalized()
    target.get_knockback(dir, force)


func _spawn_blast_visual(scene_root: Node, here: Vector3) -> void:
    var fx := MeshInstance3D.new()
    var sphere := SphereMesh.new()
    sphere.radius = 0.3
    sphere.height = 0.6
    sphere.radial_segments = 12
    sphere.rings = 6
    fx.mesh = sphere
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1.0, 0.85, 0.35, 0.85)
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mat.emission_enabled = true
    mat.emission = Color(1.0, 0.7, 0.25)
    mat.emission_energy_multiplier = 3.0
    fx.material_override = mat
    scene_root.add_child(fx)
    fx.global_position = here
    var t := create_tween().set_parallel(true)
    var final_scale: float = EXPLOSION_RADIUS * 1.7
    t.tween_property(fx, "scale", Vector3(final_scale, final_scale, final_scale), 0.25)
    t.tween_property(mat, "albedo_color:a", 0.0, 0.25)
    t.chain().tween_callback(fx.queue_free)

    var flash := OmniLight3D.new()
    flash.light_color = Color(1.0, 0.75, 0.35)
    flash.light_energy = 6.0
    flash.omni_range = EXPLOSION_RADIUS * 2.0
    scene_root.add_child(flash)
    flash.global_position = here + Vector3(0, 0.3, 0)
    var ft := create_tween()
    ft.tween_property(flash, "light_energy", 0.0, 0.30)
    ft.tween_callback(flash.queue_free)
