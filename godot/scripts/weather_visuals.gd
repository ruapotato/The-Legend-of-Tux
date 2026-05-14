extends Node

# Weather visual effects autoload. Consumes state from Weather and
# TimeOfDay (read-only) and renders the visible side of the simulation:
#  * Rain streaks (GPUParticles3D, scaled by Weather.intensity())
#  * Snow flakes (GPUParticles3D, fluffier + slower)
#  * Storm fog (lerps WorldEnvironment.fog_density + grey-blue tint)
#  * Night starfield (inverted dome mesh with procedural star shader,
#    alpha-blended above the procedural sky)
#
# The particle systems and the star dome are all parented to a single
# follower node that tracks the player every frame, so they always
# render around the camera regardless of world position.
#
# Architecture adapted from /home/david/hamberg/shared/weather_manager.gd
# (user's own AGPL project) — particle parameters, fog handling, and
# star shader patterns are inspired by it. Implementation rewritten in
# this project's style; we DO NOT duplicate that file's weather state
# machine — that already lives in scripts/weather.gd.

const RAIN_BASE_AMOUNT: int = 1200
const RAIN_PEAK_AMOUNT: int = 5000
const SNOW_BASE_AMOUNT: int = 1200
const SNOW_PEAK_AMOUNT: int = 4500

const RAIN_EMITTER_HEIGHT: float = 20.0
const SNOW_EMITTER_HEIGHT: float = 14.0
const PARTICLE_AABB_HALF: float = 30.0

const STORM_FOG_DENSITY: float = 0.012
const STORM_FOG_COLOR := Color(0.45, 0.50, 0.58)   # grey-blue
const FOG_LERP_RATE: float = 0.6                     # per second

const NIGHT_FADE_RATE: float = 0.8

# --- Footprints ------------------------------------------------------
# Decal-based snow footprints. Spawned roughly every FOOTPRINT_SPACING
# metres of horizontal player travel while the ground is snowy. The
# pool is capped at FOOTPRINT_MAX; oldest decals are recycled.
const FOOTPRINT_MAX: int = 200
const FOOTPRINT_SPACING: float = 0.30          # metres between prints
const FOOTPRINT_LIFETIME: float = 30.0         # seconds before fully faded
const FOOTPRINT_FADE_BEGIN: float = 20.0       # start fade after this long
const FOOTPRINT_SIZE: Vector3 = Vector3(0.45, 1.5, 0.65)   # decal extents
const FOOTPRINT_STRIDE_OFFSET: float = 0.10    # L/R offset of feet from path
const FOOTPRINT_TEX_SIZE: int = 32             # generated texture resolution

var _footprint_root: Node3D
var _footprint_pool: Array[Decal] = []         # all preallocated decals
var _footprint_ages: Array[float] = []         # parallel age in seconds
var _footprint_used: Array[bool] = []          # whether slot is active
var _footprint_next_idx: int = 0               # ring-buffer write cursor
var _footprint_tex: ImageTexture = null
var _last_footprint_pos: Vector3 = Vector3.ZERO
var _have_last_footprint_pos: bool = false
var _left_foot: bool = false

var _follower: Node3D
var _rain: GPUParticles3D
var _snow: GPUParticles3D
var _star_dome: MeshInstance3D
var _star_mat: ShaderMaterial

# Cached scene-level nodes (re-resolved when the current_scene changes).
var _cached_scene: Node = null
var _cached_env: WorldEnvironment = null
var _baseline_fog_enabled: bool = false
var _baseline_fog_density: float = 0.0
var _baseline_fog_color: Color = Color(1, 1, 1)

var _player: Node3D = null

# Smoothed night factor [0..1]; 1 at deep night, 0 in daylight.
var _night_factor: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_nodes()


func _build_nodes() -> void:
	_follower = Node3D.new()
	_follower.name = "WeatherFollower"
	# Keep particles + dome out of any culling AABB issues — top_level
	# means transforms are world-space, easier to track manually.
	_follower.top_level = true
	add_child(_follower)

	_rain = _make_rain_particles()
	_follower.add_child(_rain)

	_snow = _make_snow_particles()
	_follower.add_child(_snow)

	_star_dome = _make_star_dome()
	_follower.add_child(_star_dome)

	_build_footprint_system()


# --- Rain ------------------------------------------------------------

