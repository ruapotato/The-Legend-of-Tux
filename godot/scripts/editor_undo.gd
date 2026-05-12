extends RefCounted

# Stack-based undo/redo for the integrated editor. The owner (editor_ui)
# holds a single instance and pushes Action dicts when something mutates
# the scene. Ctrl+Z pops the top of `done` onto `undone`; Ctrl+Y / Shift+Z
# pops back. Max 100 actions deep; older entries are discarded silently.
#
# Action shape: {type, target, before, after, extra?}
#   - type:  "place" | "delete" | "transform" | "prop" | "sculpt" | "paint" | "multi"
#   - target: NodePath (string) of the affected node — resolved at apply time
#             so deleted-and-restored nodes can still be replayed.
#   - before / after: Variant payloads (Vector3 for transform, Dictionary
#             for prop, PackedFloat32Array for sculpt, etc.)
#   - extra: optional dict for type-specific data (e.g. scene_path for
#            place actions so we can re-instantiate).
#
# For "place": before=null, after={scene_path, parent_path, transform, name,
#     packed_scene_bytes (optional)}.
# For "delete": before={packed_scene_bytes, transform, parent_path, name},
#     after=null. Storing the packed scene lets us re-create a node from
#     scratch when undoing a delete.
# For "transform": before/after = {pos: Vector3, rot: Vector3, scale: Vector3}.
# For "prop": before/after = Dictionary of property_name → value.
# For "sculpt"/"paint": before/after = PackedFloat32Array / PackedByteArray.
# For "multi": before/after = Array of sub-actions, applied in order.

const MAX_STACK: int = 100

var done: Array = []      # actions waiting for Ctrl+Z
var undone: Array = []    # actions waiting for redo


func push(action: Dictionary) -> void:
	done.append(action)
	if done.size() > MAX_STACK:
		done.pop_front()
	# Any new action invalidates the redo stack.
	undone.clear()


func clear() -> void:
	done.clear()
	undone.clear()


func can_undo() -> bool:
	return not done.is_empty()


func can_redo() -> bool:
	return not undone.is_empty()


# The owner provides scene_root so paths can be resolved; we don't store
# a reference to keep this script tree-agnostic.
func undo(scene_root: Node) -> bool:
	if done.is_empty():
		return false
	var a: Dictionary = done.pop_back()
	_apply(a, scene_root, true)
	undone.append(a)
	return true


func redo(scene_root: Node) -> bool:
	if undone.is_empty():
		return false
	var a: Dictionary = undone.pop_back()
	_apply(a, scene_root, false)
	done.append(a)
	return true


func _apply(a: Dictionary, scene_root: Node, is_undo: bool) -> void:
	var typ: String = String(a.get("type", ""))
	match typ:
		"transform":
			var n: Node = _resolve(scene_root, a.get("target", ""))
			if n == null or not (n is Node3D):
				return
			var n3d: Node3D = n
			var d: Dictionary = a.get("before", {}) if is_undo else a.get("after", {})
			if d.has("pos"):
				n3d.position = d["pos"]
			if d.has("rot"):
				n3d.rotation = d["rot"]
			if d.has("scale"):
				n3d.scale = d["scale"]
		"prop":
			var n2: Node = _resolve(scene_root, a.get("target", ""))
			if n2 == null:
				return
			var d2: Dictionary = a.get("before", {}) if is_undo else a.get("after", {})
			for k in d2.keys():
				if k in n2:
					n2.set(k, d2[k])
				n2.set_meta(k, d2[k])
		"place":
			# undo = remove the placed node; redo = re-create.
			if is_undo:
				var n3: Node = _resolve(scene_root, a.get("target", ""))
				if n3:
					n3.queue_free()
			else:
				_restore_node(a, scene_root)
		"delete":
			# undo = re-create; redo = remove.
			if is_undo:
				_restore_node(a, scene_root)
			else:
				var n4: Node = _resolve(scene_root, a.get("target", ""))
				if n4:
					n4.queue_free()
		"sculpt":
			var n5: Node = _resolve(scene_root, a.get("target", ""))
			if n5 == null or not n5.has_method("set_heights"):
				return
			var data: PackedFloat32Array = a.get("before", PackedFloat32Array()) \
					if is_undo else a.get("after", PackedFloat32Array())
			n5.set_heights(data)
		"paint":
			var n6: Node = _resolve(scene_root, a.get("target", ""))
			if n6 == null or not n6.has_method("set_surfaces"):
				return
			var data2: PackedByteArray = a.get("before", PackedByteArray()) \
					if is_undo else a.get("after", PackedByteArray())
			n6.set_surfaces(data2)
		"multi":
			var subs: Array = a.get("before", []) if is_undo else a.get("after", [])
			for sub in subs:
				_apply(sub, scene_root, is_undo)


func _resolve(scene_root: Node, path: Variant) -> Node:
	if scene_root == null or path == null or path == "":
		return null
	return scene_root.get_node_or_null(String(path))


func _restore_node(a: Dictionary, scene_root: Node) -> void:
	# Re-create a node from a pickled scene snapshot. We pack the node
	# at delete time so it survives the round-trip.
	var blob: Variant = a.get("packed", null)
	if blob is PackedScene:
		var inst := (blob as PackedScene).instantiate()
		if inst == null:
			return
		var parent: Node = scene_root.get_node_or_null(String(a.get("parent_path", ".")))
		if parent == null:
			parent = scene_root
		parent.add_child(inst)
		inst.owner = scene_root
		if inst is Node3D and a.has("transform"):
			(inst as Node3D).transform = a["transform"]
		if a.has("name"):
			inst.name = String(a["name"])


# Helper used by callers to pack a node before deletion so undo can
# restore it.
static func pack_for_delete(node: Node) -> PackedScene:
	if node == null:
		return null
	# Temporarily own the subtree so pack walks it. We *don't* mutate
	# the user's ownership graph permanently — caller restores after.
	var prev_owners: Dictionary = {}
	for n in _walk(node):
		if n == node:
			continue
		prev_owners[n] = n.owner
		n.owner = node
	var ps := PackedScene.new()
	var err := ps.pack(node)
	# Restore.
	for n in prev_owners.keys():
		(n as Node).owner = prev_owners[n]
	if err != OK:
		return null
	return ps


static func _walk(root: Node) -> Array:
	var out: Array = [root]
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			out.append(c)
			stack.append(c)
	return out
