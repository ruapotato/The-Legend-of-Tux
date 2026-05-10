extends Node3D

# Init Shade — a tall, slender shadow figure that floats slightly off
# the ground and slowly rotates. It does not pursue. It does not attack.
#
# If the player stands within 1.5 m it drains their stamina at 8/sec.
# If the player approaches within 2 m WHILE ROLLING, the shade vanishes
# (scale-down + queue_free, 0.4 s) and is gone for the run.
#
# The shade is not killable by sword. take_damage is a no-op. Only the
# roll-approach removes it. It also does not join group "enemy" — it's
# in group "init_shade" so the enemy culler doesn't disable it strangely.
#
# Lore (private): this is Annette's footprint. The player should never
# be told that. (FILESYSTEM.md §3 / LORE.md §6.)

signal died

@export var drain_radius: float = 1.5
@export var vanish_radius: float = 2.0
@export var drain_per_sec: float = 8.0
@export var vanish_time: float = 0.4
@export var rotation_omega: float = 0.4

enum State { STILL, DRAIN, VANISH, DEAD }

var state: int = State.STILL
var state_time: float = 0.0
var player: Node3D = null
var _drain_remainder: float = 0.0
var _vanishing: bool = false

@onready var visual: Node3D = $Visual
@onready var sense_area: Area3D = $SenseArea


func _ready() -> void:
	# Deliberately NOT in "enemy" — the enemy culler shouldn't pause us.
	add_to_group("init_shade")
	# Sense area is layer 0 / mask 2 — we never overlap the sword
	# (layer 32 expectation), only the player capsule.
	sense_area.body_entered.connect(_on_sense_entered)
	sense_area.body_exited.connect(_on_sense_exited)
	set_process(true)


func _ensure_player() -> void:
	if player == null or not is_instance_valid(player):
		var ps := get_tree().get_nodes_in_group("player")
		if ps.size() > 0:
			player = ps[0]


# A slow, small rotation. Doesn't bob — the spec calls for a stillness
# distinct from the process_ghost's wandering bob.
func _process(delta: float) -> void:
	if state == State.DEAD or _vanishing:
		return
	visual.rotation.y += rotation_omega * delta
	state_time += delta
	_ensure_player()
	if not (player and is_instance_valid(player)):
		return
	var to_p: Vector3 = player.global_position - global_position
	to_p.y = 0.0
	var dist: float = to_p.length()
	# Roll-vanish takes priority over the drain window — checked every
	# tick because the player can roll into the radius from outside it.
	if dist < vanish_radius and _player_is_rolling():
		_begin_vanish()
		return
	if dist < drain_radius:
		_apply_drain(delta)
		state = State.DRAIN
	else:
		state = State.STILL
		_drain_remainder = 0.0


# Stamina drain: GameState.spend_stamina is integer-valued, so we
# accumulate fractional amounts here and spend whole pips.
func _apply_drain(delta: float) -> void:
	_drain_remainder += drain_per_sec * delta
	var whole := int(_drain_remainder)
	if whole > 0:
		_drain_remainder -= whole
		GameState.spend_stamina(whole)


# Mirrors tree_prop.gd's check: peek the player's state.action enum
# against ACT_ROLL.
func _player_is_rolling() -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if not "state" in player:
		return false
	var s = player.state
	if s == null:
		return false
	if not ("action" in s and "ACT_ROLL" in s):
		return false
	return s.action == s.ACT_ROLL


# Sense-area callbacks are mostly informational — the per-frame check
# in _process handles the actual logic. We use them to pin `player`
# even before its group is populated.
func _on_sense_entered(body: Node) -> void:
	if body.is_in_group("player"):
		player = body


func _on_sense_exited(_body: Node) -> void:
	pass


func _begin_vanish() -> void:
	if _vanishing:
		return
	_vanishing = true
	state = State.VANISH
	# The sword can't hit us anyway (layer 0 hitbox), but disable the
	# sense area so we don't apply drain during the fade-out.
	sense_area.set_deferred("monitoring", false)
	SoundBank.play_3d("warp_song", global_position)
	died.emit()
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(visual, "scale", Vector3(0.05, 0.05, 0.05), vanish_time)
	t.chain().tween_callback(queue_free)


# Sword hits route here. The shade does not take sword damage — only
# the roll-approach removes it.
func take_damage(_amount: int, _source_pos: Vector3, _attacker: Node3D = null) -> void:
	# Intentional no-op. The flavor is "you cannot cut a footprint."
	return