func _make_rain_particles() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Rain"
	p.emitting = false
	p.amount = RAIN_BASE_AMOUNT
	p.lifetime = 1.2
	p.visibility_aabb = AABB(
		Vector3(-PARTICLE_AABB_HALF, -RAIN_EMITTER_HEIGHT - 5.0, -PARTICLE_AABB_HALF),
		Vector3(PARTICLE_AABB_HALF * 2.0, RAIN_EMITTER_HEIGHT + 25.0, PARTICLE_AABB_HALF * 2.0)
	)

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.08, -1.0, 0.04)
	pm.spread = 4.0
	pm.initial_velocity_min = 35.0
	pm.initial_velocity_max = 50.0
	pm.gravity = Vector3(0, -28.0, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(20.0, 2.0, 20.0)
	pm.color = Color(0.82, 0.88, 0.98, 0.8)
	p.process_material = pm

	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.03, 0.55)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.85, 0.9, 1.0, 0.7)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mesh.material = mat
	p.draw_pass_1 = mesh
	return p


# --- Snow ------------------------------------------------------------

func _make_snow_particles() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Snow"
	p.emitting = false
	p.amount = SNOW_BASE_AMOUNT
	p.lifetime = 8.0
	p.preprocess = 5.0                                    # already falling on enter
	p.visibility_aabb = AABB(
		Vector3(-PARTICLE_AABB_HALF, -SNOW_EMITTER_HEIGHT - 30.0, -PARTICLE_AABB_HALF),
		Vector3(PARTICLE_AABB_HALF * 2.0, SNOW_EMITTER_HEIGHT + 40.0, PARTICLE_AABB_HALF * 2.0)
	)

	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 28.0
	pm.initial_velocity_min = 6.0
	pm.initial_velocity_max = 10.0
	pm.gravity = Vector3(0, -7.0, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(26.0, 2.5, 26.0)
	# Pale-blue-white snow. We pipe this through vertex_color_use_as_albedo
	# so the per-particle colour wins over the mesh albedo (which otherwise
	# inherits a warm tint from sun/fog).
	pm.color = Color(0.97, 0.98, 1.0, 1.0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.4
	pm.turbulence_noise_speed_random = 0.4
	pm.turbulence_noise_scale = 2.0
	pm.scale_min = 0.7
	pm.scale_max = 1.5
	p.process_material = pm

	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.11, 0.11)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.95)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# vertex_color_use_as_albedo wires the particle's pm.color into the
	# mesh colour so snow stays soft-white regardless of scene lighting.
	mat.vertex_color_use_as_albedo = true
	# disable_fog stops dusk/storm fog tinting the flakes orange or grey.
	mat.disable_fog = true
	# Don't receive ambient occlusion / receive_shadows; flakes should
	# read as glowing white dots, not lit surfaces.
	mat.disable_receive_shadows = true
	mesh.material = mat
	p.draw_pass_1 = mesh
	return p


# --- Footprints ------------------------------------------------------
#
# Procedural Decal-based snow footprints. The decal texture is two black
# ovals (one toe-pad cluster + one heel) on a transparent background,
# baked once into an ImageTexture. We preallocate FOOTPRINT_MAX decals
# in a pool, parented to a top-level Node3D so they live in world space
# and stay where they were laid even as the player walks away.
#
# Each footprint ages; after FOOTPRINT_FADE_BEGIN seconds we ramp its
# albedo_mix down to 0 over the remaining lifetime, then mark the slot
# free for reuse. We also recycle the oldest slot when at capacity.

func _build_footprint_system() -> void:
	_footprint_root = Node3D.new()
	_footprint_root.name = "FootprintRoot"
	_footprint_root.top_level = true
	add_child(_footprint_root)
	_footprint_tex = _make_footprint_texture()
	_footprint_pool.resize(FOOTPRINT_MAX)
	_footprint_ages.resize(FOOTPRINT_MAX)
	_footprint_used.resize(FOOTPRINT_MAX)
	for i in FOOTPRINT_MAX:
		var d := Decal.new()
		d.size = FOOTPRINT_SIZE
		d.texture_albedo = _footprint_tex
		d.albedo_mix = 0.0
		d.cull_mask = 1
		d.visible = false
		_footprint_root.add_child(d)
		_footprint_pool[i] = d
		_footprint_ages[i] = 0.0
		_footprint_used[i] = false


