extends Control

# Procedural item icon. Replaces the colored-rect placeholder in the
# pause menu's Items grid with a tiny silhouette drawn in _draw().
#
# A single Control sized to fit inside an item tile (default 56x56) —
# the silhouette itself is drawn within a 48x48 box with 8px padding,
# centered on the control's actual size at draw time. Set `item_id` to
# pick a shape; set `tint` to override the palette color (defaults to
# the matching pickup_banner.gd swatch). `dim` is multiplied into the
# alpha so the locked / unowned state can render the same shape at
# reduced contrast without rebuilding it.
#
# Shapes are chosen per the design brief — every silhouette is meant
# to be recognisable at glance, not pretty. We deliberately use only
# the cheap Godot draw_* primitives so the whole grid costs a handful
# of microseconds even when the player is rebinding items mid-pause.

# Per-item palette. Mirrors pickup_banner.gd's ITEM_TABLE so the icon
# in the grid matches the pickup banner color the player just saw.
# Anything not listed falls back to a neutral pale-yellow.
const ITEM_COLORS: Dictionary = {
    "sword":           Color(0.85, 0.88, 0.92, 1.0),
    "shield":          Color(0.55, 0.40, 0.25, 1.0),
    "boomerang":       Color(0.42, 0.78, 0.34, 1.0),
    "bow":             Color(0.78, 0.55, 0.30, 1.0),
    "slingshot":       Color(0.55, 0.75, 0.40, 1.0),
    "hookshot":        Color(0.70, 0.55, 0.20, 1.0),
    "hammer":          Color(0.82, 0.30, 0.22, 1.0),
    "bombs":           Color(0.30, 0.30, 0.34, 1.0),
    "lantern":         Color(0.95, 0.78, 0.30, 1.0),
    "glim_sight":      Color(0.55, 0.85, 0.95, 1.0),
    "anchor_boots":    Color(0.45, 0.45, 0.50, 1.0),
    "glim_mirror":     Color(0.85, 0.95, 1.00, 1.0),
    "fairy_bottle":    Color(0.95, 0.55, 0.85, 1.0),
    "heart_container": Color(0.95, 0.30, 0.40, 1.0),
    "heart_piece":     Color(0.85, 0.40, 0.50, 1.0),
    "key":             Color(0.95, 0.78, 0.30, 1.0),
    "pebbles":         Color(0.70, 0.70, 0.72, 1.0),
}

const FALLBACK_COLOR := Color(0.90, 0.85, 0.55, 1.0)

# Padding from control edge to silhouette bounding box.
const PADDING := 8.0

@export var item_id: String = "":
    set(value):
        item_id = value
        queue_redraw()
@export var tint: Color = Color(0, 0, 0, 0):
    set(value):
        tint = value
        queue_redraw()
# Multiplied into alpha — set < 1 for the locked / not-yet-acquired
# state so the same silhouette reads as a faded preview.
@export_range(0.0, 1.0) var dim: float = 1.0:
    set(value):
        dim = value
        queue_redraw()


func _init() -> void:
    custom_minimum_size = Vector2(56, 56)
    mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
    queue_redraw()


func _draw() -> void:
    var col: Color = tint if tint.a > 0.0 else _color_for(item_id)
    col.a = clampf(col.a * dim, 0.0, 1.0)
    var box: Rect2 = _silhouette_box()
    match item_id:
        "sword":           _draw_sword(box, col)
        "shield":          _draw_shield(box, col)
        "boomerang":       _draw_boomerang(box, col)
        "bow":             _draw_bow(box, col)
        "slingshot":       _draw_bow(box, col)    # close enough — Y-frame
        "bombs":           _draw_bomb(box, col)
        "hookshot":        _draw_hookshot(box, col)
        "hammer":          _draw_hammer(box, col)
        "anchor_boots":    _draw_boots(box, col)
        "glim_sight":      _draw_glim_sight(box, col)
        "glim_mirror":     _draw_glim_mirror(box, col)
        "lantern":         _draw_lantern(box, col)
        "fairy_bottle":    _draw_bottle(box, col)
        "heart_container", "heart_piece":
                           _draw_heart(box, col)
        "key":             _draw_key(box, col)
        "pebbles":         _draw_pebbles(box, col)
        _:                 _draw_default(box, col)


# ---- Color + bounds helpers --------------------------------------------

func _color_for(id: String) -> Color:
    return ITEM_COLORS.get(id, FALLBACK_COLOR)


