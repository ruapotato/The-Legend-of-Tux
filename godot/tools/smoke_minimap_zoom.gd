extends SceneTree

# Headless verification of the mini-map zoom cycle. Loads the script,
# instantiates the autoload-style node, and verifies that _cycle_zoom
# walks through LOCAL → REGIONAL → WORLD and clamps at the ends.
#
# Run with:
#   ./Godot_v4.5.1-stable_linux.x86_64 --headless --path godot \
#       --script res://tools/smoke_minimap_zoom.gd

const MiniMap = preload("res://scripts/world_mini_map.gd")

func _initialize() -> void:
	var mm: Node = MiniMap.new()
	# _ready will try to build Controls with parent refs, which requires
	# the node to be inside a tree. Add to root just so init runs.
	get_root().add_child(mm)

	var ok := true
	ok = _assert_eq(mm._current_zoom, mm.Zoom.LOCAL, "starts at LOCAL") and ok
	mm._cycle_zoom(+1)
	ok = _assert_eq(mm._current_zoom, mm.Zoom.REGIONAL, "+1 → REGIONAL") and ok
	mm._cycle_zoom(+1)
	ok = _assert_eq(mm._current_zoom, mm.Zoom.WORLD, "+1 → WORLD") and ok
	mm._cycle_zoom(+1)
	ok = _assert_eq(mm._current_zoom, mm.Zoom.WORLD, "+1 clamps at WORLD") and ok
	mm._cycle_zoom(-1)
	ok = _assert_eq(mm._current_zoom, mm.Zoom.REGIONAL, "-1 → REGIONAL") and ok
	mm._cycle_zoom(-1)
	ok = _assert_eq(mm._current_zoom, mm.Zoom.LOCAL, "-1 → LOCAL") and ok
	mm._cycle_zoom(-1)
	ok = _assert_eq(mm._current_zoom, mm.Zoom.LOCAL, "-1 clamps at LOCAL") and ok

	print("SMOKE_RESULT: ", "PASS" if ok else "FAIL")
	mm.queue_free()
	quit(0 if ok else 1)


func _assert_eq(actual: int, expected: int, label: String) -> bool:
	if actual == expected:
		print("  OK    %s  (zoom=%d)" % [label, actual])
		return true
	print("  FAIL  %s  expected=%d actual=%d" % [label, expected, actual])
	return false
