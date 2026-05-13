extends Node3D

# Root of the procedural overworld scene. Wires the WorldStreamer to
# Tux + the Chunks container, force-loads the spawn chunks before the
# first frame so Tux doesn't free-fall, and snaps Tux onto the surface.

@onready var _tux: Node3D = $Tux
@onready var _chunks_root: Node3D = $Chunks


func _ready() -> void:
	WorldStreamer.set_container(_chunks_root)
	WorldStreamer.set_player(_tux)
	# Spawn Tux at the centre of the starter island, snapped to the
	# surface plus a small clearance. Phase 4 (POI seeder) will likely
	# move this to a specific entry POI; for now (0, 0) is fine.
	var sy: float = WorldGen.height_at(0.0, 0.0) + 1.5
	_tux.position = Vector3(0, sy, 0)
	# Pre-warm the chunks around the spawn so collision exists by the
	# time gravity kicks in this frame.
	WorldStreamer.force_load_around(_tux.position)
