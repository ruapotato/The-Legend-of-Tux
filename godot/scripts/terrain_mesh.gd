extends Node3D
class_name TerrainMesh

# Cell-paint floor + black-hill negative-space border, rendered as a
# single SurfaceTool mesh.
#
# This used to fan 8 triangles around each cell's centre vertex; for
# big maps (sourceplain has ~30k cells once the border is grown) that
# was 240k+ triangles which both blew up rendering time and made the
# trimesh-shape collision rebuild crawl. Switched to a flat 2-triangle
# quad per cell — corners are shared logically across neighbours so
# heights still blend smoothly at corner positions, and the black-
# hill border still slopes up because non-walking cells set higher
# corner heights. ~4× faster mesh + collision build.
#
# Per-corner deterministic ground noise (`ground_noise`) jitters every
# corner Y by a hashed amount so the surface reads as bumpy ground
# instead of a perfectly flat slab. The hash is on (ci, cj) so the
# same corner gets the same offset every run and adjacent cells share
# the same corner value.
#
# Inputs (set by build_dungeon.py per floor):
#   cell_data       Walking cells. [i,j] / [i,j,y_off] /
#                   [i,j,y_off,[r,g,b,a]] / dict form.
#   cell_size       World meters per cell.
#   floor_y         Base Y; per-cell y_off is added.
#   floor_color     Default tint when no per-cell colour override.
#   skirt_depth     Drop on the outermost edge so the mesh doesn't
#                   show its underside.
#   smoothing       Marching-squares-y inset on outer-only corners.
#   border_margin   Cells of black-hill border to grow outward.
#   border_slope    m of rise per cell of distance from walking.
#   border_max      Cap on border height.
#   border_color    Tint for non-walking cells.
#   ground_noise    ±range applied per-corner from a hashed seed.
#   path_cells      Optional [[i,j], ...] list of cell coords painted
#                   with `path_color` and given a flat (non-noisy)
#                   surface. Used by the build script to draw a
#                   "cleared dirt path" leading to each load_zone gap
#                   so the player visually reads the opening as a
#                   walked-down trail through the grass, not just a
#                   missing wall.
#   path_color      Tint for path cells (slightly different shade —
#                   packed dirt). Defaults to a darker version of the
#                   floor_color if left unset.

@export var cell_data:      Array  = []
@export var cell_size:      float  = 2.0
@export var floor_y:        float  = 0.0
@export var floor_color:    Color  = Color(0.30, 0.50, 0.30, 1.0)
@export var skirt_depth:    float  = 6.0
@export var smoothing:      float  = 0.45
@export var roughness:      float  = 0.92

@export var border_margin:  int    = 6
@export var border_slope:   float  = 5.5
@export var border_max:     float  = 20.0
@export var border_color:   Color  = Color(0.05, 0.04, 0.05, 1.0)

@export var ground_noise:   float  = 0.18

@export var path_cells:     Array  = []
@export var path_color:     Color  = Color(0, 0, 0, 0)   # 0-alpha = "auto-derive from floor"


func _ready() -> void:
    # Lets the mini-map find us via get_nodes_in_group, instead of
    # walking the whole scene tree and inspecting every node's
    # property list looking for `cell_data` — which on sourceplain
    # added a multi-second hitch every time the mini-map mounted.
    add_to_group("terrain_mesh")
    _build()


func _parse_cells() -> Dictionary:
    var path_set: Dictionary = _path_cell_set()
    var pc: Color = _effective_path_color()
    var out: Dictionary = {}
    for c in cell_data:
        var i: int = 0; var j: int = 0
        var y_off: float = 0.0
        var col: Color = floor_color
        if c is Dictionary:
            i = int(c.get("i", 0)); j = int(c.get("j", 0))
            if c.has("y"): y_off = float(c["y"])
            if c.has("color") and c["color"] is Array and c["color"].size() >= 3:
                col = Color(c["color"][0], c["color"][1], c["color"][2], 1.0)
        else:
            i = int(c[0]); j = int(c[1])
            if c.size() >= 3 and c[2] != null:
                y_off = float(c[2])
            if c.size() >= 4 and c[3] is Array and c[3].size() >= 3:
                col = Color(c[3][0], c[3][1], c[3][2], 1.0)
        var key := Vector2i(i, j)
        # Path cells override the per-cell colour — the build script
        # uses this to paint a packed-dirt corridor leading to each
        # load-zone gap. The y-offset is preserved so a path crossing
        # raised terrain still drapes over the bumps.
        if path_set.has(key):
            col = pc
        out[key] = {"y": floor_y + y_off, "color": col, "path": path_set.has(key)}
    return out


