extends Area3D

# Heart Piece — collect 4 to earn a heart container. Self-contained
# so it doesn't compete with the parallel inventory agents over
# pickup.gd's shared enum.

@export var pickup_message_normal:   String = "A Piece of Heart."
@export var pickup_message_complete: String = "Four pieces! Your courage swells — a new heart for the Source."

@onready var visual: Node3D = $Visual

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0


func _ready() -> void:
    collision_layer = 64
    collision_mask = 2
    set_deferred("monitoring", true)
    set_deferred("monitorable", false)
    body_entered.connect(_on_body_entered)
    if visual:
        _start_y = visual.position.y


func _process(delta: float) -> void:
    _t += delta
    if visual:
        visual.position.y = _start_y + sin(_t * 3.2) * 0.10
        visual.rotation.y += 1.4 * delta


func _on_body_entered(body: Node) -> void:
    if _picked or not body.is_in_group("player"):
        return
    _picked = true
    var was: int = GameState.heart_pieces
    GameState.add_heart_piece()
    var completed: bool = (was == 3)   # the 4th piece promoted to a container
    if get_tree().root.has_node("SoundBank"):
        SoundBank.play_2d("heart_container_get" if completed else "heart_get")
    if get_tree().root.has_node("Dialog"):
        Dialog.show_message(pickup_message_complete if completed else pickup_message_normal)
    queue_free()
