extends Area3D

# Hookshot tip projectile. Flies forward at SPEED for up to MAX_RANGE.
# On contact with a "hookshot_target"-grouped Node3D OR any
# StaticBody3D, locks onto the impact point and triggers the player
# pull through Hookshot.begin_pull(). Either way self-frees once the
# pull starts (or the range runs out).
#
# A simple line MeshInstance3D between the player and the tip plays the
# chain visual. We rebuild that line in code each tick rather than
# baking it into the scene because the segment length changes every
# physics frame.

const Hookshot := preload("res://scripts/hookshot.gd")

const SPEED: float = 30.0
const MAX_RANGE: float = 12.0

@onready var line_mesh: MeshInstance3D = $Line

var direction: Vector3 = Vector3.FORWARD
var owner_player: Node3D = null
var traveled: float = 0.0
var _hit: bool = false
var _origin: Vector3 = Vector3.ZERO


func _ready() -> void:
    collision_layer = 0
    # Hittable (32) for special targets + World (1) for generic walls +
    # Enemy (4) so an enemy can be yanked toward the player too.
    collision_mask = 1 | 4 | 32
    monitoring = true
    monitorable = false
    body_entered.connect(_on_body_entered)
    area_entered.connect(_on_area_entered)
    _origin = global_position
    SoundBank.play_3d("sword_swing", _origin)


func set_direction(d: Vector3) -> void:
    var dd: Vector3 = d
    if dd.length_squared() < 1e-6:
        dd = Vector3(0, 0, -1)
    direction = dd.normalized()


func set_owner_player(p: Node3D) -> void:
    owner_player = p


func _physics_process(delta: float) -> void:
    if _hit:
        _update_chain()
        return
    global_position += direction * SPEED * delta
    traveled += SPEED * delta
    _update_chain()
    if traveled >= MAX_RANGE:
        queue_free()


func _on_body_entered(body: Node) -> void:
    if _hit:
        return
    if body == owner_player:
        return
    _resolve_hit(body, body)


func _on_area_entered(area: Area3D) -> void:
    if _hit:
        return
    var owner_node: Node = area.get_parent()
    if owner_node == owner_player:
        return
    _resolve_hit(area, owner_node if owner_node else area)


func _resolve_hit(_overlap: Node, owner_node: Node) -> void:
    var anchor: Vector3 = global_position
    var is_target: bool = false
    if owner_node is Node and (owner_node as Node).is_in_group("hookshot_target"):
        is_target = true
        if owner_node is Node3D:
            anchor = (owner_node as Node3D).global_position
    elif _overlap is Node and (_overlap as Node).is_in_group("hookshot_target"):
        is_target = true
        if _overlap is Node3D:
            anchor = (_overlap as Node3D).global_position
    elif _overlap is StaticBody3D:
        is_target = true
    if not is_target:
        return
    _hit = true
    SoundBank.play_3d("crystal_hit", anchor)
    if owner_player:
        # Pull anchor: keep current player Y so we don't yank Tux into
        # the floor or up into a ceiling — most uses are horizontal.
        var pull_to: Vector3 = anchor
        pull_to.y = owner_player.global_position.y
        Hookshot.begin_pull(owner_player, pull_to)
    # Brief lifetime so the chain stays visible during the yank.
    var killer := Timer.new()
    killer.one_shot = true
    killer.wait_time = 0.25
    add_child(killer)
    killer.timeout.connect(queue_free)
    killer.start()


func _update_chain() -> void:
    if not line_mesh or owner_player == null or not is_instance_valid(owner_player):
        return
    var origin: Vector3 = owner_player.global_position + Vector3(0, 1.0, 0)
    var to_tip: Vector3 = global_position - origin
    var length: float = to_tip.length()
    if length < 0.05:
        line_mesh.visible = false
        return
    line_mesh.visible = true
    line_mesh.top_level = true
    var midpoint: Vector3 = (origin + global_position) * 0.5
    line_mesh.global_position = midpoint
    # Orient the chain so its local Y axis points along the wire.
    var up: Vector3 = to_tip.normalized()
    var ref: Vector3 = Vector3(0, 0, 1) if abs(up.dot(Vector3(0, 1, 0))) > 0.95 else Vector3(0, 1, 0)
    var right: Vector3 = ref.cross(up).normalized()
    var fwd: Vector3 = up.cross(right).normalized()
    var basis := Basis(right, up, fwd)
    line_mesh.global_transform = Transform3D(basis.scaled(Vector3(1, length, 1)), midpoint)
