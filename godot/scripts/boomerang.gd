extends Area3D

# Boomerang projectile. Travels forward up to MAX_DISTANCE, then loops
# back toward the owner. On contact with anything that has take_damage()
# it deals 1 damage and starts the return arc immediately. Caught by
# overlap with the owner player → despawns.
#
# Hits both bodies (enemies, switches that derive from PhysicsBody) and
# areas (Hittable layer hitboxes, like the practice target's child Area).

const SPEED: float = 14.0
const MAX_DISTANCE: float = 7.0
const RETURN_SPEED: float = 16.0
const SPIN_SPEED: float = 30.0

var direction: Vector3 = Vector3.FORWARD
var traveled: float = 0.0
var returning: bool = false
var owner_player: Node3D = null
var hit_set: Array = []


func _ready() -> void:
    collision_layer = 8       # PlayerHitbox
    collision_mask = 36       # Hittable (32) + Enemy (4)
    monitoring = true
    monitorable = false
    body_entered.connect(_on_body_enter)
    area_entered.connect(_on_area_enter)
    SoundBank.play_3d("sword_swing", global_position)


func set_direction(d: Vector3) -> void:
    var dd: Vector3 = d
    dd.y = 0.0
    if dd.length_squared() < 1e-6:
        dd = Vector3(0, 0, -1)
    direction = dd.normalized()


func set_owner_player(p: Node3D) -> void:
    owner_player = p


func _physics_process(delta: float) -> void:
    rotation.y += SPIN_SPEED * delta
    if not returning:
        global_position += direction * SPEED * delta
        traveled += SPEED * delta
        if traveled >= MAX_DISTANCE:
            returning = true
    else:
        if not owner_player or not is_instance_valid(owner_player):
            queue_free()
            return
        var anchor: Vector3 = owner_player.global_position + Vector3(0, 0.8, 0)
        var to_p: Vector3 = anchor - global_position
        var dist: float = to_p.length()
        if dist < 0.6:
            queue_free()
            return
        global_position += to_p.normalized() * RETURN_SPEED * delta


func _on_body_enter(body: Node) -> void:
    if body == owner_player:
        return
    if body in hit_set:
        return
    hit_set.append(body)
    if body.has_method("take_damage"):
        body.take_damage(1, global_position)
        SoundBank.play_3d("sword_hit", global_position)
        returning = true


func _on_area_enter(area: Area3D) -> void:
    if area in hit_set:
        return
    hit_set.append(area)
    var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
    if receiver and receiver.has_method("take_damage"):
        receiver.take_damage(1, global_position)
        SoundBank.play_3d("sword_hit", global_position)
        returning = true
