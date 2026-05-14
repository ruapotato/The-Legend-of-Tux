extends Area3D

# Generic auto-pickup for the gather loop's raw materials (wood, meat,
# antler, raspberry, stone, …). Sits on the ground, bobs slightly, and
# accelerates toward the player when they're within MAGNET_RADIUS so the
# small-radius collider doesn't get missed when the player skims past.
# On contact it calls GameState.add_resource(item_id, amount), pops a
# PickupBanner toast, and frees.
#
# Kept deliberately thin — the heavyweight pickup.gd handles equipment
# and currency; this one is only for the new resource ledger.

@export var item_id: String = ""
@export var amount: int = 1

# Magnet pull range and snap distance. Within MAGNET_RADIUS the pickup
# homes on the player at MAGNET_SPEED; once within SNAP_RADIUS we treat
# it as collected (covers the case where the small CollisionShape never
# triggered body_entered because the player overshot in one frame).
const MAGNET_RADIUS: float = 4.0
const SNAP_RADIUS: float = 0.9
const MAGNET_SPEED: float = 12.0

@onready var _visual: Node3D = get_node_or_null("Visual")

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0
var _player_ref: Node3D = null


func _ready() -> void:
    # Layer 64 = Interactable, mask 2 = Player. Matches pickup.gd so the
    # player's existing pickup mask catches us with no project changes.
    collision_layer = 64
    collision_mask = 2
    # Deferred — _ready can run inside a signal callback when an animal
    # spawns this pickup via call_deferred from its death path.
    set_deferred("monitoring", true)
    set_deferred("monitorable", false)
    body_entered.connect(_on_body_entered)
    if _visual:
        _start_y = _visual.position.y


func _process(delta: float) -> void:
    _t += delta
    if _visual:
        _visual.position.y = _start_y + sin(_t * 3.0) * 0.08
        _visual.rotation.y += 1.4 * delta
    _magnet_toward_player(delta)


func _magnet_toward_player(delta: float) -> void:
    if _picked:
        return
    if _player_ref == null or not is_instance_valid(_player_ref):
        var ps := get_tree().get_nodes_in_group("player")
        if ps.is_empty():
            return
        _player_ref = ps[0] as Node3D
        if _player_ref == null:
            return
    var to_p: Vector3 = _player_ref.global_position - global_position
    var dist: float = to_p.length()
    if dist >= MAGNET_RADIUS:
        return
    # Snap-collect when the player is essentially on top of us — covers
    # the high-speed/missed-collision case.
    if dist <= SNAP_RADIUS:
        _collect()
        return
    # Linear lerp toward the player; speed scales with how close we are
    # so the last metre is fast and the magnet feels like a vacuum.
    var step: float = MAGNET_SPEED * delta * lerp(0.4, 1.0, 1.0 - dist / MAGNET_RADIUS)
    var dir: Vector3 = to_p.normalized()
    global_position += dir * min(step, dist)


func _on_body_entered(body: Node) -> void:
    if _picked:
        return
    if not body.is_in_group("player"):
        return
    _collect()


func _collect() -> void:
    if _picked:
        return
    _picked = true
    if item_id != "" and GameState.has_method("add_resource"):
        GameState.add_resource(item_id, amount)
    # Pop a small "+1 Wood" toast via PickupBanner if available — the
    # autoload silently no-ops in headless / boot-time contexts so the
    # call is safe.
    var banner: Node = get_node_or_null("/root/PickupBanner")
    if banner and banner.has_method("show"):
        banner.show("+%d %s" % [amount, item_id])
    queue_free()
