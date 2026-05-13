extends Node

# Autoload. Streams WorldChunk nodes around the player.
#
# Compute (heightmap + foliage spec generation) happens in worker
# threads via WorkerThreadPool so a chunk load doesn't hitch the main
# thread. Only the node-creation step (ArrayMesh build + add_child) runs
# on the main thread — that's the part that has to.
#
# Hysteresis between LOAD_RADIUS and UNLOAD_RADIUS prevents thrash at
# chunk boundaries. A small synchronous ring is force-loaded on scene
# spawn so the player has ground under them on frame 0; everything else
# streams in.

const LOAD_RADIUS:   int = 6       # chunks loaded in each direction (13x13 grid)
const UNLOAD_RADIUS: int = 8       # beyond this, drop the chunk (hysteresis)
const FORCE_LOAD_R:  int = 2       # synchronous ring on spawn (5x5)

const MAX_INFLIGHT: int = 4        # concurrent generate_data tasks
const POLL_FRAMES:  int = 4        # how often to check player chunk + drain results

# Cap how many chunks we instance per frame. Workers can keep
# generating ahead; results sit in _pending_apply until the main
# thread picks them up. Keeps frame time bounded regardless of how
# fast the worker pool drains the queue.
const MAX_APPLY_PER_FRAME: int = 1

const WorldChunkScript = preload("res://scripts/world_chunk.gd")

var _container: Node3D = null
var _player: Node3D = null
var _chunks: Dictionary = {}       # Vector2i -> StaticBody3D
var _pending: Array = []           # Vector2i, FIFO queue of chunks to generate
var _inflight: Dictionary = {}     # task_id (int) -> Vector2i
var _completed: Dictionary = {}    # Vector2i -> Dictionary (chunk data, populated by workers)
var _completed_mtx := Mutex.new()

# Main-thread apply queue. Worker results funnel here as soon as the
# task completes; we then materialize at most MAX_APPLY_PER_FRAME
# chunks per frame so we never spike on instantiation cost.
var _pending_apply: Array = []     # Array[{cc, data}]

var _last_player_chunk: Vector2i = Vector2i(2147483647, 2147483647)
var _frame: int = 0


# ---- Public API ---------------------------------------------------------

func set_container(c: Node3D) -> void:
	_container = c
	# Drop bookkeeping on scene swap — old chunks are owned by the
	# previous container and will be freed with it.
	_chunks.clear()
	_pending.clear()
	_inflight.clear()
	_completed.clear()
	_pending_apply.clear()
	_last_player_chunk = Vector2i(2147483647, 2147483647)


func set_player(p: Node3D) -> void:
	_player = p


# Synchronously load a small ring around `pos` so the player has terrain
# to stand on the very first frame. The rest of LOAD_RADIUS streams in
# async via _process.
func force_load_around(pos: Vector3) -> void:
	if _container == null or not is_instance_valid(_container):
		return
	var pc := _world_to_chunk(pos)
	for dz in range(-FORCE_LOAD_R, FORCE_LOAD_R + 1):
		for dx in range(-FORCE_LOAD_R, FORCE_LOAD_R + 1):
			var cc := Vector2i(pc.x + dx, pc.y + dz)
			if _chunks.has(cc):
				continue
			var data: Dictionary = WorldChunkScript.generate_data(cc, WorldGen.world_seed)
			_create_chunk_from_data(cc, data)
	_last_player_chunk = pc
	# Queue the rest of LOAD_RADIUS for async generation.
	_enqueue_ring(pc)


# Debug — used by the FPS overlay.
func active_chunk_count() -> int:
	return _chunks.size()


func inflight_count() -> int:
	return _inflight.size()


func pending_count() -> int:
	return _pending.size()


func pending_apply_count() -> int:
	return _pending_apply.size()


# ---- Main loop ---------------------------------------------------------

func _process(_dt: float) -> void:
	if _container == null or not is_instance_valid(_container):
		return
	if _player == null or not is_instance_valid(_player):
		return
	_frame += 1
	if _frame % POLL_FRAMES != 0:
		# Even when not re-evaluating ring, drain completed tasks each
		# frame so chunks pop in promptly.
		_drain_completed()
		return
	var pc := _world_to_chunk(_player.global_position)
	if pc != _last_player_chunk:
		_last_player_chunk = pc
		_enqueue_ring(pc)
		_unload_far(pc)
	_launch_pending()
	_drain_completed()


