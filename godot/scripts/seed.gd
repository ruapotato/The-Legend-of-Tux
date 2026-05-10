extends Area3D

# Slingshot pellet. Faster and flatter than the arrow but only deals 1
# damage and despawns quickly — meant for plinking small things from
# range or stunning a flying target into the dirt.

const LIFETIME: float = 1.5
const DAMAGE: int = 1

var velocity: Vector3 = Vector3.ZERO
var owner_player: Node = null

var _life: float = 0.0
var _hit_set: Array = []


func _ready() -> void:
    collision_layer = 0
    collision_mask = 1 | 32
    monitoring = true
    monitorable = false
    body_entered.connect(_on_body_entered)
    area_entered.connect(_on_area_entered)
    SoundBank.play_3d("seed_fire", global_position)


func setup(initial_velocity: Vector3, shooter: Node = null) -> void:
    velocity = initial_velocity
    owner_player = shooter


func _physics_process(delta: float) -> void:
    _life += delta
    if _life >= LIFETIME:
        queue_free()
        return
    # No gravity — seeds are small and travel flat over their short life.
    global_position += velocity * delta


func _on_area_entered(area: Area3D) -> void:
    if area in _hit_set:
        return
    var receiver: Object = area if area.has_method("take_damage") else area.get_parent()
    if not receiver or not receiver.has_method("take_damage"):
        return
    if owner_player and receiver == owner_player:
        return
    _hit_set.append(area)
    receiver.take_damage(DAMAGE, global_position, owner_player)
    SoundBank.play_3d("seed_hit", global_position)
    queue_free()


func _on_body_entered(body: Node) -> void:
    if owner_player and body == owner_player:
        return
    if body.has_method("take_damage"):
        if body in _hit_set:
            return
        _hit_set.append(body)
        body.take_damage(DAMAGE, global_position, owner_player)
        SoundBank.play_3d("seed_hit", global_position)
    queue_free()