func _path_cell_set() -> Dictionary:
    var out: Dictionary = {}
    for c in path_cells:
        if c is Vector2i:
            out[c] = true
        elif c is Array and c.size() >= 2:
            out[Vector2i(int(c[0]), int(c[1]))] = true
        elif c is Dictionary and c.has("i") and c.has("j"):
            out[Vector2i(int(c["i"]), int(c["j"]))] = true
    return out


func _effective_path_color() -> Color:
    # Alpha == 0 sentinel means "no override given — derive". We darken
    # the floor colour ~25% for a "packed dirt vs. grass" feel without
    # forcing every level to ship its own colour.
    if path_color.a <= 0.0:
        return floor_color.darkened(0.25)
    return path_color


func _grow_border(walking: Dictionary) -> Dictionary:
    var out: Dictionary = {}
    if border_margin <= 0:
        return out
    var min_i: int = 1 << 30; var max_i: int = -(1 << 30)
    var min_j: int = 1 << 30; var max_j: int = -(1 << 30)
    for k in walking:
        if k.x < min_i: min_i = k.x
        if k.x > max_i: max_i = k.x
        if k.y < min_j: min_j = k.y
        if k.y > max_j: max_j = k.y
    var elo_i: int = min_i - border_margin
    var ehi_i: int = max_i + border_margin
    var elo_j: int = min_j - border_margin
    var ehi_j: int = max_j + border_margin

    var dist:    Dictionary = {}
    var base_y:  Dictionary = {}
    var queue:   Array = []
    for k in walking:
        dist[k]   = 0
        base_y[k] = walking[k].y
        queue.append(k)
    var head: int = 0
    while head < queue.size():
        var current: Vector2i = queue[head]
        head += 1
        var d: int = dist[current] + 1
        for delta in [Vector2i(1, 0), Vector2i(-1, 0),
                      Vector2i(0, 1), Vector2i(0, -1)]:
            var n: Vector2i = current + delta
            if n.x < elo_i or n.x > ehi_i or n.y < elo_j or n.y > ehi_j:
                continue
            if dist.has(n): continue
            dist[n]   = d
            base_y[n] = base_y[current]
            queue.append(n)

    for k in dist:
        if walking.has(k): continue
        var rise: float = min(float(dist[k]) * border_slope, border_max)
        out[k] = {"y": base_y[k] + rise, "color": border_color}
    return out


# Cheap hash → -1..1. Frequency tuned so adjacent cells get visibly
# different values; the constants are the standard "shadertoy hash"
# pair for pseudo-random per-coord noise.
func _hash_noise(ci: int, cj: int) -> float:
    var h: float = sin(float(ci) * 12.9898 + float(cj) * 78.2333) * 43758.5453
    h = h - floor(h)
    return (h - 0.5) * 2.0


func _corner_pos(cells: Dictionary, walking_keys: Dictionary,
                 ci: int, cj: int) -> Vector3:
    var x: float = float(ci) * cell_size
    var z: float = float(cj) * cell_size
    var noise_y: float = _hash_noise(ci, cj) * ground_noise

    var walking_at: Array = []
    var on_path: bool = false
    for di in [-1, 0]:
        for dj in [-1, 0]:
            var k := Vector2i(ci + di, cj + dj)
            if walking_keys.has(k):
                walking_at.append(cells[k].y)
                if cells[k].get("path", false):
                    on_path = true
    if on_path:
        # Path corners get NO noise — a packed-dirt corridor reads as
        # smooth, flattened ground, not the bumpy untracked grass
        # around it. Doing this only on path-touching corners keeps
        # the boundary between path and grass visible.
        noise_y = 0.0
    if not walking_at.is_empty():
        var sy: float = 0.0
        for h in walking_at: sy += h
        return Vector3(x, sy / float(walking_at.size()) + noise_y, z)

    var present: Array = []
    for di in [-1, 0]:
        for dj in [-1, 0]:
            var k := Vector2i(ci + di, cj + dj)
            if cells.has(k):
                present.append([di, dj, cells[k].y])
    var n: int = present.size()
    if n == 0:
        return Vector3(x, floor_y, z)
    var sum_y: float = 0.0
    var dx_sum: float = 0.0
    var dz_sum: float = 0.0
    for p in present:
        sum_y  += p[2]
        dx_sum += float(p[0]) + 0.5
        dz_sum += float(p[1]) + 0.5
    var y: float = sum_y / float(n)
    if n < 4:
        x += (dx_sum / float(n)) * cell_size * smoothing
        z += (dz_sum / float(n)) * cell_size * smoothing
    return Vector3(x, y, z)