func _world_to_chunk(p: Vector3) -> Vector2i:
	var sz: float = WorldChunkScript.CHUNK_SIZE
	return Vector2i(int(floor(p.x / sz)), int(floor(p.z / sz)))


# Queue every missing chunk in LOAD_RADIUS for async generation. Skips
# anything that's already loaded OR in-flight OR pending.
func _enqueue_ring(pc: Vector2i) -> void:
	var pending_set := {}
	for cc in _pending:
		pending_set[cc] = true
	var inflight_set := {}
	for cc in _inflight.values():
		inflight_set[cc] = true
	for dz in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			var cc := Vector2i(pc.x + dx, pc.y + dz)
			if _chunks.has(cc) or pending_set.has(cc) or inflight_set.has(cc):
				continue
			_pending.append(cc)


func _unload_far(pc: Vector2i) -> void:
	var to_drop: Array = []
	for cc in _chunks.keys():
		var d: int = max(abs(cc.x - pc.x), abs(cc.y - pc.y))
		if d > UNLOAD_RADIUS:
			to_drop.append(cc)
	for cc in to_drop:
		var n: Node = _chunks[cc]
		if n and is_instance_valid(n):
			n.queue_free()
		_chunks.erase(cc)


func _launch_pending() -> void:
	# Sort the pending queue so chunks closest to the player generate
	# first — otherwise the rim of LOAD_RADIUS would compete with the
	# near ring and the player would walk into ungenerated land.
	if _pending.size() > 1:
		var pc := _last_player_chunk
		_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var da: int = max(abs(a.x - pc.x), abs(a.y - pc.y))
			var db: int = max(abs(b.x - pc.x), abs(b.y - pc.y))
			return da < db)
	while _inflight.size() < MAX_INFLIGHT and not _pending.is_empty():
		var cc: Vector2i = _pending.pop_front()
		var task_id: int = WorkerThreadPool.add_task(
				_gen_task.bind(cc), false, "world_chunk_gen")
		_inflight[task_id] = cc


# Runs on a worker thread. Computes the chunk data, parks it in _completed.
func _gen_task(cc: Vector2i) -> void:
	var data: Dictionary = WorldChunkScript.generate_data(cc, WorldGen.world_seed)
	_completed_mtx.lock()
	_completed[cc] = data
	_completed_mtx.unlock()


# Main thread — first drain completed worker tasks into the apply
# queue (cheap), then materialize at most MAX_APPLY_PER_FRAME per
# frame (expensive — that's the actual node construction + foliage
# instantiation).
func _drain_completed() -> void:
	# Move completed task results into _pending_apply.
	var done_tasks: Array = []
	for task_id in _inflight.keys():
		if WorkerThreadPool.is_task_completed(task_id):
			done_tasks.append(task_id)
	for task_id in done_tasks:
		WorkerThreadPool.wait_for_task_completion(task_id)
		var cc: Vector2i = _inflight[task_id]
		_inflight.erase(task_id)
		_completed_mtx.lock()
		var data: Dictionary = _completed.get(cc, {})
		_completed.erase(cc)
		_completed_mtx.unlock()
		if not data.is_empty():
			_pending_apply.append({"cc": cc, "data": data})

	# Apply at most MAX_APPLY_PER_FRAME this frame.
	var applied: int = 0
	while applied < MAX_APPLY_PER_FRAME and not _pending_apply.is_empty():
		var entry: Dictionary = _pending_apply.pop_front()
		var cc: Vector2i = entry["cc"]
		if _chunks.has(cc):
			continue
		var d: int = max(abs(cc.x - _last_player_chunk.x),
				abs(cc.y - _last_player_chunk.y))
		if d > UNLOAD_RADIUS:
			continue
		_create_chunk_from_data(cc, entry["data"])
		applied += 1


func _create_chunk_from_data(cc: Vector2i, data: Dictionary) -> void:
	var chunk: StaticBody3D = StaticBody3D.new()
	chunk.set_script(WorldChunkScript)
	_container.add_child(chunk)
	chunk.apply_data(cc, data)
	_chunks[cc] = chunk
