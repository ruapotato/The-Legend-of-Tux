extends Area3D

# Generic ground-pickup. Bobs and spins; on player overlap, applies its
# kind-specific effect, plays a sound, and despawns.
#
# Subscenes (pickup_pebble, pickup_heart, pickup_key, pickup_item) bind
# the kind via the export and place the right visual mesh. The script
# is shared.

enum Kind { PEBBLE, FISH, KEY, ITEM }

@export var kind: Kind = Kind.PEBBLE
@export var item_name: String = ""    # used when kind == ITEM
@export var pebble_amount: int = 1
@export var fish_amount: int = 1      # = 4 HP units per fish
@export var pickup_message: String = ""  # if non-empty, shows in dialog box on grab

@onready var visual: Node3D = $Visual

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0


func _ready() -> void:
    collision_layer = 64    # Interactable
    collision_mask = 2      # Player
    monitoring = true
    monitorable = false
    body_entered.connect(_on_body_entered)
    if visual:
        _start_y = visual.position.y


func _process(delta: float) -> void:
    _t += delta
    if visual:
        visual.position.y = _start_y + sin(_t * 3.0) * 0.10
        visual.rotation.y += 1.5 * delta


func _on_body_entered(body: Node) -> void:
    if _picked:
        return
    if not body.is_in_group("player"):
        return
    _picked = true
    match kind:
        Kind.PEBBLE:
            GameState.add_pebbles(pebble_amount)
        Kind.FISH:
            GameState.heal(fish_amount * GameState.HP_PER_FISH)
            SoundBank.play_2d("pebble_get")
        Kind.KEY:
            GameState.add_key()
            SoundBank.play_2d("pebble_get")
        Kind.ITEM:
            if item_name != "":
                GameState.acquire_item(item_name)
                SoundBank.play_2d("sword_charge_ready")
    if pickup_message != "":
        Dialog.show_message(pickup_message)
    queue_free()
