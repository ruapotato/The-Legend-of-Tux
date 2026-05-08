extends CharacterBody3D

# Spore Drifter — slow floating fungal mote. No melee. When the player
# enters aggro range, it drops a SPORE CLOUD at its current position
# (an Area3D that ticks damage on contact for ~2s) and then drifts
# away. Very low HP — one decent sword swing kills it, but the cloud
# lingers as a hazard.
#
# State machine:
#   DRIFT    — slow ambient bobbing, no player in range
#   APPROACH — player in aggro range, spore not on cooldown — drift in
#              a bit closer before releasing
#   RELEASE  — spawns the cloud at current position
#   RETREAT  — back away while the cloud is alive (~2s)
#   HURT     — bounce when hit
#   DEAD     — burst into a dust pop

const PebblePickup = preload("res://scenes/pickup_pebble.tscn")
const HeartPickup = preload("res://scenes/pickup_heart.tscn")

signal died

@export var max_hp: int = 3
@export var aggro_range: float = 10.0
@export var release_range: float = 6.5
@export var drift_speed: float = 1.6
@export var retreat_speed: float = 2.6
@export var spore_cooldown: float = 3.0
@export var pebble_reward: int = 1

const HOVER_HEIGHT: float = 1.6
const HOVER_AMP: float = 0.18
const KNOCKBACK_SPEED: float = 5.0
const HURT_TIME: float = 0.30
const RETREAT_TIME: float = 2.0
const SPORE_LIFETIME: float = 2.0
const SPORE_TICK_INTERVAL: float = 0.5
const SPORE_TICK_DAMAGE: int = 1
const SPORE_RADIUS: float = 1.4

enum State { DRIFT, APPROACH, RELEASE, RETREAT, HURT, DEAD }

var hp: int = 3
var state: int = State.DRIFT
var state_time: float = 0.0
var player: Node3D = null
var _spawn_y: float = 1.6
var _spore_ready_at: float = 0.0   # absolute time (sec) when next spore allowed

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox


func _ready() -> void:
    hp = max_hp
    add_to_group("enemy")
    _spawn_y = global_position.y
    if _spawn_y < 0.5:
        _spawn_y = HOVER_HEIGHT
        global_position.y = _spawn_y


func _ensure_player() -> void:
    if player == null or not is_instance_valid(player):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.size() > 0:
            player = ps[0]


func _physics_process(delta: float) -> void:
    state_time += delta
    if state == State.DEAD:
        return
    _ensure_player()

    var to_player := Vector3.ZERO
    var dist: float = 1e9
    if player and is_instance_valid(player):
        to_player = player.global_position - global_position
        to_player.y = 0.0
        dist = to_player.length()

    var now: float = Time.get_ticks_msec() / 1000.0

    match state:
        State.DRIFT:
            _bob_y()
            velocity.x = sin(state_time * 0.6) * 0.5
            velocity.z = cos(state_time * 0.5) * 0.5
            visual.rotation.y += delta * 1.5
            if dist < aggro_range and now >= _spore_ready_at:
                _set_state(State.APPROACH)
        State.APPROACH:
            _bob_y()
            visual.rotation.y += delta * 2.0
            if dist <= release_range or state_time > 1.5:
                _set_state(State.RELEASE)
            else:
                var dir := to_player
                if dir.length() > 0.001:
                    var n: Vector3 = dir.normalized()
                    velocity.x = n.x * drift_speed
                    velocity.z = n.z * drift_speed
        State.RELEASE:
            _bob_y()
            velocity.x = move_toward(velocity.x, 0.0, 8.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 8.0 * delta)
            visual.scale = Vector3.ONE * (1.0 + sin(state_time * 18.0) * 0.06)
            if state_time >= 0.20:
                _spawn_spore_cloud()
                _spore_ready_at = now + spore_cooldown
                _set_state(State.RETREAT)
        State.RETREAT:
            _bob_y()
            visual.rotation.y += delta * 3.0
            var away: Vector3 = -to_player
            if away.length() > 0.001:
                var an: Vector3 = away.normalized()
                velocity.x = an.x * retreat_speed
                velocity.z = an.z * retreat_speed
            if state_time >= RETREAT_TIME:
                _set_state(State.DRIFT)
        State.HURT:
            _bob_y()
            velocity.x = move_toward(velocity.x, 0.0, 6.0 * delta)
            velocity.z = move_toward(velocity.z, 0.0, 6.0 * delta)
            if state_time >= HURT_TIME:
                _set_state(State.DRIFT)

    move_and_slide()


func _bob_y() -> void:
    var target_y := _spawn_y + sin(state_time * 1.8) * HOVER_AMP
    velocity.y = (target_y - global_position.y) * 4.0