# Returns the 48x48 (default) box centered inside the control rect.
func _silhouette_box() -> Rect2:
    var s: Vector2 = size
    if s.x <= 0.0 or s.y <= 0.0:
        s = custom_minimum_size
    var inner: Vector2 = s - Vector2(PADDING * 2.0, PADDING * 2.0)
    var side: float = minf(inner.x, inner.y)
    var origin: Vector2 = (s - Vector2(side, side)) * 0.5
    return Rect2(origin, Vector2(side, side))


# ---- Per-item silhouettes ----------------------------------------------

# Sword: triangle pointing up + a small crossguard rectangle.
func _draw_sword(box: Rect2, col: Color) -> void:
    var top := Vector2(box.position.x + box.size.x * 0.5,
                       box.position.y + box.size.y * 0.05)
    var bl  := Vector2(box.position.x + box.size.x * 0.32,
                       box.position.y + box.size.y * 0.78)
    var br  := Vector2(box.position.x + box.size.x * 0.68,
                       box.position.y + box.size.y * 0.78)
    draw_polygon(PackedVector2Array([top, br, bl]), PackedColorArray([col]))
    var guard := Rect2(
        box.position.x + box.size.x * 0.18,
        box.position.y + box.size.y * 0.78,
        box.size.x * 0.64,
        box.size.y * 0.08)
    draw_rect(guard, col, true)
    var hilt := Rect2(
        box.position.x + box.size.x * 0.45,
        box.position.y + box.size.y * 0.86,
        box.size.x * 0.10,
        box.size.y * 0.10)
    draw_rect(hilt, col, true)


