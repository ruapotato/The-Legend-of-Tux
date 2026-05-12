extends Camera3D

# Free-fly editor camera — Godot-editor-style hold-RMB-to-fly.
#
# Default: cursor is FREE and visible. UI is fully clickable. No mouse
# capture, no Alt-toggle dance.
#
# Hold RMB:
#   - cursor captured + hidden
#   - mouse motion rotates camera (yaw + pitch)
#   - WASD horizontal fly, Q/E down/up
#   - Shift = 3x speed, Ctrl = 0.3x fine
#   - Mouse wheel adjusts fly SPEED (more useful day-to-day than FOV).
# Release RMB:
#   - cursor returns to the same screen position it left from
#   - fly stops, look freezes.
#
# F: focus camera on the current selection (queried from EditorUI).
#
# MMB drag: lateral pan (no rotation).
# MMB+Alt drag: orbit around a pivot point (the last raycast hit ahead).
#
# Numpad views and bookmarks preserved.

const SPEED_DEFAULT: float = 8.0
const SPEED_MIN: float = 0.5
const SPEED_MAX: float = 80.0
const SPEED_BOOST: float = 3.0
const SPEED_FINE: float = 0.3
const MOUSE_SENS: float = 0.0025
const FOV_DEFAULT: float = 70.0

var _yaw: float = 0.0
var _pitch: float = -0.25
var _ortho: bool = false

# Hold-to-fly state.
var _flying: bool = false
# Cursor position at the moment we started flying; on release, warp back here.
var _cursor_return_pos: Vector2 = Vector2.ZERO

# Pan (MMB drag) state.
var _panning: bool = false
var _orbiting: bool = false
var _orbit_pivot: Vector3 = Vector3.ZERO

# Configurable fly speed (wheel adjusts).
var fly_speed: float = SPEED_DEFAULT


func _ready() -> void:
	visible = false
	current = false
	rotation = Vector3(_pitch, _yaw, 0)
	fov = FOV_DEFAULT


func _exit_tree() -> void:
	_release_capture()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not visible:
			_release_capture()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _flying:
			_yaw   -= mm.relative.x * MOUSE_SENS
			_pitch -= mm.relative.y * MOUSE_SENS
			_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
			rotation = Vector3(_pitch, _yaw, 0)
		elif _panning:
			# Pan in camera-local right/up plane.
			var r: Vector3 = global_transform.basis.x
			var u: Vector3 = global_transform.basis.y
			var scale: float = 0.01 * max(1.0, fly_speed * 0.5)
			position += (-r * mm.relative.x + u * mm.relative.y) * scale
		elif _orbiting:
			# Orbit around _orbit_pivot.
			var d_yaw: float = -mm.relative.x * MOUSE_SENS
			var d_pitch: float = -mm.relative.y * MOUSE_SENS
			var rel: Vector3 = global_position - _orbit_pivot
			rel = rel.rotated(Vector3.UP, d_yaw)
			var right: Vector3 = global_transform.basis.x
			rel = rel.rotated(right, d_pitch)
			global_position = _orbit_pivot + rel
			look_at(_orbit_pivot, Vector3.UP)
			_yaw = rotation.y
			_pitch = rotation.x
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_begin_fly(mb.position)
				else:
					_end_fly()
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					if Input.is_key_pressed(KEY_ALT):
						_begin_orbit()
					else:
						_begin_pan()
				else:
					_panning = false
					_orbiting = false
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed and _flying:
					_adjust_fly_speed(1.15)
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed and _flying:
					_adjust_fly_speed(1.0 / 1.15)
					get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var ke := event as InputEventKey
		if not ke.pressed or ke.echo:
			return
		match ke.keycode:
			KEY_KP_7:
				view_top(); get_viewport().set_input_as_handled()
			KEY_KP_1:
				view_front(); get_viewport().set_input_as_handled()
			KEY_KP_3:
				view_side(); get_viewport().set_input_as_handled()
			KEY_KP_5:
				toggle_ortho(); get_viewport().set_input_as_handled()
			KEY_KP_0:
				view_reset(); get_viewport().set_input_as_handled()


func _begin_fly(pos: Vector2) -> void:
	if _flying:
		return
	_cursor_return_pos = pos
	_flying = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Drop GUI focus so WASD doesn't type into a focused LineEdit.
	var vp := get_viewport()
	if vp:
		vp.gui_release_focus()


func _end_fly() -> void:
	if not _flying:
		return
	_flying = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Return cursor to where the user pressed RMB.
	if _cursor_return_pos != Vector2.ZERO:
		Input.warp_mouse(_cursor_return_pos)


func _begin_pan() -> void:
	_panning = true


func _begin_orbit() -> void:
	# Pivot = center-raycast hit ahead of the camera, fallback to 10m forward.
	var hit := center_raycast()
	if hit.get("hit", false):
		_orbit_pivot = hit["position"]
	else:
		_orbit_pivot = global_position + (-global_transform.basis.z) * 10.0
	_orbiting = true


func _adjust_fly_speed(factor: float) -> void:
	fly_speed = clamp(fly_speed * factor, SPEED_MIN, SPEED_MAX)


func _release_capture() -> void:
	if _flying:
		_flying = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# Public — used by EditorUI in case it needs to know.
func is_flying() -> bool:
	return _flying


# ---- Process / movement -------------------------------------------------