# Bake a small 32x32 footprint mask into an ImageTexture. Two black
# ovals (heel + toe pad) on transparent background. Pure code, no asset.
func _make_footprint_texture() -> ImageTexture:
	var size: int = FOOTPRINT_TEX_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# Heel oval: centred ~30% down the texture, smaller.
	var heel_cx: float = float(size) * 0.5
	var heel_cy: float = float(size) * 0.30
	var heel_rx: float = float(size) * 0.18
	var heel_ry: float = float(size) * 0.13
	# Toe oval: centred ~70% down, slightly larger.
	var toe_cx: float = float(size) * 0.5
	var toe_cy: float = float(size) * 0.72
	var toe_rx: float = float(size) * 0.22
	var toe_ry: float = float(size) * 0.16
	for y in size:
		for x in size:
			var fx: float = float(x)
			var fy: float = float(y)
			var heel: float = pow((fx - heel_cx) / heel_rx, 2.0) + pow((fy - heel_cy) / heel_ry, 2.0)
			var toe: float = pow((fx - toe_cx) / toe_rx, 2.0) + pow((fy - toe_cy) / toe_ry, 2.0)
			# Soft edge: 1.0 inside, fading to 0 at ellipse boundary.
			var heel_a: float = clamp(1.0 - heel, 0.0, 1.0)
			var toe_a: float = clamp(1.0 - toe, 0.0, 1.0)
			var a: float = maxf(heel_a, toe_a)
			if a > 0.0:
				# Smoothstep gives nicer falloff than linear.
				a = a * a * (3.0 - 2.0 * a)
				img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	return ImageTexture.create_from_image(img)


func _update_footprints(dt: float) -> void:
	# Age existing footprints and fade / retire them.
	for i in FOOTPRINT_MAX:
		if not _footprint_used[i]:
			continue
		_footprint_ages[i] += dt
		var age: float = _footprint_ages[i]
		var d: Decal = _footprint_pool[i]
		if age >= FOOTPRINT_LIFETIME:
			d.visible = false
			d.albedo_mix = 0.0
			_footprint_used[i] = false
			continue
		if age > FOOTPRINT_FADE_BEGIN:
			var fade_t: float = (age - FOOTPRINT_FADE_BEGIN) / max(FOOTPRINT_LIFETIME - FOOTPRINT_FADE_BEGIN, 0.0001)
			d.albedo_mix = clamp(1.0 - fade_t, 0.0, 1.0)

	# Only spawn new prints when it's snowing and we have a player.
	if Weather == null or not Weather.is_snowing():
		_have_last_footprint_pos = false
		return
	if Weather.intensity() < 0.05:
		_have_last_footprint_pos = false
		return
	if _player == null or not is_instance_valid(_player):
		return
	# Require player on ground.
	var on_ground: bool = true
	if _player.has_method("is_on_floor"):
		on_ground = _player.is_on_floor()
	if not on_ground:
		return

	var pos: Vector3 = _player.global_position
	if not _have_last_footprint_pos:
		_last_footprint_pos = pos
		_have_last_footprint_pos = true
		return

	var horiz_delta: Vector3 = Vector3(pos.x - _last_footprint_pos.x, 0.0, pos.z - _last_footprint_pos.z)
	if horiz_delta.length() < FOOTPRINT_SPACING:
		return

	var move_dir: Vector3 = horiz_delta.normalized()
	# Perpendicular in XZ plane for L/R foot stride offset.
	var perp: Vector3 = Vector3(-move_dir.z, 0.0, move_dir.x)
	var sign: float = 1.0 if _left_foot else -1.0
	var foot_pos: Vector3 = pos + perp * (FOOTPRINT_STRIDE_OFFSET * sign)
	_spawn_footprint(foot_pos, move_dir)
	_left_foot = not _left_foot
	_last_footprint_pos = pos


func _spawn_footprint(world_pos: Vector3, forward: Vector3) -> void:
	var idx: int = -1
	# Prefer an unused slot.
	for i in FOOTPRINT_MAX:
		if not _footprint_used[i]:
			idx = i
			break
	# All in use — recycle oldest via ring-buffer cursor.
	if idx < 0:
		idx = _footprint_next_idx
		_footprint_next_idx = (_footprint_next_idx + 1) % FOOTPRINT_MAX
	var d: Decal = _footprint_pool[idx]
	# Place slightly above ground so the decal projects downward onto it.
	# Decals project along -Y by default; raise origin a touch.
	d.global_position = world_pos + Vector3(0.0, 0.05, 0.0)
	# Rotate decal so its "forward" (texture +Y) lines up with movement.
	var yaw: float = atan2(forward.x, forward.z)
	d.rotation = Vector3(0.0, yaw, 0.0)
	d.albedo_mix = 1.0
	d.visible = true
	_footprint_used[idx] = true
	_footprint_ages[idx] = 0.0


