extends Area3D

# Fairy Bottle — consumable revive. Self-contained (doesn't share
# pickup.gd) so the parallel inventory-extension agents don't collide
# on enum/branch edits, mirroring heart_piece_pickup.gd's pattern.
#
# On collect, calls GameState.add_fairy(1) (which clamps to capacity
# and flips the `bottle_seen` inventory flag so the HUD readout sticks
# around even after the count returns to zero), plays a chime, and
# pops a Dialog message. The visual is a small glass bottle with a
# glowing mote inside; bobs and spins like the other pickups.

@export var pickup_message: String = "A Fairy Bottle. The fae hide a spark of life inside."

@onready var visual: Node3D = $Visual

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0


func _ready() -> void:
    collision_layer = 64    # Interactable layer
    collision_mask  = 2     # Player layer
    set_deferred("monitoring", true)
    set_deferred("monitorable", false)
    body_entered.connect(_on_body_entered)
    if visual:
        _start_y = visual.position.y


func _process(delta: float) -> void:
    _t += delta
    if visual:
        visual.position.y = _start_y + sin(_t * 2.6) * 0.12
        visual.rotation.y += 1.0 * delta


func _on_body_entered(body: Node) -> void:
    if _picked or not body.is_in_group("player"):
        return
    _picked = true
    GameState.add_fairy(1)
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("pebble_get")
    if pickup_message != "" and get_tree().root.has_node("Dialog"):
        Dialog.show_message(pickup_message)
    queue_free()
