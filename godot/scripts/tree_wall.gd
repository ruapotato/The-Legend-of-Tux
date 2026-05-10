@tool
extends Node3D

# Distant-tree visual boundary. Spawns a row of stylized tree silhouettes
# along a closed polyline (the boundary path) plus an invisible static
# collision wall directly behind them, so the trees both READ as a far-
# off horizon and PHYSICALLY stop the player from leaving the play area.
#
# Procedural geometry: brown cylinder trunks + dark-green cone canopies.
# Lit unshaded so they read as far-away silhouettes regardless of scene
# lighting. Slight per-tree size jitter sells the variety.
#
# To use: drop a TreeWall node, set `boundary_points` to a list of XZ
# corners (CCW), and an arena floor will be naturally fenced. The path
# auto-closes (last → first).
#
# Gaps: the optional `gaps` export carves clearings into the wall so
# load_zones feel like *paths through the trees* instead of "a black
# rectangle plopped onto a wall of green". Each gap is a Dictionary
# {"angle": <radians, 0=east, +y=north>, "width": <radians arc width>}.
# The gap angle is measured from the boundary's centroid; any tree (or
# collision-wall segment piece) whose own centroid-angle lies within
# `gap.width / 2` of `gap.angle` is dropped. Same input → same output;
# no randomness in gap math.

@export var boundary_points: PackedVector2Array = PackedVector2Array([
    Vector2(-15,-15), Vector2(15,-15), Vector2(15,15), Vector2(-15,15)
])
@export var closed: bool = true          # false = don't wrap last → first
                                         # (use to leave an exit gap in the wall)
@export var spacing: float = 0.7         # meters between trunk centers —
                                         # tight packing hides the grey
                                         # void behind the wall.
@export var trunk_height: float = 4.5
@export var trunk_radius: float = 0.32
@export var canopy_height: float = 5.5
@export var canopy_radius: float = 1.9   # canopies overlap noticeably
                                         # which seals gaps overhead.
@export var size_jitter: float = 0.3     # 0–1, randomizes trunk + canopy
@export var seed: int = 1337
@export var wall_height: float = 8.0
@export var trunk_color: Color = Color(0.20, 0.13, 0.09)
@export var canopy_color: Color = Color(0.10, 0.22, 0.12)

# List of {"angle": float (radians), "width": float (radians)}.
# A tree's angle relative to the boundary centroid is checked against
# every gap; if it falls within `width/2` of a gap's centre, the tree
# (and the underlying collision wall sub-piece) is omitted. This is
# how load_zones become *visible openings* in the tree wall instead
# of black rectangles glued onto an unbroken hedge.
@export var gaps: Array = []

@export_tool_button("Rebuild") var _rebuild_btn = _rebuild

# Cached centroid of `boundary_points` (XZ); used to compute each
# tree's angle. Initialised in _rebuild().
var _centroid: Vector2 = Vector2.ZERO


func _ready() -> void:
    if get_child_count() == 0:
        _rebuild()


func _rebuild() -> void:
    for child in get_children():
        child.queue_free()
    if boundary_points.size() < 2:
        return

    _centroid = _compute_centroid(boundary_points)

    var rng := RandomNumberGenerator.new()
    rng.seed = seed

    var trunk_mesh := CylinderMesh.new()
    trunk_mesh.top_radius = trunk_radius * 0.85
    trunk_mesh.bottom_radius = trunk_radius
    trunk_mesh.height = trunk_height
    trunk_mesh.radial_segments = 8

    var canopy_mesh := SphereMesh.new()
    canopy_mesh.radius = canopy_radius
    canopy_mesh.height = canopy_height
    canopy_mesh.radial_segments = 10
    canopy_mesh.rings = 6

    var trunk_mat := StandardMaterial3D.new()
    trunk_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
    trunk_mat.albedo_color = trunk_color

    var canopy_mat := StandardMaterial3D.new()
    canopy_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
    canopy_mat.albedo_color = canopy_color

    # Walk each segment, dropping trunks at intervals and dropping a
    # collision wall along the segment. If `closed` is false the last
    # point doesn't connect back to the first — that's how we leave an
    # exit visible in the tree boundary.
    var n := boundary_points.size()
    var pairs := n if closed else n - 1
    for i in range(pairs):
        var a := boundary_points[i]
        var b := boundary_points[(i + 1) % n]
        _spawn_segment(a, b, rng, trunk_mesh, canopy_mesh, trunk_mat, canopy_mat)


func _compute_centroid(pts: PackedVector2Array) -> Vector2:
    var sum := Vector2.ZERO
    for p in pts:
        sum += p
    return sum / float(pts.size())


# Smallest signed difference between two angles, normalised to [-PI, PI].
static func _angle_diff(a: float, b: float) -> float:
    var d: float = fposmod(a - b + PI, TAU) - PI
    return d


# True if the world-XZ position falls inside any configured gap.
# Tested per tree (and per collision sub-segment) so a gap can carve
# both a visible opening and the underlying wall section away.
func _in_gap(world_xz: Vector2) -> bool:
    if gaps.is_empty():
        return false
    var rel: Vector2 = world_xz - _centroid
    if rel.length_squared() < 1e-6:
        return false
    var ang: float = atan2(rel.y, rel.x)
    for g in gaps:
        if not (g is Dictionary):
            continue
        var ga: float = float(g.get("angle", 0.0))
        var gw: float = float(g.get("width", 0.0))
        if gw <= 0.0:
            continue
        if abs(_angle_diff(ang, ga)) <= gw * 0.5:
            return true
    return false