func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
    st.add_vertex(a)
    st.add_vertex(b)
    st.add_vertex(c)


func _build() -> void:
    var walking: Dictionary = _parse_cells()
    if walking.is_empty(): return

    var cells: Dictionary = walking.duplicate()
    var border: Dictionary = _grow_border(walking)
    for k in border:
        cells[k] = border[k]

    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    # ---- top surface: 2 triangles per cell, sharing corner positions ----
    for key in cells:
        var ci: int = key.x
        var cj: int = key.y
        var col: Color = cells[key].color
        var nw := _corner_pos(cells, walking, ci,     cj)
        var ne := _corner_pos(cells, walking, ci + 1, cj)
        var se := _corner_pos(cells, walking, ci + 1, cj + 1)
        var sw := _corner_pos(cells, walking, ci,     cj + 1)
        st.set_color(col)
        # Winding chosen so generate_normals produces +Y after the
        # opposite-handed convention SurfaceTool applies — the
        # geometric cross product points +Y when wound clockwise from
        # above, but Godot 4's SurfaceTool flips the sign, so we wind
        # counter-clockwise (NW→SE→SW etc.) to actually face up.
        _add_tri(st, nw, se, sw)
        _add_tri(st, nw, ne, se)

    # ---- skirts at the outer mesh boundary -----------------------------
    for key in cells:
        var ci: int = key.x
        var cj: int = key.y
        var hc: float = cells[key].y
        var col: Color = cells[key].color.darkened(0.50)
        var nw := _corner_pos(cells, walking, ci,     cj)
        var ne := _corner_pos(cells, walking, ci + 1, cj)
        var se := _corner_pos(cells, walking, ci + 1, cj + 1)
        var sw := _corner_pos(cells, walking, ci,     cj + 1)
        var bottom: float = hc - skirt_depth

        st.set_color(col)
        if not cells.has(Vector2i(ci + 1, cj)):
            var b_ne := Vector3(ne.x, bottom, ne.z)
            var b_se := Vector3(se.x, bottom, se.z)
            _add_tri(st, ne, b_ne, b_se)
            _add_tri(st, ne, b_se, se)
        if not cells.has(Vector2i(ci - 1, cj)):
            var b_nw := Vector3(nw.x, bottom, nw.z)
            var b_sw := Vector3(sw.x, bottom, sw.z)
            _add_tri(st, sw, b_sw, b_nw)
            _add_tri(st, sw, b_nw, nw)
        if not cells.has(Vector2i(ci, cj + 1)):
            var b_se := Vector3(se.x, bottom, se.z)
            var b_sw := Vector3(sw.x, bottom, sw.z)
            _add_tri(st, se, b_se, b_sw)
            _add_tri(st, se, b_sw, sw)
        if not cells.has(Vector2i(ci, cj - 1)):
            var b_nw := Vector3(nw.x, bottom, nw.z)
            var b_ne := Vector3(ne.x, bottom, ne.z)
            _add_tri(st, nw, b_nw, b_ne)
            _add_tri(st, nw, b_ne, ne)

    st.generate_normals()
    var mesh: ArrayMesh = st.commit()

    var mat := StandardMaterial3D.new()
    mat.vertex_color_use_as_albedo = true
    mat.roughness = roughness
    mat.metallic = 0.0

    var mi := MeshInstance3D.new()
    mi.mesh = mesh
    mi.material_override = mat
    add_child(mi)

    var sb := StaticBody3D.new()
    sb.collision_layer = 1
    sb.collision_mask = 0
    var cs := CollisionShape3D.new()
    cs.shape = mesh.create_trimesh_shape()
    sb.add_child(cs)
    add_child(sb)
