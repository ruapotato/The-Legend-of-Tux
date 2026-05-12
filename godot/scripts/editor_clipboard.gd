extends RefCounted

# Ctrl+C / Ctrl+V clipboard for editor selections. We store a list of
# duplicated Node3Ds *plus* their world-space transforms relative to a
# common centroid; paste re-instantiates each clone and offsets by the
# raycast hit position (so each paste lands where the cursor is).
#
# Pasting twice without moving = visible offset, achieved by bumping a
# small +0.5/0/0.5m drift on every paste.

var _entries: Array = []     # array of {scene: Node3D, offset: Vector3}
var _centroid: Vector3 = Vector3.ZERO
var _paste_counter: int = 0


func is_empty() -> bool:
	return _entries.is_empty()


func clear() -> void:
	for e in _entries:
		var n: Node = e.get("scene", null)
		if n and is_instance_valid(n):
			n.free()
	_entries.clear()


func copy(nodes: Array) -> void:
	clear()
	if nodes.is_empty():
		return
	# Compute centroid in world space.
	var sum := Vector3.ZERO
	var cnt := 0
	for n in nodes:
		if n is Node3D:
			sum += (n as Node3D).global_position
			cnt += 1
	if cnt == 0:
		return
	_centroid = sum / float(cnt)
	for n in nodes:
		if n is Node3D:
			var clone: Node = (n as Node3D).duplicate(Node.DUPLICATE_USE_INSTANTIATION)
			_entries.append({
				"scene": clone,
				"offset": (n as Node3D).global_position - _centroid,
				"rotation": (n as Node3D).rotation,
				"scale": (n as Node3D).scale,
			})
	_paste_counter = 0


# Returns the freshly-pasted Node3Ds parented under `parent` at
# `world_pos`. Each call adds a small drift so consecutive pastes
# don't pile up on top of each other.
func paste(parent: Node, world_pos: Vector3) -> Array:
	var out: Array = []
	if _entries.is_empty() or parent == null:
		return out
	_paste_counter += 1
	var drift := Vector3(0.5, 0, 0.5) * float(_paste_counter - 1)
	for e in _entries:
		var src: Node = e.get("scene", null)
		if src == null or not is_instance_valid(src):
			continue
		var inst: Node = src.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
		if inst == null:
			continue
		parent.add_child(inst)
		if inst is Node3D:
			var n3d: Node3D = inst
			n3d.global_position = world_pos + e["offset"] + drift
			n3d.rotation = e["rotation"]
			n3d.scale = e["scale"]
		out.append(inst)
	return out
