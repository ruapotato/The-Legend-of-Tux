extends StaticBody3D

# Lives on a tree_prop's TrunkBody child. The player's sword_hitbox
# walks body_entered and calls `take_damage(amount, source_pos,
# attacker)` on whatever it hit; the trunk-body is the actual physics
# body so it's what gets reported. Forward the call to the tree_prop
# root so HP tracking + wood-drop lives in one place.

func take_damage(amount: int, source_pos: Vector3, attacker: Node = null) -> void:
	var p: Node = get_parent()
	if p == null:
		return
	if p.has_method("take_damage"):
		p.take_damage(amount, source_pos, attacker)