# Shield: pentagon (point down).
func _draw_shield(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    var pts := PackedVector2Array([
        Vector2(ox + w * 0.20, oy + h * 0.10),
        Vector2(ox + w * 0.80, oy + h * 0.10),
        Vector2(ox + w * 0.92, oy + h * 0.45),
        Vector2(ox + w * 0.50, oy + h * 0.95),
        Vector2(ox + w * 0.08, oy + h * 0.45),
    ])
    draw_polygon(pts, PackedColorArray([col]))


# Boomerang: V-shape — two triangle legs meeting at a centered apex.
func _draw_boomerang(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    # Left arm.
    var l1 := Vector2(ox + w * 0.10, oy + h * 0.20)
    var l2 := Vector2(ox + w * 0.30, oy + h * 0.10)
    var apex := Vector2(ox + w * 0.50, oy + h * 0.85)
    var r1 := Vector2(ox + w * 0.90, oy + h * 0.20)
    var r2 := Vector2(ox + w * 0.70, oy + h * 0.10)
    draw_polygon(PackedVector2Array([l1, l2, apex]),
                 PackedColorArray([col]))
    draw_polygon(PackedVector2Array([r2, r1, apex]),
                 PackedColorArray([col]))


# Bow: arc with a chord (string) joining the tips.
func _draw_bow(box: Rect2, col: Color) -> void:
    var center := Vector2(box.position.x + box.size.x * 0.62,
                          box.position.y + box.size.y * 0.50)
    var radius: float = box.size.x * 0.42
    # Arc from -110 deg to +110 deg around the center, opening to the
    # right of screen (so it looks like a bow drawn left-to-right).
    var pts := PackedVector2Array()
    var seg: int = 18
    var a0: float = deg_to_rad(110.0)
    var a1: float = deg_to_rad(250.0)
    for i in seg + 1:
        var t: float = float(i) / float(seg)
        var a: float = lerpf(a0, a1, t)
        pts.append(center + Vector2(cos(a), sin(a)) * radius)
    draw_polyline(pts, col, 2.5, true)
    # Chord (string) — straight line between the two endpoints.
    if pts.size() >= 2:
        draw_line(pts[0], pts[pts.size() - 1], col, 1.5, true)


# Bomb: filled circle with a small fuse rect on top.
func _draw_bomb(box: Rect2, col: Color) -> void:
    var center := Vector2(box.position.x + box.size.x * 0.50,
                          box.position.y + box.size.y * 0.58)
    var r: float = box.size.x * 0.34
    draw_circle(center, r, col)
    var fuse := Rect2(
        center.x - box.size.x * 0.04,
        center.y - r - box.size.y * 0.20,
        box.size.x * 0.08,
        box.size.y * 0.20)
    draw_rect(fuse, col, true)


# Hookshot: rectangle (chain/stem) with a triangle hook on the end.
func _draw_hookshot(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    # Stem along the diagonal — rendered as a straight horizontal-ish
    # rectangle so the silhouette stays readable at small sizes.
    var stem := Rect2(
        ox + w * 0.20, oy + h * 0.55,
        w * 0.55, h * 0.10)
    draw_rect(stem, col, true)
    # Hook: small triangle at the right end pointing up-right.
    var p1 := Vector2(ox + w * 0.75, oy + h * 0.55)
    var p2 := Vector2(ox + w * 0.95, oy + h * 0.30)
    var p3 := Vector2(ox + w * 0.78, oy + h * 0.30)
    draw_polygon(PackedVector2Array([p1, p2, p3]),
                 PackedColorArray([col]))
    # Tail handle — small rect at the left end so it reads as a tool.
    var handle := Rect2(
        ox + w * 0.10, oy + h * 0.50,
        w * 0.10, h * 0.20)
    draw_rect(handle, col, true)


# Hammer: T-shape — head rect on top + handle rect below.
func _draw_hammer(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    var head := Rect2(
        ox + w * 0.15, oy + h * 0.18,
        w * 0.70, h * 0.22)
    draw_rect(head, col, true)
    var handle := Rect2(
        ox + w * 0.42, oy + h * 0.40,
        w * 0.16, h * 0.55)
    draw_rect(handle, col, true)


# Anchor Boots: trapezoid (boot silhouette).
func _draw_boots(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    # Trapezoid tapering toward the top — wider at the foot.
    var pts := PackedVector2Array([
        Vector2(ox + w * 0.34, oy + h * 0.15),
        Vector2(ox + w * 0.66, oy + h * 0.15),
        Vector2(ox + w * 0.90, oy + h * 0.85),
        Vector2(ox + w * 0.10, oy + h * 0.85),
    ])
    draw_polygon(pts, PackedColorArray([col]))


# Glim Sight: filled circle with a small ring around it.
func _draw_glim_sight(box: Rect2, col: Color) -> void:
    var center := Vector2(box.position.x + box.size.x * 0.50,
                          box.position.y + box.size.y * 0.50)
    var inner_r: float = box.size.x * 0.18
    var ring_r: float = box.size.x * 0.40
    draw_circle(center, inner_r, col)
    # Ring drawn as a polyline circle — Godot's draw_arc would also
    # work but polyline keeps the line thickness consistent with the
    # other silhouettes.
    var pts := PackedVector2Array()
    var seg: int = 28
    for i in seg + 1:
        var a: float = TAU * float(i) / float(seg)
        pts.append(center + Vector2(cos(a), sin(a)) * ring_r)
    draw_polyline(pts, col, 2.0, true)


# Glim Mirror: pentagon (same outline as the shield, different fill)
# with an inner sparkle — the shield reads as a defensive silhouette;
# this reads as a polished facet.
func _draw_glim_mirror(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    var pts := PackedVector2Array([
        Vector2(ox + w * 0.20, oy + h * 0.10),
        Vector2(ox + w * 0.80, oy + h * 0.10),
        Vector2(ox + w * 0.92, oy + h * 0.45),
        Vector2(ox + w * 0.50, oy + h * 0.95),
        Vector2(ox + w * 0.08, oy + h * 0.45),
    ])
    draw_polygon(pts, PackedColorArray([col]))
    # Inner facet — a smaller pentagon offset toward the upper-left
    # so the silhouette reads as something that REFLECTS, not blocks.
    var inner_col: Color = Color(1.0 - col.r * 0.5,
                                 1.0 - col.g * 0.5,
                                 1.0 - col.b * 0.5,
                                 col.a * 0.7)
    var ipts := PackedVector2Array([
        Vector2(ox + w * 0.36, oy + h * 0.28),
        Vector2(ox + w * 0.58, oy + h * 0.28),
        Vector2(ox + w * 0.64, oy + h * 0.45),
        Vector2(ox + w * 0.46, oy + h * 0.66),
        Vector2(ox + w * 0.30, oy + h * 0.45),
    ])
    draw_polygon(ipts, PackedColorArray([inner_col]))


# Lantern: filled lozenge (rotated rectangle).
func _draw_lantern(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    var pts := PackedVector2Array([
        Vector2(ox + w * 0.50, oy + h * 0.08),    # top
        Vector2(ox + w * 0.85, oy + h * 0.50),    # right
        Vector2(ox + w * 0.50, oy + h * 0.92),    # bottom
        Vector2(ox + w * 0.15, oy + h * 0.50),    # left
    ])
    draw_polygon(pts, PackedColorArray([col]))
    # Tiny handle on top — reinforces "lantern" over "gem".
    var handle := Rect2(
        ox + w * 0.46, oy + h * 0.02,
        w * 0.08, h * 0.08)
    draw_rect(handle, col, true)


# Fairy Bottle: rounded rectangle with a smaller cap rectangle on top.
# We approximate the rounded body as a tall rect plus a circle bottom
# to suggest the curve without going to draw_arc for every corner.
func _draw_bottle(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    var body := Rect2(
        ox + w * 0.30, oy + h * 0.25,
        w * 0.40, h * 0.55)
    draw_rect(body, col, true)
    # Rounded shoulders + base — circles at the four interior corners.
    var r: float = w * 0.08
    draw_circle(Vector2(body.position.x + r, body.position.y + body.size.y - r), r, col)
    draw_circle(Vector2(body.position.x + body.size.x - r,
                        body.position.y + body.size.y - r), r, col)
    # Bottom curve — a half-disc by drawing a circle with the upper
    # half visually subsumed by the body rect.
    draw_circle(Vector2(body.position.x + body.size.x * 0.5,
                        body.position.y + body.size.y - 1.0),
                w * 0.20, col)
    # Cap.
    var cap := Rect2(
        ox + w * 0.40, oy + h * 0.15,
        w * 0.20, h * 0.12)
    draw_rect(cap, col, true)


# Heart: two circles + a triangle at the bottom. The classic.
func _draw_heart(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    var lobe_r: float = w * 0.20
    var lobe_l := Vector2(ox + w * 0.32, oy + h * 0.34)
    var lobe_r_pos := Vector2(ox + w * 0.68, oy + h * 0.34)
    draw_circle(lobe_l, lobe_r, col)
    draw_circle(lobe_r_pos, lobe_r, col)
    # Triangle from the lobe outer edges down to a point.
    var tip := Vector2(ox + w * 0.50, oy + h * 0.90)
    var tl  := Vector2(ox + w * 0.12, oy + h * 0.40)
    var tr  := Vector2(ox + w * 0.88, oy + h * 0.40)
    draw_polygon(PackedVector2Array([tl, tr, tip]),
                 PackedColorArray([col]))


# Skeleton key: rectangle stem + circle bow at one end + small notch.
func _draw_key(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    # Bow (the loop at the top of the key).
    var bow_center := Vector2(ox + w * 0.30, oy + h * 0.30)
    var bow_r: float = w * 0.18
    draw_circle(bow_center, bow_r, col)
    # Hollow the bow visually with an inner darker dot — gives the
    # silhouette its key-shape read at a glance.
    var hole_col: Color = Color(col.r * 0.25, col.g * 0.25, col.b * 0.25, col.a)
    draw_circle(bow_center, bow_r * 0.45, hole_col)
    # Stem from the bow toward the bottom-right.
    var stem := Rect2(
        ox + w * 0.36, oy + h * 0.42,
        w * 0.45, h * 0.10)
    draw_rect(stem, col, true)
    # Bit / teeth.
    var tooth := Rect2(
        ox + w * 0.74, oy + h * 0.52,
        w * 0.10, h * 0.12)
    draw_rect(tooth, col, true)
    var tooth2 := Rect2(
        ox + w * 0.62, oy + h * 0.52,
        w * 0.06, h * 0.08)
    draw_rect(tooth2, col, true)


# Pebbles: a small cluster of three circles. Not in the design brief
# but pebbles ARE in KNOWN_ITEMS so we need a glyph.
func _draw_pebbles(box: Rect2, col: Color) -> void:
    var w: float = box.size.x
    var h: float = box.size.y
    var ox: float = box.position.x
    var oy: float = box.position.y
    draw_circle(Vector2(ox + w * 0.32, oy + h * 0.62), w * 0.16, col)
    draw_circle(Vector2(ox + w * 0.62, oy + h * 0.50), w * 0.20, col)
    draw_circle(Vector2(ox + w * 0.55, oy + h * 0.78), w * 0.12, col)


# Fallback: small filled square + a question-mark-ish dot. Used for
# any item id not handled above so the tile never renders blank.
func _draw_default(box: Rect2, col: Color) -> void:
    var inset := Rect2(
        box.position.x + box.size.x * 0.20,
        box.position.y + box.size.y * 0.20,
        box.size.x * 0.60,
        box.size.y * 0.60)
    draw_rect(inset, col, false, 2.0)
    draw_circle(box.position + box.size * 0.5, box.size.x * 0.10, col)
