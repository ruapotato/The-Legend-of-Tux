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
# Used only when kind == KEY: which dungeon key-group this key counts
# toward. Empty falls back to GameState.current_key_group (set by
# dungeon_root.gd), so a key dropped in a level naturally tags itself
# to that level. A chest can override this to hand out a key for a
# different dungeon (antechamber → main dungeon, etc.).
@export var key_group: String = ""
@export var pickup_message: String = ""  # if non-empty, shows in dialog box on grab

@onready var visual: Node3D = $Visual

var _picked: bool = false
var _t: float = 0.0
var _start_y: float = 0.0


func _ready() -> void:
    collision_layer = 64    # Interactable
    collision_mask = 2      # Player
    # Deferred sets in case _ready runs inside a signal callback (e.g.,
    # when an enemy._die spawns this pickup via call_deferred).
    set_deferred("monitoring", true)
    set_deferred("monitorable", false)
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
            GameState.add_key(key_group)
            SoundBank.play_2d("pebble_get")
        Kind.ITEM:
            if item_name != "":
                GameState.acquire_item(item_name)
                SoundBank.play_2d("sword_charge_ready")
    if pickup_message != "":
        Dialog.show_message(pickup_message)
    queue_free()
