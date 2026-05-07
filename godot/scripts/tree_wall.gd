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

@export var boundary_points: PackedVector2Array = PackedVector2Array([
    Vector2(-15,-15), Vector2(15,-15), Vector2(15,15), Vector2(-15,15)
])
@export var closed: bool = true          # false = don't wrap last → first
                                         # (use to leave an exit gap in the wall)
@export var spacing: float = 1.4         # meters between trunk centers
@export var trunk_height: float = 4.5
@export var trunk_radius: float = 0.35
@export var canopy_height: float = 5.0
@export var canopy_radius: float = 1.6
@export var size_jitter: float = 0.3     # 0–1, randomizes trunk + canopy
@export var seed: int = 1337
@export var wall_height: float = 8.0
@export var trunk_color: Color = Color(0.20, 0.13, 0.09)
@export var canopy_color: Color = Color(0.10, 0.22, 0.12)
@export_tool_button("Rebuild") var _rebuild_btn = _rebuild


func _ready() -> void:
    if get_child_count() == 0:
        _rebuild()


func _rebuild() -> void:
    for child in get_children():
        child.queue_free()
    if boundary_points.size() < 2:
        return

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

    # Collision wall along the segment.
    var body := StaticBody3D.new()
    body.collision_layer = 1
    body.collision_mask = 0
    add_child(body)
    body.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
    var col := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(seg_len, wall_height, 0.4)
    col.shape = box
    var mid := (a + b) * 0.5
    body.global_position = Vector3(mid.x, wall_height * 0.5, mid.y)
    body.rotation.y = -atan2(dir.y, dir.x)
    body.add_child(col)
    if Engine.is_editor_hint():
        col.owner = get_tree().edited_scene_root

    # Trees along the segment. Slight outward offset so the canopy reads
    # as "beyond" the play area, not stuck on the wall.
    var trees_root := Node3D.new()
    trees_root.name = "Trees"
    add_child(trees_root)
    if Engine.is_editor_hint():
        trees_root.owner = get_tree().edited_scene_root

    for i in range(n):
        var t := (i + 0.5) / float(n)
        var p2 := a + dir * (t * seg_len)
        var perp_jitter: float = rng.randf_range(-0.6, 0.4)
        var pos := Vector3(p2.x + normal.x * perp_jitter,
                           0,
                           p2.y + normal.y * perp_jitter)
        var s_jitter: float = 1.0 + rng.randf_range(-size_jitter, size_jitter)

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