func _process(delta: float) -> void:
	# Only consume movement keys when flying — otherwise WASD belongs to UI
	# (text edits etc.) or just shouldn't do anything.
	if not _flying:
		return
	var fwd: Vector3 = -global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	fwd.y = 0
	if fwd.length() > 0.001:
		fwd = fwd.normalized()
	right.y = 0
	if right.length() > 0.001:
		right = right.normalized()
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move += fwd
	if Input.is_key_pressed(KEY_S): move -= fwd
	if Input.is_key_pressed(KEY_D): move += right
	if Input.is_key_pressed(KEY_A): move -= right
	if Input.is_key_pressed(KEY_E): move += Vector3.UP
	if Input.is_key_pressed(KEY_Q): move -= Vector3.UP
	var speed: float = fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= SPEED_BOOST
	if Input.is_key_pressed(KEY_CTRL):
		speed *= SPEED_FINE
	if move.length() > 1.0:
		move = move.normalized()
	position += move * speed * delta


# ---- Center-screen raycast ---------------------------------------------

# Returns {hit, position, normal, collider}. Casts straight forward from
# the camera origin along its -Z (the screen-center direction), 200m
# range. This is the entire raycast model for editor placement: the
# crosshair at viewport center IS the targeting reticle.
func center_raycast(max_dist: float = 200.0) -> Dictionary:
	var out := {"hit": false, "position": Vector3.ZERO, "normal": Vector3.UP, "collider": null}
	var world := get_world_3d()
	if world == null:
		return out
	var space := world.direct_space_state
	if space == null:
		return out
	var origin: Vector3 = global_position
	var dir: Vector3 = -global_transform.basis.z
	var to: Vector3 = origin + dir * max_dist
	var params := PhysicsRayQueryParameters3D.create(origin, to)
	params.collide_with_areas = true
	params.collide_with_bodies = true
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		out["position"] = origin + dir * 8.0
		return out
	out["hit"] = true
	out["position"] = hit["position"]
	out["normal"] = hit.get("normal", Vector3.UP)
	out["collider"] = hit.get("collider", null)
	return out


# ---- Focus on selection -------------------------------------------------

# Position the camera looking at `target` from a sane distance. Distance
# scales with the target's AABB size if we can compute one; otherwise 6m.
func focus_on(target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	var center: Vector3 = target.global_position
	var dist: float = 6.0
	# If the target has an AABB-able mesh anywhere, fit to it.
	var aabb := _aabb_of(target)
	if aabb.size.length() > 0.01:
		center = aabb.get_center()
		dist = max(3.0, aabb.size.length() * 0.9)
	# Move along the current forward but flipped — we want to be looking AT center.
	# Use current view direction so the user's orientation is preserved.
	var dir: Vector3 = -global_transform.basis.z
	if dir.length() < 0.001:
		dir = Vector3.FORWARD
	global_position = center - dir.normalized() * dist
	look_at(center, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x


static func _aabb_of(root: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is VisualInstance3D:
			var vi: VisualInstance3D = n
			var a: AABB = vi.get_aabb()
			# Translate to world space.
			a.position = vi.global_position + a.position
			if first:
				out = a
				first = false
			else:
				out = out.merge(a)
	return out


# ---- Views ------------------------------------------------------------

func view_top() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = 40.0
	_ortho = true
	position = Vector3(position.x, 40, position.z)
	_yaw = 0
	_pitch = -PI * 0.5
	rotation = Vector3(_pitch, _yaw, 0)


func view_front() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = 40.0
	_ortho = true
	position = Vector3(position.x, 6, 40)
	_yaw = 0
	_pitch = 0
	rotation = Vector3(_pitch, _yaw, 0)


func view_side() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = 40.0
	_ortho = true
	position = Vector3(40, 6, position.z)
	_yaw = PI * 0.5
	_pitch = 0
	rotation = Vector3(_pitch, _yaw, 0)


func toggle_ortho() -> void:
	if projection == PROJECTION_ORTHOGONAL:
		projection = PROJECTION_PERSPECTIVE
		_ortho = false
	else:
		projection = PROJECTION_ORTHOGONAL
		_ortho = true


func view_reset() -> void:
	projection = PROJECTION_PERSPECTIVE
	fov = FOV_DEFAULT
	_ortho = false
	position = Vector3(0, 8, 8)
	_yaw = 0
	_pitch = deg_to_rad(-30)
	rotation = Vector3(_pitch, _yaw, 0)


# Bookmarks ------------------------------------------------------------

func capture_bookmark() -> Dictionary:
	return {
		"position": position,
		"rotation": rotation,
		"fov": fov,
		"projection": projection,
		"size": size,
	}


func apply_bookmark(b: Dictionary) -> void:
	if b.is_empty():
		return
	if b.has("position"):
		position = b["position"]
	if b.has("rotation"):
		rotation = b["rotation"]
		_pitch = rotation.x
		_yaw = rotation.y
	if b.has("fov"):
		fov = b["fov"]
	if b.has("projection"):
		projection = b["projection"]
	if b.has("size"):
		size = b["size"]


# ---- Back-compat shims (no-ops now — kept so old callers don't crash) -

func capture_mouse() -> void:
	# Legacy: no-op. RMB-hold is the only modal capture now.
	pass


func release_mouse() -> void:
	pass


func is_mouse_captured() -> bool:
	return _flying


func set_fov_delta(delta: float) -> void:
	# Legacy: shift FOV. Kept for PageUp/PageDown reset path if anyone calls it.
	fov = clamp(fov + delta, 40.0, 90.0)


func get_forward_xz() -> Vector3:
	var f: Vector3 = -global_transform.basis.z
	f.y = 0
	if f.length() < 0.001:
		return Vector3.FORWARD
	return f.normalized()
