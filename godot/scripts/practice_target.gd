extends StaticBody3D

# Stationary practice dummy. Takes hits, flashes, plays a bounce. Dies
# at HP 0 (vanishes). No AI, no return damage — it's a tuning aid for
# the combat slice. Has a child "Hitbox" Area3D on the Hittable layer
# that the sword scans for.

@export var max_hp: int = 3
var hp: int = 3

@onready var visual: Node3D = $Visual
@onready var hitbox: Area3D = $Hitbox
var _flash_t: float = 0.0
var _bounce_t: float = 0.0
var _flash_mat: StandardMaterial3D = null


func _ready() -> void:
    hp = max_hp
    add_to_group("practice_target")
    if visual:
        var mesh := visual.get_node_or_null("Mesh") as MeshInstance3D
        if mesh:
            _flash_mat = StandardMaterial3D.new()
            _flash_mat.albedo_color = Color(0.85, 0.55, 0.35)
            mesh.material_override = _flash_mat


func take_damage(amount: int, _source_pos: Vector3, _attacker: Node = null) -> void:
    if hp <= 0:
        return
    hp -= amount
    _flash_t = 0.18
    _bounce_t = 0.25
    if hp <= 0:
        _on_destroyed()


func _on_destroyed() -> void:
    if hitbox:
        hitbox.monitoring = false
        hitbox.monitorable = false
    visible = false
    set_process(false)


func _process(delta: float) -> void:
    if _flash_t > 0.0:
        _flash_t = max(_flash_t - delta, 0.0)
        if _flash_mat:
            var k: float = _flash_t / 0.18
            _flash_mat.albedo_color = Color(0.85, 0.55, 0.35).lerp(Color(1.0, 1.0, 1.0), k)
    if _bounce_t > 0.0:
        _bounce_t = max(_bounce_t - delta, 0.0)
        var phase: float = _bounce_t / 0.25
        if visual:
            visual.position.y = sin(phase * PI) * 0.15
            visual.scale = Vector3.ONE * (1.0 + sin(phase * PI) * 0.15)
    elif visual and visual.position.y != 0.0:
        visual.position.y = 0.0
        visual.scale = Vector3.ONE