# --- Star dome -------------------------------------------------------
#
# A large inverted SphereMesh follows the player; its inside surface is
# rendered with a procedural star shader. The alpha rises only during
# night so daytime sky shows through unobstructed.

const STAR_DOME_RADIUS: float = 800.0

func _make_star_dome() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "StarDome"
	# We want trees and terrain to occlude the dome — same as the
	# procedural sky itself. The shader uses additive blend + depth test
	# ON + depth write OFF, so any opaque geometry already in the depth
	# buffer will mask the stars. render_priority is negative so the
	# dome draws BEFORE any other transparents in the world.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Negative sorting_offset pushes this back in transparent sort, so it
	# lays underneath every other transparent / particle in the scene.
	mi.sorting_offset = -1000.0
	# extra_cull_margin lets the very-large sphere stay in frustum even
	# when its centre is at the player's feet (otherwise Godot may try
	# to cull it when the camera tilts).
	mi.extra_cull_margin = STAR_DOME_RADIUS

	var sphere := SphereMesh.new()
	sphere.radius = STAR_DOME_RADIUS
	sphere.height = STAR_DOME_RADIUS * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	# Flip normals so we see the inside.
	sphere.is_hemisphere = false
	mi.mesh = sphere

	_star_mat = ShaderMaterial.new()
	_star_mat.shader = _build_star_shader()
	_star_mat.set_shader_parameter("night_alpha", 0.0)
	_star_mat.set_shader_parameter("star_density", 0.55)
	_star_mat.render_priority = -128            # draw early in transparent pass
	mi.material_override = _star_mat
	return mi


func _build_star_shader() -> Shader:
	var sh := Shader.new()
	# render_mode notes:
	#  * unshaded         — stars don't receive sun/ambient.
	#  * blend_add        — stars are additive over whatever's behind them
	#                       (the procedural sky background).
	#  * depth_draw_never — we do NOT write into the depth buffer, so
	#                       particles / transparents drawn after us are
	#                       unaffected.
	#  * (no depth_test_disabled) — depth test is ENABLED, so trees and
	#                       terrain that have already drawn into depth
	#                       buffer correctly occlude the stars. THIS is
	#                       what stops the dome rendering on top of trees.
	#  * cull_front       — we sit INSIDE the sphere, so cull front faces
	#                       and render the inside.
	var sh_code := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_front;

uniform float night_alpha : hint_range(0.0, 1.0) = 0.0;
uniform float star_density : hint_range(0.0, 1.0) = 0.55;
uniform vec3  tint : source_color = vec3(0.92, 0.94, 1.0);
uniform vec3  milky_tint : source_color = vec3(0.78, 0.82, 1.0);

float h31(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yxz + 19.19);
	return fract((p.x + p.y) * p.z);
}

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = h21(i);
	float b = h21(i + vec2(1.0, 0.0));
	float c = h21(i + vec2(0.0, 1.0));
	float d = h21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Procedural background star grid: many dim points + a few bright ones
// with cheap atmospheric twinkle. Direction is normalized world-space.
float bg_stars(vec3 d) {
	vec3 p = d * 220.0;
	vec3 cell = floor(p);
	float gate = h31(cell);
	float s = 0.0;
	if (gate > 0.985) {
		vec3 sp = vec3(h31(cell + vec3(1.0, 0.0, 0.0)),
		               h31(cell + vec3(0.0, 1.0, 0.0)),
		               h31(cell + vec3(0.0, 0.0, 1.0)));
		float dist = length(fract(p) - sp);
		float br = 0.3 + 0.7 * h31(cell + vec3(2.0));
		s = smoothstep(0.07, 0.0, dist) * br;
	}
	return s;
}