func take_damage(amount: int, source_pos: Vector3, _attacker: Node3D = null) -> void:
    if hp <= 0:
        return
    hp -= amount
    var away: Vector3 = global_position - source_pos
    away.y = 0.0
    if away.length() > 0.01:
        away = away.normalized()
        velocity.x = away.x * KNOCKBACK_SPEED
        velocity.z = away.z * KNOCKBACK_SPEED
    if visual:
        visual.scale = Vector3(1.30, 0.85, 1.30)
        var t := create_tween()
        t.tween_property(visual, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
    SoundBank.play_3d("enemy_squish", global_position)
    if hp <= 0:
        _die()
    else:
        _set_state(State.HURT)


func get_knockback(direction: Vector3, force: float) -> void:
    velocity.x = direction.x * force
    velocity.z = direction.z * force
    _set_state(State.HURT)


# Build the spore cloud Area3D in code so the enemy scene stays simple.
# The cloud is parented to our parent (dungeon root) so it persists when
# we move away or die. It self-despawns after SPORE_LIFETIME.
func _spawn_spore_cloud() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var cloud := SporeCloud.new()
    cloud.position = global_position
    parent.call_deferred("add_child", cloud)
    SoundBank.play_3d("blob_attack", global_position)


func _die() -> void:
    state = State.DEAD
    state_time = 0.0
    hitbox.set_deferred("monitoring", false)
    hitbox.set_deferred("monitorable", false)
    SoundBank.play_3d("blob_die", global_position)
    _drop_loot()
    _spawn_dust_pop()
    died.emit()
    var t := create_tween()
    t.tween_property(visual, "scale", Vector3.ZERO, 0.30)
    t.tween_callback(queue_free)


# Pop visual: a few small spheres that float briefly upward, then are
# freed. We attach them to our parent so they survive past queue_free.
func _spawn_dust_pop() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(5):
        var dust := MeshInstance3D.new()
        var m := SphereMesh.new()
        m.radius = 0.10
        m.height = 0.20
        m.radial_segments = 6
        m.rings = 3
        dust.mesh = m
        var mat := StandardMaterial3D.new()
        mat.albedo_color = Color(0.65, 0.78, 0.45, 0.85)
        mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        mat.emission_enabled = true
        mat.emission = Color(0.50, 0.70, 0.30, 1.0)
        mat.emission_energy_multiplier = 0.5
        dust.material_override = mat
        var off := Vector3(randf_range(-0.3, 0.3), randf_range(-0.1, 0.2), randf_range(-0.3, 0.3))
        dust.position = here + off
        parent.call_deferred("add_child", dust)
        var rise := here + off + Vector3(0, 0.6, 0)
        var t := dust.create_tween()
        t.tween_property(dust, "position", rise, 0.6)
        t.parallel().tween_property(dust, "scale", Vector3.ZERO, 0.6)
        t.tween_callback(dust.queue_free)


func _drop_loot() -> void:
    var parent: Node = get_parent()
    if parent == null:
        return
    var here: Vector3 = global_position
    for i in range(pebble_reward):
        var p := PebblePickup.instantiate()
        p.position = here + Vector3(randf_range(-0.4, 0.4), -1.0, randf_range(-0.4, 0.4))
        parent.call_deferred("add_child", p)


func _set_state(new_state: int) -> void:
    state = new_state
    state_time = 0.0


# ---- Spore cloud inner class -----------------------------------------
# Uses a class_name-less inner so we can keep this enemy in one file.
# Ticks SPORE_TICK_DAMAGE on the player every SPORE_TICK_INTERVAL while
# the player is overlapping. Self-despawns after SPORE_LIFETIME.
class SporeCloud extends Area3D:
    var _life: float = 0.0
    var _next_tick: float = 0.0
    var _lifetime: float = 2.0
    var _radius: float = 1.4
    var _tick_dmg: int = 1
    var _tick_int: float = 0.5
    var _mesh: MeshInstance3D
    var _shape: CollisionShape3D

    func _ready() -> void:
        # Cloud overlaps the player layer (2). collision_layer 0 — purely
        # detection, never collides.
        collision_layer = 0
        collision_mask = 2
        monitoring = true
        monitorable = false
        var sh := SphereShape3D.new()
        sh.radius = _radius
        _shape = CollisionShape3D.new()
        _shape.shape = sh
        add_child(_shape)
        _mesh = MeshInstance3D.new()
        var m := SphereMesh.new()
        m.radius = _radius
        m.height = _radius * 2.0
        m.radial_segments = 12
        m.rings = 6
        _mesh.mesh = m
        var mat := StandardMaterial3D.new()
        mat.albedo_color = Color(0.55, 0.78, 0.40, 0.35)
        mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        mat.emission_enabled = true
        mat.emission = Color(0.45, 0.70, 0.30, 1.0)
        mat.emission_energy_multiplier = 0.4
        mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _mesh.material_override = mat
        add_child(_mesh)
        # Soft drift up a bit while alive — feels like dispersing gas.

    func _process(delta: float) -> void:
        _life += delta
        # Fade alpha toward end of life.
        if _mesh and _mesh.material_override is StandardMaterial3D:
            var mat: StandardMaterial3D = _mesh.material_override
            var t: float = clampf(_life / _lifetime, 0.0, 1.0)
            var a := lerpf(0.40, 0.0, t)
            mat.albedo_color = Color(mat.albedo_color.r, mat.albedo_color.g, mat.albedo_color.b, a)
        # Damage tick.
        if _life >= _next_tick:
            _next_tick = _life + _tick_int
            for body in get_overlapping_bodies():
                if body.is_in_group("player") and body.has_method("take_damage"):
                    body.take_damage(_tick_dmg, global_position, self)
        if _life >= _lifetime:
            queue_free()
