extends Node

# Autoload. Owns the world seed and a pure function `height_at(x, z)`
# that any chunk can call to find its surface height at a world
# coordinate. Heights are continuous across chunk boundaries because
# the function is deterministic on world coords — no seam handling.
#
# Phase 1 produces a single starter island centred at (0, 0): a
# radial bias plus two octaves of noise. Phase 3 will add continent
# noise so multiple islands appear at larger radii.

const SEA_LEVEL: float = 0.0

# Starter island geometry. Three stacked noise layers give terrain at
# three scales — big landforms (mountains/valleys), rolling hills, and
# surface roughness. Combined with a gentle radial bias, the center is
# guaranteed land and the edge plunges into the sea.
const CENTER_BIAS_PEAK:  float =  6.0
const CENTER_BIAS_FLOOR: float = -18.0
const CENTER_BIAS_RANGE: float = 2200.0

# Tuned for "Valheim-ish": peaks around +30 m, valleys cut down to sea
# level, beaches naturally show up at the coast.
const MOUNTAIN_AMPLITUDE: float = 22.0    # very-low-freq landforms
const HILLS_AMPLITUDE:    float = 9.0     # rolling hills (~150m wavelength)
const DETAIL_AMPLITUDE:   float = 1.5     # surface bumps

# Continent-scale noise drives the archipelago BEYOND the starter
# island. Where it's positive, an island peaks above sea level; where
# it's negative, ocean. Frequency 1/3000 makes features ~3 km wide on
# average — large enough that crossing one feels meaningful.
const CONTINENT_AMPLITUDE: float = 28.0
const CONTINENT_BIAS:      float = -6.0   # tilt toward ocean so land is the minority
const WORLD_EDGE_INNER:    float = 25000.0
const WORLD_EDGE_OUTER:    float = 30000.0

# Rivers — carve down along the river-noise zero-crossings. We don't
# subtract a depth; we lerp the surface toward RIVER_TARGET_Y so river
# bottoms always end up below sea level (the ocean plane fills the
# channel — they read as water, not as dry canyons).
# Threshold controls width; lower freq spaces rivers farther apart.
const RIVER_THRESHOLD: float = 0.025
const RIVER_TARGET_Y:  float = -1.5      # below SEA_LEVEL so water fills

# Density modulator — drives within-biome foliage variation. Per-position
# noise scaled into [0, MOD_RANGE]. Effective foliage density at any
# spot = biome.density × modulator. Where the noise is high, dense
# thickets; where it's low, open clearings. MAX_DENSITY = densest biome
# × MOD_RANGE — used as the upper bound for candidate count per chunk.
const DENSITY_MOD_RANGE: float = 3.0
const MAX_DENSITY:       float = 0.018   # = max biome density (0.006) × MOD_RANGE

var world_seed: int = 1234567

var _mountain_noise:  FastNoiseLite
var _hills_noise:     FastNoiseLite
var _detail_noise:    FastNoiseLite
var _biome_noise:     FastNoiseLite     # ring-boundary wobble
var _continent_noise: FastNoiseLite     # archipelago shapes beyond center
var _river_noise:     FastNoiseLite     # carving along zero-crossings
var _density_noise:   FastNoiseLite     # within-biome foliage modulator
var _cluster_noise:   FastNoiseLite     # micro-scale clumping of foliage

# Biome ring table — outward from origin. Each ring has a max radius
# (in m), display name, surface color, foliage pool (used in Phase 4),
# and per-chunk foliage density. The wobble noise distorts the radial
# measurement so the boundaries are wavy, not perfect circles.
const BIOME_WOBBLE_AMP: float = 800.0

