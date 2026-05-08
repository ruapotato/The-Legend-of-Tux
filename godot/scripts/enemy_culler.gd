extends Node

# Disables _physics_process and rendering on enemies that are far from
# the player, then re-enables them when the player approaches. Big
# levels like sourceplain ship 60+ enemies; with this culler only the
# few near the player tick AI / physics every frame.
#
# Attached as an autoload-style runner: dungeon_root.gd creates one
# per scene and reuses it. We poll on a 0.25s tick rather than every
# frame because the cull radius is generous enough that one tick of
# slop is invisible.

@export var active_radius: float = 36.0      # within → fully active
@export var visible_radius: float = 48.0     # within → visible (rendering on)
@export var poll_interval: float = 0.25

var _player: Node3D = null
var _enemies: Array = []
var _t: float = 0.0


func _ready() -> void:
    set_physics_process(false)


func bind(player: Node3D) -> void:
    _player = player


func _process(delta: float) -> void:
    _t += delta
    if _t < poll_interval:
        return
    _t = 0.0
    if _player == null or not is_instance_valid(_player):
        var hits := get_tree().get_nodes_in_group("player")
        if hits.is_empty():
            return
        _player = hits[0]
    _enemies.clear()
    for e in get_tree().get_nodes_in_group("enemy"):
        _enemies.append(e)
    var p := _player.global_position
    var ar2: float = active_radius  * active_radius
    var vr2: float = visible_radius * visible_radius
    for e in _enemies:
        if not (e is Node3D) or not is_instance_valid(e):
            continue
        var d2: float = e.global_position.distance_squared_to(p)
        var active: bool = d2 < ar2
        var visible: bool = d2 < vr2
        # Pause physics_process / process for distant enemies. Don't
        # PROCESS_MODE_DISABLED them — that would also halt timers
        # and signals. PROCESS_MODE_INHERIT with manual flag toggles
        # is fine.
        if e.has_method("set_physics_process"):
            e.set_physics_process(active)
        if e.has_method("set_process"):
            e.set_process(active)
        if "visible" in e:
            e.visible = visible
