extends RefCounted

# Two-click wall placement. First click stores a point; second click
# places a wall_segment between the two points (rotated to match) and
# leaves the second point as the new anchor for chained placement.
#
# Wall height/thickness/material configurable via the UI's wall panel.
# The owning editor_ui invokes:
#   enter()          → arm the tool
#   exit()           → cancel, drop anchor
#   pick(world_pos)  → click handler; returns the placed wall or null
#   preview(...)     → updates the rubber-band preview line each frame
#
# The preview is a thin yellow box parented under the scene root.

const WALL_SEGMENT_SCENE := "res://scenes/wall_segment.tscn"

var active: bool = false
var anchor: Vector3 = Vector3.ZERO
var have_anchor: bool = false
var wall_height: float = 4.0
var wall_thickness: float = 0.3
var material_kind: String = "stone"   # "stone"/"wood"/"brick"/"dirt"/"metal"

var _preview: MeshInstance3D = null
var _preview_parent: Node = null


func enter(parent_for_preview: Node) -> void:
	active = true
	have_anchor = false
	_preview_parent = parent_for_preview


func exit() -> void:
	active = false
	have_anchor = false
	_drop_preview()


func _drop_preview() -> void:
	if _preview and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null


# Called by editor_ui on LMB click (in world space). Returns the newly
# placed wall Node3D (or null if this was only the first anchor click).
func pick(world_pos: Vector3, place_parent: Node) -> Node3D:
	if not have_anchor:
		anchor = world_pos
		have_anchor = true
		return null
	var wall := _spawn_wall(anchor, world_pos, place_parent)
	# Chain: new anchor is the just-placed end.
	anchor = world_pos
	return wall


# Rubber-band preview drawn under the editor camera as a thin box.
func preview(hover_world: Vector3, scene_root: Node) -> void:
	if not active or not have_anchor:
		_drop_preview()
		return
	if _preview == null:
		_preview = MeshInstance3D.new()
		_preview.top_level = true
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 1, 0, 0.45)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_preview.material_override = mat
		var parent: Node = _preview_parent if _preview_parent else scene_root
		parent.add_child(_preview)
	_update_preview_transform(anchor, hover_world)


func _update_preview_transform(a: Vector3, b: Vector3) -> void:
	var delta: Vector3 = b - a
	var len: float = delta.length()
	if len < 0.01:
		_preview.visible = false
		return
	_preview.visible = true
	var bm := BoxMesh.new()
	bm.size = Vector3(len, wall_height, wall_thickness)
	_preview.mesh = bm
	# Position at midpoint, rotated to face along delta on XZ.
	var mid: Vector3 = (a + b) * 0.5
	mid.y += wall_height * 0.5
	var yaw: float = atan2(delta.x, delta.z)
	# Wall's X spans the segment, so rotate y by -yaw (since +X local maps to delta dir).
	_preview.global_position = mid
	_preview.rotation = Vector3(0, yaw - PI * 0.5, 0)


func _spawn_wall(a: Vector3, b: Vector3, place_parent: Node) -> Node3D:
	if place_parent == null:
		return null
	var delta: Vector3 = b - a
	var len: float = delta.length()
	if len < 0.1:
		return null
	var scn: PackedScene = load(WALL_SEGMENT_SCENE) as PackedScene
	if scn == null:
		return null
	var wall := scn.instantiate() as Node3D
	if wall == null:
		return null
	place_parent.add_child(wall)
	# Apply size / color via the wall_segment script's properties.
	if "size" in wall:
		wall.size = Vector3(len, wall_height, wall_thickness)
	if "color" in wall:
		wall.color = _material_color()
	var mid: Vector3 = (a + b) * 0.5
	var yaw: float = atan2(delta.x, delta.z)
	wall.global_position = mid
	wall.rotation = Vector3(0, yaw - PI * 0.5, 0)
	return wall


func _material_color() -> Color:
	match material_kind:
		"wood":  return Color(0.45, 0.30, 0.18, 1)
		"brick": return Color(0.62, 0.30, 0.25, 1)
		"dirt":  return Color(0.40, 0.28, 0.18, 1)
		"metal": return Color(0.72, 0.74, 0.78, 1)
		_:       return Color(0.55, 0.55, 0.58, 1)
