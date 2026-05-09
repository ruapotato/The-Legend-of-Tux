extends Node

# Autoloaded global event bus for puzzle props. Switches/plates/torches
# call WorldEvents.activate("some_id") and any door/bridge/wall that
# stored a matching listen_id reacts. Decouples the emitter from the
# listener so the dungeon JSON only needs to share a target_id string.
#
# Per-id state is tracked so a door connected to "boss_door" can come
# up already open if it spawns after the switch was already hit, and
# so a "holds: false" plate can correctly toggle off.

signal activated(target_id: String)
signal deactivated(target_id: String)

# Map of target_id -> bool (true = currently active). Used both as a
# convenience read for late-binding listeners and to dedupe redundant
# emits (a plate emitting twice in a row shouldn't double-fire).
var _states: Dictionary = {}


func activate(target_id: String) -> void:
	if target_id == "":
		return
	if _states.get(target_id, false):
		return
	_states[target_id] = true
	activated.emit(target_id)


func deactivate(target_id: String) -> void:
	if target_id == "":
		return
	if not _states.get(target_id, false):
		return
	_states[target_id] = false
	deactivated.emit(target_id)


func is_active(target_id: String) -> bool:
	return _states.get(target_id, false)


# Called by dungeon_root.gd when a fresh scene loads, so a previous
# dungeon's puzzle state doesn't leak into the next one. Per-run state
# is intentionally not persisted across scene swaps — every dungeon
# resets its own switches.
func reset() -> void:
	_states.clear()