func _spawn_segment(
    a: Vector2, b: Vector2, rng: RandomNumberGenerator,
    trunk_mesh: Mesh, canopy_mesh: Mesh, trunk_mat: Material, canopy_mat: Material
) -> void:
    var seg := b - a
    var seg_len := seg.length()
    if seg_len < 0.001:
        return
    var dir := seg.normalized()
    var normal := Vector2(-dir.y, dir.x)   # inward/outward (we don't care)
    var n := int(floor(seg_len / spacing))
    if n < 1:
        n = 1

    # Trees along the segment. Slight outward offset so the canopy reads
    # as "beyond" the play area, not stuck on the wall.
    var trees_root := Node3D.new()
    trees_root.name = "Trees"
    add_child(trees_root)
    if Engine.is_editor_hint():
        trees_root.owner = get_tree().edited_scene_root

    # Walking pass: decide per-slot whether the tree is in a gap, and
    # carve the collision wall to match so the player can actually
    # step through the visible opening (otherwise we'd have an
    # invisible wall in the gap, which is exactly the bug we're
    # trying to fix).
    var slot_world: Array = []     # XZ positions per slot
    var slot_kept: Array = []      # bool per slot
    for i in range(n):
        var t := (i + 0.5) / float(n)
        var p2 := a + dir * (t * seg_len)
        slot_world.append(p2)
        # Tree gets dropped if its slot midpoint OR the underlying
        # boundary point is inside a configured gap. Use the boundary
        # midpoint (no jitter) for the gap test so the gap location
        # is deterministic.
        var keep: bool = not _in_gap(p2)
        slot_kept.append(keep)

    # Emit a collision wall *piece* for each contiguous run of kept
    # slots. This way the gap is physically open as well as visually
    # open. For a fully kept segment we get one wall identical to the
    # old behaviour.
    var run_start: int = -1
    for i in range(n + 1):
        var kept: bool = i < n and slot_kept[i]
        if kept and run_start < 0:
            run_start = i
        elif not kept and run_start >= 0:
            _emit_wall_piece(a, dir, seg_len, n, run_start, i - 1)
            run_start = -1

    # Trees themselves.
    for i in range(n):
        if not slot_kept[i]:
            # Skip the trunk + canopy entirely. The gap reads as a
            # visible opening because no trees are placed here.
            # Still advance the RNG so removing/adding a single gap
            # doesn't reshuffle every other tree's jitter.
            rng.randf()
            rng.randf()
            continue
        var p2: Vector2 = slot_world[i]
        var perp_jitter: float = rng.randf_range(-0.6, 0.4)
        var s_jitter: float = 1.0 + rng.randf_range(-size_jitter, size_jitter)
        var pos := Vector3(p2.x + normal.x * perp_jitter,
                           0,
                           p2.y + normal.y * perp_jitter)

        var trunk := MeshInstance3D.new()
        trunk.mesh = trunk_mesh
        trunk.material_override = trunk_mat
        trunk.position = pos + Vector3(0, trunk_height * s_jitter * 0.5, 0)
        trunk.scale = Vector3(s_jitter, s_jitter, s_jitter)
        trees_root.add_child(trunk)
        if Engine.is_editor_hint():
            trunk.owner = get_tree().edited_scene_root

        var canopy := MeshInstance3D.new()
        canopy.mesh = canopy_mesh
        canopy.material_override = canopy_mat
        canopy.position = pos + Vector3(0, trunk_height * s_jitter + canopy_radius * s_jitter * 0.4, 0)
        canopy.scale = Vector3(s_jitter, s_jitter, s_jitter)
        trees_root.add_child(canopy)
        if Engine.is_editor_hint():
            canopy.owner = get_tree().edited_scene_root


func _emit_wall_piece(a: Vector2, dir: Vector2, seg_len: float,
                      slot_count: int, i0: int, i1: int) -> void:
    # Cover slots [i0..i1] inclusive with a single box collider. Slot
    # i has midpoint at t = (i+0.5)/n along the segment, so the run
    # spans t in [i0/n, (i1+1)/n] — convert that to world.
    var t0: float = float(i0) / float(slot_count)
    var t1: float = float(i1 + 1) / float(slot_count)
    var p_start: Vector2 = a + dir * (t0 * seg_len)
    var p_end: Vector2 = a + dir * (t1 * seg_len)
    var piece_len: float = (p_end - p_start).length()
    if piece_len < 0.001:
        return
    var mid: Vector2 = (p_start + p_end) * 0.5

    var body := StaticBody3D.new()
    body.collision_layer = 1
    body.collision_mask = 0
    add_child(body)
    body.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
    var col := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(piece_len, wall_height, 0.4)
    col.shape = box
    body.global_position = Vector3(mid.x, wall_height * 0.5, mid.y)
    body.rotation.y = -atan2(dir.y, dir.x)
    body.add_child(col)
    if Engine.is_editor_hint():
        col.owner = get_tree().edited_scene_root
