extends Area3D

# Generic auto-pickup for the gather loop's raw materials (meat, antler,
# raspberry, ...). Sits on the ground, bobs slightly, and on player
# overlap calls GameState.add_resource(item_id, amount) before freeing.
#
# Kept deliberately thin — the heavyweight pickup.gd handles equipment
# and currency; this one is only for the new resource ledger.

@export var item_id: String = ""
@export var amount: int = 1

@onready var _visual: Node3D = get_node_or_null("Visual")

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0


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


func _on_body_entered(body: Node) -> void:
    if _picked:
        return
    if not body.is_in_group("player"):
        return
    _picked = true
    if item_id != "" and GameState.has_method("add_resource"):
        GameState.add_resource(item_id, amount)
    queue_free()