vec3 bright_stars(vec3 d, float t) {
	vec3 p = d * 80.0;
	vec3 g = floor(p);
	vec3 f = fract(p);
	vec3 total = vec3(0.0);
	for (int x = 0; x <= 1; x++) {
		for (int y = 0; y <= 1; y++) {
			for (int z = 0; z <= 1; z++) {
				vec3 cell = g + vec3(float(x), float(y), float(z));
				float gate = h31(cell);
				if (gate > 1.0 - star_density * 0.18) {
					vec3 sp = vec3(h31(cell + vec3(1.0, 0.0, 0.0)),
					               h31(cell + vec3(0.0, 1.0, 0.0)),
					               h31(cell + vec3(0.0, 0.0, 1.0)));
					vec3 diff = f - sp - vec3(float(x), float(y), float(z));
					float dist = length(diff);
					float base = 0.35 + 0.65 * h31(cell + vec3(2.0));
					// Twinkle: combine two frequencies, gentle amplitude.
					float ph1 = h31(cell + vec3(3.0)) * 6.2831;
					float ph2 = h31(cell + vec3(4.0)) * 6.2831;
					float tw = 0.78 + 0.22 * sin(t * (3.0 + 5.0 * h31(cell + vec3(5.0))) + ph1)
					                 + 0.10 * sin(t * (12.0 + 8.0 * h31(cell + vec3(6.0))) + ph2);
					float core = smoothstep(0.045 + base * 0.04, 0.0, dist);
					float glow = exp(-dist * dist * 220.0) * 0.45 * base;
					// Star colour bin.
					float temp = h31(cell + vec3(7.0));
					vec3 col = vec3(1.0);
					if (temp < 0.2)      col = vec3(1.0, 0.7, 0.55);
					else if (temp < 0.5) col = vec3(1.0, 0.92, 0.82);
					else if (temp < 0.85) col = vec3(1.0);
					else                  col = vec3(0.82, 0.88, 1.0);
					total += (core + glow) * col * base * tw;
				}
			}
		}
	}
	return total;
}

// A faint diagonal milky-way style band gives the night sky depth
// without needing the full hamberg nebula stack.
vec3 milky_band(vec3 d) {
	vec3 axis = normalize(vec3(0.25, 0.55, 0.80));
	float across = abs(dot(d, axis));
	float band = 1.0 - smoothstep(0.0, 0.42, across);
	band = band * band;
	vec2 q = d.xy * 6.0 + d.z * 3.0;
	float grain = noise2(q * 8.0) * noise2(q * 17.0 + 3.1);
	grain = smoothstep(0.18, 0.55, grain);
	float core_dist = 1.0 - dot(d, normalize(vec3(-0.4, 0.5, 0.6)));
	float core = exp(-core_dist * 8.0) * 0.55;
	return milky_tint * (band * grain * 0.35 + core * grain * 0.4);
}

// No custom vertex() — Godot's default transform places the (very large)
// inverted sphere correctly. Using VERTEX in fragment gives us the local
// model-space position, whose direction we treat as the view ray.

