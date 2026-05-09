extends Area3D

# Heart Container — permanent +1 max HP. Self-contained (doesn't share
# pickup.gd) so the parallel inventory-extension agents don't collide
# on enum/branch edits. Bosses drop these on death.

@export var pickup_message: String = "A Heart Container — your courage grows."

@onready var visual: Node3D = $Visual

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0


func _ready() -> void:
    collision_layer = 64    # Interactable layer
    collision_mask = 2      # Player layer
    set_deferred("monitoring", true)
    set_deferred("monitorable", false)
    body_entered.connect(_on_body_entered)
    if visual:
        _start_y = visual.position.y


func _process(delta: float) -> void:
    _t += delta
    if visual:
        visual.position.y = _start_y + sin(_t * 2.5) * 0.15
        visual.rotation.y += 0.9 * delta


func _on_body_entered(body: Node) -> void:
    if _picked or not body.is_in_group("player"):
        return
    _picked = true
    GameState.add_heart_container()
    if Engine.has_singleton("SoundBank") or get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("sword_charge_ready")
    if pickup_message != "" and Engine.has_singleton("Dialog") or get_tree().root.has_node("Dialog"):
        Dialog.show_message(pickup_message)
    queue_free()