const BIOME_RINGS: Array = [
	{
		"id": "wyrdwood",   "display": "Wyrdwood",
		"max_r": 4000.0,
		"color": Color(0.40, 0.62, 0.28),
		"foliage": [
			{"scene": "res://scenes/tree_prop.tscn",     "weight": 6.0},
			{"scene": "res://scenes/bush.tscn",          "weight": 3.0},
			{"scene": "res://scenes/rock.tscn",          "weight": 1.0},
			{"scene": "res://scenes/raspberry_bush.tscn", "weight": 1.5},
			{"scene": "res://scenes/mushroom.tscn",       "weight": 0.8},
			# Animals are rare. Combined with the in-script
			# distance-throttle (60 m), total active animal count
			# stays at ~5–15 across the whole streaming ring.
			{"scene": "res://scenes/deer.tscn",           "weight": 0.10},
			{"scene": "res://scenes/sheep.tscn",          "weight": 0.06},
		],
		# base × MOD_RANGE = peak density. Dense thickets approach
		# ~70 trees/chunk, clearings drop to single digits.
		"density": 0.0060,
	},
	{
		"id": "cairnreach", "display": "Cairnreach",
		"max_r": 9000.0,
		"color": Color(0.62, 0.55, 0.40),
		"foliage": [
			{"scene": "res://scenes/rock.tscn",      "weight": 6.0},
			{"scene": "res://scenes/tree_prop.tscn", "weight": 2.0},
			{"scene": "res://scenes/mushroom.tscn",  "weight": 0.2},
			{"scene": "res://scenes/pig.tscn",       "weight": 0.04},
		],
		"density": 0.0020,
	},
	{
		"id": "selkari",    "display": "Selkari Shoals",
		"max_r": 14000.0,
		"color": Color(0.32, 0.50, 0.42),
		"foliage": [
			{"scene": "res://scenes/bush.tscn",          "weight": 5.0},
			{"scene": "res://scenes/rock.tscn",          "weight": 2.0},
			{"scene": "res://scenes/tree_prop.tscn",     "weight": 1.0},
			{"scene": "res://scenes/raspberry_bush.tscn", "weight": 1.0},
			{"scene": "res://scenes/pig.tscn",            "weight": 0.08},
		],
		"density": 0.0030,
	},
	{
		"id": "hollowed",   "display": "Hollowed Warren",
		"max_r": 20000.0,
		"color": Color(0.20, 0.30, 0.18),
		"foliage": [
			{"scene": "res://scenes/tree_prop.tscn", "weight": 7.0},
			{"scene": "res://scenes/rock.tscn",      "weight": 2.0},
			{"scene": "res://scenes/mushroom.tscn",  "weight": 1.5},
			{"scene": "res://scenes/deer.tscn",      "weight": 0.06},
		],
		"density": 0.0060,
	},
	{
		"id": "duneborn",   "display": "Duneborn Sands",
		"max_r": 26000.0,
		"color": Color(0.85, 0.72, 0.42),
		"foliage": [
			{"scene": "res://scenes/rock.tscn", "weight": 1.0},
		],
		"density": 0.0010,
	},
	{
		"id": "ashen",      "display": "Ashen Verge",
		"max_r": 30000.0,
		"color": Color(0.30, 0.18, 0.15),
		"foliage": [
			{"scene": "res://scenes/rock.tscn", "weight": 1.0},
		],
		"density": 0.0008,
	},
]


func _ready() -> void:
	_mountain_noise  = _make_noise(world_seed,     1.0 / 500.0)
	_hills_noise     = _make_noise(world_seed + 1, 1.0 / 150.0)
	_detail_noise    = _make_noise(world_seed + 2, 1.0 / 30.0)
	_biome_noise     = _make_noise(world_seed + 3, 1.0 / 1500.0)
	_continent_noise = _make_noise(world_seed + 4, 1.0 / 3000.0)
	_river_noise     = _make_noise(world_seed + 5, 1.0 / 1400.0)
	_density_noise   = _make_noise(world_seed + 6, 1.0 / 600.0)
	_cluster_noise   = _make_noise(world_seed + 7, 1.0 / 40.0)
	# Pre-load every foliage scene referenced in the biome table. Worker
	# threads call get_scene() from off-main; if the cache is fully
	# populated upfront, they never write — no race condition.
	for biome in BIOME_RINGS:
		for entry in biome.get("foliage", []):
			var path: String = String(entry.get("scene", ""))
			if path != "" and not _scene_cache.has(path):
				_scene_cache[path] = load(path)


