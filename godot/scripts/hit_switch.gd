extends Area3D

# Hittable crystal. Activates when struck by anything carrying the
# `damage` group (sword hitbox, arrow, etc.). On activation it emits
# `activated` for connected gates / puzzle elements to react. Optional
# auto-reset after `cooldown` seconds, otherwise stays on permanently.

signal activated()

@export var cooldown: float = 0.0     # 0 = permanent
@export var active_color: Color = Color(0.4, 0.9, 1.0, 1.0)
@export var idle_color: Color = Color(0.4, 0.5, 0.7, 1.0)

@onready var mesh: MeshInstance3D = $Mesh
var _active: bool = false
var _cooldown_t: float = 0.0
var _mat: StandardMaterial3D


func _ready() -> void:
    add_to_group("hittable_switch")
    if mesh and mesh.mesh:
        _mat = StandardMaterial3D.new()
        _mat.albedo_color = idle_color
        _mat.emission_enabled = true
        _mat.emission = idle_color
        _mat.emission_energy_multiplier = 0.4
        mesh.material_override = _mat


# Called by the sword hitbox when its overlap check matches this area's
# parent group. The sword's host calls take_damage on the parent; we
# expose take_damage here so the same dispatch reaches us.
func take_damage(_amount: int, _source_pos: Vector3) -> void:
    if _active:
        return
    _active = true
    _cooldown_t = cooldown
    _refresh_color()
    activated.emit()


func _process(delta: float) -> void:
    if not _active or cooldown <= 0.0:
        return
    _cooldown_t -= delta
    if _cooldown_t <= 0.0:
        _active = false
        _refresh_color()


func _refresh_color() -> void:
    if not _mat:
        return
    var c: Color = active_color if _active else idle_color
    _mat.albedo_color = c
    _mat.emission = c
    _mat.emission_energy_multiplier = 1.6 if _active else 0.4
