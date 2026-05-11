extends Area3D

# Generic ground-pickup. Bobs and spins; on player overlap, applies its
# kind-specific effect, plays a sound, and despawns.
#
# Subscenes (pickup_pebble, pickup_heart, pickup_key, pickup_item) bind
# the kind via the export and place the right visual mesh. The script
# is shared.

enum Kind { PEBBLE, FISH, KEY, ITEM, ARROW, SEED, BOMB }

@export var kind: Kind = Kind.PEBBLE
@export var item_name: String = ""    # used when kind == ITEM
@export var pebble_amount: int = 1
@export var fish_amount: int = 1      # = 4 HP units per fish
@export var arrow_amount: int = 5     # ammo bundles for ARROW pickups
@export var seed_amount: int = 5      # ammo bundles for SEED pickups
@export var bomb_amount: int = 1      # used when kind == BOMB
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
    # Terminal-corner narration. Lore-canon command for grabbing a
    # pickup is `cp <pickup> ~/.inv/`. We prefer a human-readable
    # label (item_name for ITEM kind, the kind name otherwise) over
    # the bare scene-node name so the corner reads as "cp Hammer …"
    # not "cp @Pickup_413@".
    var tl: Node = get_node_or_null("/root/TerminalLog")
    if tl:
        var label: String = _terminal_label()
        tl.cmd("cp %s ~/.inv/" % label)
    match kind:
        Kind.PEBBLE:
            GameState.add_pebbles(pebble_amount)
        Kind.FISH:
            GameState.heal(fish_amount * GameState.HP_PER_FISH)
            SoundBank.play_2d("pebble_get")
        Kind.KEY:
            GameState.add_key(key_group)
            SoundBank.play_2d("pebble_get")
            _banner_show("key")
        Kind.ITEM:
            if item_name != "":
                GameState.acquire_item(item_name)
                SoundBank.play_2d("sword_charge_ready")
                _banner_show(item_name)
        Kind.ARROW:
            GameState.add_arrows(arrow_amount)
            SoundBank.play_2d("pebble_get")
        Kind.SEED:
            GameState.add_seeds(seed_amount)
            SoundBank.play_2d("pebble_get")
        Kind.BOMB:
            GameState.add_bombs(bomb_amount)
            SoundBank.play_2d("pebble_get")
    if pickup_message != "":
        Dialog.show_message(pickup_message)
    queue_free()


# Defer to the PickupBanner autoload if it's registered. The banner
# script also listens to GameState signals as a fallback so this
# explicit call is mostly a "first-frame timing guarantee" — and
# perfectly safe to skip in builds that haven't autoloaded the banner
# yet (mid-merge, quick tests, etc.).
func _banner_show(item_id: String) -> void:
    if item_id == "":
        return
    var banner := get_node_or_null("/root/PickupBanner")
    if banner and banner.has_method("show_item"):
        banner.show_item(item_id)


# Build the label used inside the terminal-corner `cp ...` line. ITEM
# pickups carry a meaningful `item_name`; the rest report by kind so
# generic pebble/heart/key drops all read as themselves rather than
# whatever the engine auto-named the scene node.
func _terminal_label() -> String:
    match kind:
        Kind.ITEM:
            return item_name if item_name != "" else "item"
        Kind.PEBBLE:
            return "pebble"
        Kind.FISH:
            return "fish"
        Kind.KEY:
            return "key"
        Kind.ARROW:
            return "arrow"
        Kind.SEED:
            return "seed"
        Kind.BOMB:
            return "bomb"
        _:
            return name
