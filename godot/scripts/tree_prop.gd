extends Node3D

# Stand-alone tree prop you can place individually (vs the tree_wall
# script which fills a whole boundary). Has solid trunk collision so
# the player can't walk through, plus a roll-trigger area: roll into
# the trunk and there's a chance a pebble drops out of the canopy.
# Modeled on the OoT bush-tree mechanic.

const PebblePickup := preload("res://scenes/pickup_pebble.tscn")

@export var pebble_chance: float = 0.30
@export var trunk_height: float = 4.6
@export var trunk_radius: float = 0.30
@export var canopy_radius: float = 1.7
@export var trunk_color: Color = Color(0.20, 0.13, 0.09, 1)
@export var canopy_color: Color = Color(0.10, 0.22, 0.12, 1)

@onready var trunk_mesh: MeshInstance3D = $Trunk
@onready var trunk_body: StaticBody3D = $TrunkBody
@onready var canopy_mesh: MeshInstance3D = $Canopy
@onready var roll_area: Area3D = $RollArea

var _shaken: bool = false
var _shake_cooldown: float = 0.0


func _ready() -> void:
    var trunk: CylinderMesh = trunk_mesh.mesh
    if trunk:
        trunk.height = trunk_height
        trunk.bottom_radius = trunk_radius
        trunk.top_radius = trunk_radius * 0.85
    trunk_mesh.position.y = trunk_height * 0.5
    var canopy: SphereMesh = canopy_mesh.mesh
    if canopy:
        canopy.radius = canopy_radius
        canopy.height = canopy_radius * 1.6
    canopy_mesh.position.y = trunk_height + canopy_radius * 0.5
    var trunk_mat := StandardMaterial3D.new()
    trunk_mat.albedo_color = trunk_color
    trunk_mat.roughness = 0.95
    trunk_mesh.material_override = trunk_mat
    var canopy_mat := StandardMaterial3D.new()
    canopy_mat.albedo_color = canopy_color
    canopy_mat.roughness = 0.85
    canopy_mesh.material_override = canopy_mat
    var trunk_shape: CollisionShape3D = trunk_body.get_node("Shape")
    var cs: CylinderShape3D = trunk_shape.shape
    if cs:
        cs.height = trunk_height
        cs.radius = trunk_radius
    trunk_shape.position.y = trunk_height * 0.5
    roll_area.body_entered.connect(_on_roll_enter)


func _process(delta: float) -> void:
    if _shake_cooldown > 0:
        _shake_cooldown -= delta


func _on_roll_enter(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    if _shake_cooldown > 0 or _shaken:
        return
    # The state machine on the player keeps a public `action` enum.
    # Only count this as a "roll into the tree" if the player is
    # currently rolling — not if they just walked into it.
    var rolling: bool = false
    if "state" in body:
        var s = body.state
        if s != null and "action" in s and "ACT_ROLL" in s:
            rolling = (s.action == s.ACT_ROLL)
    if not rolling:
        return
    _shake_cooldown = 1.0
    _shake_canopy()
    if randf() < pebble_chance:
        _shaken = true
        _drop_pebble()


func _shake_canopy() -> void:
    var t := create_tween()
    var orig: Vector3 = canopy_mesh.position
    t.tween_property(canopy_mesh, "position",
                     orig + Vector3(0.18, -0.05, 0), 0.06)
    t.tween_property(canopy_mesh, "position",
                     orig - Vector3(0.18, 0, 0), 0.08)
    t.tween_property(canopy_mesh, "position", orig, 0.10)


func _drop_pebble() -> void:
    var here: Vector3 = global_position + Vector3(0, trunk_height + 0.5, 0)
    var p := PebblePickup.instantiate()
    p.position = here
    var parent: Node = get_parent()
    if parent:
        parent.call_deferred("add_child", p)
