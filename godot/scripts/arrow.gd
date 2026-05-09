extends Area3D

# Arrow projectile fired by the bow. Travels in a straight line with a
# light gravity arc so longer-range shots droop a touch — gives the
# weapon a learnable lob without making short-range plinking awkward.
#
# Hits enemies via the Hittable layer (32) and sticks briefly to world
# geometry on a body overlap. The world stick mainly exists so missed
# shots don't fly forever before the lifetime cap clears them.

const GRAVITY: float = 6.0          # gentle arc; arrows are not fish-bombs
const LIFETIME: float = 4.0
const STUCK_LINGER: float = 0.6
const DAMAGE: int = 2

var velocity: Vector3 = Vector3.ZERO
var owner_player: Node = null

var _life: float = 0.0
var _stuck: bool = false
var _stuck_t: float = 0.0
var _hit_set: Array = []


func _ready() -> void:
    # 0 layer so nothing scans us; mask covers world (1) + Hittable (32)
    # so we collide with enemy hitbox areas and static walls/floors.
    collision_layer = 0
    collision_mask = 1 | 32
    monitoring = true
    monitorable = false
    body_entered.connect(_on_body_entered)
    area_entered.connect(_on_area_entered)


func setup(initial_velocity: Vector3, shooter: Node = null) -> void:
    velocity = initial_velocity
    owner_player = shooter
    _orient_to_velocity()


func _physics_process(delta: float) -> void:
    _life += delta
    if _life >= LIFETIME:
        queue_free()
        return
    if _stuck:
        _stuck_t += delta
        if _stuck_t >= STUCK_LINGER:
            queue_free()
        return
    velocity.y -= GRAVITY * delta
    global_position += velocity * delta
    _orient_to_velocity()


func _orient_to_velocity() -> void:
    if velocity.length_squared() < 1e-4:
        return
    # The arrow shaft mesh runs along +X (see arrow.tscn), so look_at
    # would mis-aim. Manually point +X at the velocity vector.
    var fwd: Vector3 = velocity.normalized()
    var up: Vector3 = Vector3.UP
    if abs(fwd.dot(up)) > 0.99:
        up = Vector3.FORWARD
    var right: Vector3 = up.cross(fwd).normalized()
    var new_up: Vector3 = fwd.cross(right).normalized()
    # Basis columns: x=fwd, y=new_up, z=right (so the +X shaft aims at fwd)
    transform.basis = Basis(fwd, new_up, right)


func _on_area_entered(area: Area3D) -> void:
    if _stuck or area in _hit_set:
        return
    var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
    if not receiver or not receiver.has_method("take_damage"):
        return
    if owner_player and receiver == owner_player:
        return
    _hit_set.append(area)
    receiver.take_damage(DAMAGE, global_position, owner_player)
    SoundBank.play_3d("sword_hit", global_position)
    queue_free()


func _on_body_entered(body: Node) -> void:
    if _stuck:
        return
    if owner_player and body == owner_player:
        return
    if body.has_method("take_damage"):
        if body in _hit_set:
            return
        _hit_set.append(body)
        body.take_damage(DAMAGE, global_position, owner_player)
        SoundBank.play_3d("sword_hit", global_position)
        queue_free()
        return
    # World hit — stick briefly so the arrow visibly lodges, then despawn.
    _stuck = true
    velocity = Vector3.ZERO
    set_collision_mask_value(1, false)
