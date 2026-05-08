extends Node3D
class_name TerrainMesh

# Cell-paint floor + black-hill negative-space border. The walking
# cells (passed in via cell_data) become a smoothed mesh with optional
# per-cell heights and colours. Everything inside an extended bounding
# box that ISN'T a walking cell becomes a non-walking "border" cell:
# coloured nearly-black and rising in height with distance from the
# nearest walking cell, so the level is visually walled in by a steep
# black hillscape rather than dropping off into a grey void.
#
# Inputs (set by build_dungeon.py per floor):
#   cell_data       Walking cells. Same heterogeneous form as before:
#                   [i,j] / [i,j,y_off] / [i,j,y_off,[r,g,b,a]] / dict.
#   cell_size       World meters per cell.
#   floor_y         Base Y; per-cell y_off is added.
#   floor_color     Default tint when no per-cell colour override.
#   skirt_depth     How far the outer cliffs drop below their top so
#                   the player can never see undermesh.
#   smoothing       0..1; corner inset for marching-squares-y look on
#                   the OUTER non-walking ring.
#   border_margin   Cells of border to grow outward from the walking
#                   bounding box. 0 disables the black-hill effect
#                   (legacy behaviour: walking cells with skirts only).
#   border_slope    Meters of rise per cell of distance from the
#                   nearest walking cell — controls how steep the
#                   black wall is.
#   border_max      Cap on border height so far cells don't shoot to
#                   infinity.
#   border_color    Tint for non-walking cells. Near-black by default.

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


func _ready() -> void:
    _build()


func _parse_cells() -> Dictionary:
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
        out[Vector2i(i, j)] = {"y": floor_y + y_off, "color": col, "walk": true}
    return out


func _grow_border(walking: Dictionary) -> Dictionary:
    # BFS outward from walking cells, propagating distance + base_y.
    # Non-walking cells take their nearest walker's Y as the local
    # base, so when walking terrain is hilly the border tracks it.
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
        out[k] = {"y": base_y[k] + rise, "color": border_color, "walk": false}
    return out


func _corner_pos(cells: Dictionary, walking_keys: Dictionary,
                 ci: int, cj: int) -> Vector3:
    # Walking cells anchor their corners flat at walking-y. Border
    # cells average and inset toward the centroid of present cells
    # (marching-squares smoothing) so a single internal hole rounds
    # off into a diamond/cone instead of a hard square pit.
    var x: float = float(ci) * cell_size
    var z: float = float(cj) * cell_size

    var walking_at: Array = []
    for di in [-1, 0]:
        for dj in [-1, 0]:
            var k := Vector2i(ci + di, cj + dj)
            if walking_keys.has(k):
                walking_at.append(cells[k].y)
    if not walking_at.is_empty():
        var sy: float = 0.0
        for h in walking_at: sy += h
        return Vector3(x, sy / float(walking_at.size()), z)

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


func _edge_mid(cells: Dictionary, ci: int, cj: int, ni: int, nj: int) -> Vector3:
    var h_self: float = cells[Vector2i(ci, cj)].y
    var h_other: float = h_self
    if cells.has(Vector2i(ni, nj)):
        h_other = cells[Vector2i(ni, nj)].y
    var ax := Vector2((float(ci) + 0.5) * cell_size, (float(cj) + 0.5) * cell_size)
    var bx := Vector2((float(ni) + 0.5) * cell_size, (float(nj) + 0.5) * cell_size)
    var mid := (ax + bx) * 0.5
    return Vector3(mid.x, (h_self + h_other) * 0.5, mid.y)


func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
    st.add_vertex(a)
    st.add_vertex(b)
    st.add_vertex(c)


func _build() -> void:
    var walking: Dictionary = _parse_cells()
    if walking.is_empty(): return

    # Combine walking + non-walking border into one cell map.
    var cells: Dictionary = walking.duplicate()
    var border: Dictionary = _grow_border(walking)
    for k in border:
        cells[k] = border[k]

    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    for key in cells:
        var ci: int = key.x
        var cj: int = key.y
        var cell: Dictionary = cells[key]
        var col: Color = cell.color
        var hc: float = cell.y

        var nw := _corner_pos(cells, walking, ci,     cj)
        var ne := _corner_pos(cells, walking, ci + 1, cj)
        var se := _corner_pos(cells, walking, ci + 1, cj + 1)
        var sw := _corner_pos(cells, walking, ci,     cj + 1)
        var n_mid := _edge_mid(cells, ci, cj, ci,     cj - 1)
        var e_mid := _edge_mid(cells, ci, cj, ci + 1, cj)
        var s_mid := _edge_mid(cells, ci, cj, ci,     cj + 1)
        var w_mid := _edge_mid(cells, ci, cj, ci - 1, cj)
        var center := Vector3((float(ci) + 0.5) * cell_size, hc,
                              (float(cj) + 0.5) * cell_size)

        st.set_color(col)
        _add_tri(st, center, nw,    n_mid)
        _add_tri(st, center, n_mid, ne)
        _add_tri(st, center, ne,    e_mid)
        _add_tri(st, center, e_mid, se)
        _add_tri(st, center, se,    s_mid)
        _add_tri(st, center, s_mid, sw)
        _add_tri(st, center, sw,    w_mid)
        _add_tri(st, center, w_mid, nw)

    # Skirts at outermost edges of the combined mesh. With
    # border_margin > 0 these are far away from the playable area;
    # with border_margin = 0 they sit at the walking-cell perimeter
    # and behave like the original cliff drops.
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