void fragment() {
	if (night_alpha <= 0.001) {
		discard;
	}
	vec3 dir = normalize(VERTEX);
	// Only render the upper hemisphere — dome sits around the camera and
	// the horizon below has terrain anyway.
	if (dir.y < -0.05) {
		discard;
	}
	float horizon = smoothstep(-0.05, 0.25, dir.y);
	float bg = bg_stars(dir);
	vec3 bgc = tint * bg;
	vec3 br = bright_stars(dir, TIME);
	vec3 mw = milky_band(dir);
	// Overall brightness budget scaled WAY down — the previous 0.55 still
	// left a noticeable grey wash at night. The sky background does the
	// heavy lifting now; the dome is just sparse stars over it.
	vec3 col = (bgc + br + mw) * horizon * 0.22;
	// Fade with night_alpha so the dome is invisible at midday.
	col *= night_alpha;
	// Hard floor — anything below ~0.02 reads as black anyway and was
	// what painted the upper hemisphere grey. Discard those pixels so
	// they truly contribute nothing in the BLEND_ADD pass.
	if (max(max(col.r, col.g), col.b) < 0.025) {
		discard;
	}
	ALBEDO = col;
	ALPHA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
}
"""
	sh.code = sh_code
	return sh


# --- Tick ------------------------------------------------------------

func _process(dt: float) -> void:
	_follow_player()
	_update_rain()
	_update_snow()
	_update_fog(dt)
	_update_night(dt)
	_update_footprints(dt)


func _follow_player() -> void:
	if _player == null or not is_instance_valid(_player):
		var ps := get_tree().get_nodes_in_group("player") if get_tree() else []
		_player = ps[0] as Node3D if ps.size() > 0 else null
	if _player and is_instance_valid(_player):
		var p: Vector3 = _player.global_position
		_follower.global_position = p
		_rain.global_position = Vector3(p.x, p.y + RAIN_EMITTER_HEIGHT, p.z)
		_snow.global_position = Vector3(p.x, p.y + SNOW_EMITTER_HEIGHT, p.z)
		# Star dome stays centred on the player so it never feels close;
		# the radius is large enough that parallax is imperceptible.
		_star_dome.global_position = p


func _update_rain() -> void:
	if Weather == null:
		return
	var raining: bool = Weather.is_raining()
	var intensity: float = clamp(Weather.intensity(), 0.0, 1.0)
	var want_emit: bool = raining and intensity > 0.05
	if _rain.emitting != want_emit:
		_rain.emitting = want_emit
	if want_emit:
		_rain.amount = int(lerp(float(RAIN_BASE_AMOUNT), float(RAIN_PEAK_AMOUNT), intensity))
		var pm := _rain.process_material as ParticleProcessMaterial
		if pm:
			pm.initial_velocity_min = 32.0 + intensity * 25.0
			pm.initial_velocity_max = 48.0 + intensity * 30.0
			# Bend the rain more in a storm.
			var wind: float = 0.05 + intensity * 0.35
			pm.direction = Vector3(wind, -1.0, wind * 0.45).normalized()


func _update_snow() -> void:
	if Weather == null:
		return
	var snowing: bool = Weather.is_snowing()
	var intensity: float = clamp(Weather.intensity(), 0.0, 1.0)
	var want_emit: bool = snowing and intensity > 0.05
	if _snow.emitting != want_emit:
		_snow.emitting = want_emit
	if want_emit:
		_snow.amount = int(lerp(float(SNOW_BASE_AMOUNT), float(SNOW_PEAK_AMOUNT), intensity))
		var pm := _snow.process_material as ParticleProcessMaterial
		if pm:
			pm.turbulence_noise_strength = 1.2 + intensity * 1.8
			pm.gravity = Vector3(intensity * 2.0, -6.5 - intensity * 2.5, intensity * 1.2)


# --- Fog (storm) -----------------------------------------------------

func _resolve_env() -> void:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == _cached_scene:
		return
	_cached_scene = scene
	_cached_env = null
	if scene == null:
		return
	_cached_env = _find_world_env(scene)
	if _cached_env and _cached_env.environment:
		var e: Environment = _cached_env.environment
		_baseline_fog_enabled = e.fog_enabled
		_baseline_fog_density = e.fog_density
		_baseline_fog_color = e.fog_light_color


func _find_world_env(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root
	for child in root.get_children():
		var hit: WorldEnvironment = _find_world_env(child)
		if hit:
			return hit
	return null


func _update_fog(dt: float) -> void:
	_resolve_env()
	if _cached_env == null or _cached_env.environment == null:
		return
	var env: Environment = _cached_env.environment
	var storming: bool = Weather != null and Weather.is_storming()
	var intensity: float = clamp(Weather.intensity() if Weather else 0.0, 0.0, 1.0)
	# Target = baseline blended toward storm parameters.
	var w: float = (intensity if storming else 0.0)
	var target_density: float = lerp(_baseline_fog_density, STORM_FOG_DENSITY, w)
	var target_color: Color = _baseline_fog_color.lerp(STORM_FOG_COLOR, w)
	var step: float = clamp(dt * FOG_LERP_RATE, 0.0, 1.0)
	env.fog_enabled = _baseline_fog_enabled or w > 0.0
	env.fog_density = lerp(env.fog_density, target_density, step)
	env.fog_light_color = env.fog_light_color.lerp(target_color, step)


# --- Night fade ------------------------------------------------------

func _update_night(dt: float) -> void:
	var target: float = 0.0
	if TimeOfDay:
		# Use the sun energy from TimeOfDay's palette as a continuous
		# proxy for "how dark is it". Sun energy ~0.1 at midnight, ~1.2
		# at noon. Map [0.1, 0.6] → [1, 0].
		var se: float = TimeOfDay.sun_energy()
		target = clamp(1.0 - (se - 0.1) / 0.5, 0.0, 1.0)
	var step: float = clamp(dt * NIGHT_FADE_RATE, 0.0, 1.0)
	_night_factor = lerp(_night_factor, target, step)
	if _star_mat:
		_star_mat.set_shader_parameter("night_alpha", _night_factor)