func _make_noise(seed_: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed_
	n.frequency = freq
	return n


# Pure function — same (x, z) always yields the same height for a given
# world seed. Called once per chunk vertex; cheap (a few ns).
#
# Composition:
#   • starter_bias  — radial: guarantees land at the centre, fades to ocean.
#   • continent     — large-scale noise: drives the archipelago at distance.
#   • center_weight — 1 at origin, 0 past CENTER_BIAS_RANGE. Blends the
#                     two so the centre is reliable land and the outer
#                     world is continent-driven.
#   • mountain / hills / detail — three octaves of relief on top.
#   • edge_fall     — smoothly tapers everything to a flat -60 m past
#                     the world edge so there's nothing but ocean past
#                     WORLD_EDGE_OUTER (the disc boundary).
func height_at(world_x: float, world_z: float) -> float:
	var r: float = sqrt(world_x * world_x + world_z * world_z)

	# Starter island bias — guaranteed land in the centre.
	var t: float = clamp(r / CENTER_BIAS_RANGE, 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)                    # smoothstep
	var starter_bias: float = lerp(CENTER_BIAS_PEAK, CENTER_BIAS_FLOOR, t)

	# Continent-scale archipelago beyond.
	var continent_raw: float = _continent_noise.get_noise_2d(world_x, world_z)
	var continent: float = continent_raw * CONTINENT_AMPLITUDE + CONTINENT_BIAS

	# Blend: at centre, pure starter_bias; past CENTER_BIAS_RANGE, pure
	# continent. center_weight^2 falls off faster than linear so the
	# starter island stays compact and the archipelago dominates beyond.
	var center_weight: float = clamp(1.0 - r / CENTER_BIAS_RANGE, 0.0, 1.0)
	center_weight = center_weight * center_weight
	var base: float = lerp(continent, starter_bias, center_weight)

	var mountain: float = _mountain_noise.get_noise_2d(world_x, world_z) * MOUNTAIN_AMPLITUDE
	var hills:    float = _hills_noise.get_noise_2d(world_x, world_z) * HILLS_AMPLITUDE
	var detail:   float = _detail_noise.get_noise_2d(world_x, world_z) * DETAIL_AMPLITUDE

	# World-edge taper.
	var edge_fall: float = clamp(1.0 - (r - WORLD_EDGE_INNER)
			/ (WORLD_EDGE_OUTER - WORLD_EDGE_INNER), 0.0, 1.0)
	edge_fall = edge_fall * edge_fall * (3.0 - 2.0 * edge_fall)

	var inland: float = base + mountain + hills + detail

	# Carve rivers along zero-crossings of the river noise. We lerp
	# the surface TOWARD RIVER_TARGET_Y (a fixed depth below sea level)
	# rather than subtracting a depth — that way river bottoms are
	# always submerged regardless of the surrounding terrain height,
	# and the ocean plane fills the channel visually.
	if inland > SEA_LEVEL:
		var river_raw: float = absf(_river_noise.get_noise_2d(world_x, world_z))
		if river_raw < RIVER_THRESHOLD:
			var carve_t: float = 1.0 - river_raw / RIVER_THRESHOLD
			carve_t = carve_t * carve_t * (3.0 - 2.0 * carve_t)
			inland = lerp(inland, RIVER_TARGET_Y, carve_t)

	return lerp(-60.0, inland, edge_fall)


# Per-position foliage density modulator. Combined with the biome's
# base density it produces the local effective density — high → dense
# thickets, low → open clearings. Range [0, MOD_RANGE].
func density_modulator_at(world_x: float, world_z: float) -> float:
	var raw: float = _density_noise.get_noise_2d(world_x, world_z)  # [-1, 1]
	var t: float = (raw + 1.0) * 0.5                                # [0, 1]
	# Slight bias toward sparse — most of the world feels open, the
	# dense pockets feel noticeably dense by contrast.
	t = pow(t, 0.7)
	return t * DENSITY_MOD_RANGE


# Micro-scale (~40 m) clumping factor. Multiplied into the foliage
# density check so trees aggregate in tight patches with empty gaps
# rather than spreading uniformly. Range [0, 1]:
#   noise < -0.3 → 0  (no foliage; gap between clumps)
#   noise > +0.2 → 1  (full density inside clump)
#   smooth transition in between.
func cluster_factor_at(world_x: float, world_z: float) -> float:
	var raw: float = _cluster_noise.get_noise_2d(world_x, world_z)
	return smoothstep(-0.3, 0.2, raw)


# Surface used for placing things on top of the world — clamped at
# sea level so we never place a tree at -8m.
func surface_y(world_x: float, world_z: float) -> float:
	return max(SEA_LEVEL, height_at(world_x, world_z))


# Biome lookup. Distorts the radial measurement with low-frequency
# noise so adjacent biomes meander instead of forming concentric
# circles. Returns the BIOME_RINGS entry; clamps to the outermost
# ring if past the world edge.
func biome_at(world_x: float, world_z: float) -> Dictionary:
	var r: float = sqrt(world_x * world_x + world_z * world_z)
	var wobble: float = _biome_noise.get_noise_2d(world_x, world_z) * BIOME_WOBBLE_AMP
	var eff_r: float = r + wobble
	for biome in BIOME_RINGS:
		if eff_r <= float(biome["max_r"]):
			return biome
	return BIOME_RINGS[BIOME_RINGS.size() - 1]


func biome_color_at(world_x: float, world_z: float) -> Color:
	return biome_at(world_x, world_z)["color"]


func biome_id_at(world_x: float, world_z: float) -> String:
	return String(biome_at(world_x, world_z)["id"])


# Cache of PackedScenes loaded for foliage. Avoids re-load per chunk.
var _scene_cache: Dictionary = {}

func get_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var scn: PackedScene = load(path) as PackedScene
	_scene_cache[path] = scn
	return scn
