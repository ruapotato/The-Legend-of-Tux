extends Node

# Library of named StandardMaterial3D presets the inspector's material
# picker applies via `material_override`. Stateless utility — call
# `get_material(name)` for a fresh material every time so different
# nodes don't share the same instance (and accidentally mutate each
# other when one widget pushes a color).
#
# `kind` strings are stored in the MeshInstance3D's metadata under
# `mat_kind` so a save+load roundtrip can repaint the override on
# scene ready. The inspector's "Reset to default" clears both.

const KINDS := [
	"default", "grass", "stone", "wood", "brick", "dirt",
	"sand", "metal", "ice", "glass", "lava", "water", "path"
]


static func get_material(kind: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 0.85
	match kind:
		"grass":
			m.albedo_color = Color(0.30, 0.50, 0.26, 1)
		"stone":
			m.albedo_color = Color(0.55, 0.55, 0.58, 1)
		"wood":
			m.albedo_color = Color(0.45, 0.30, 0.18, 1)
		"brick":
			m.albedo_color = Color(0.62, 0.30, 0.25, 1)
		"dirt":
			m.albedo_color = Color(0.40, 0.28, 0.18, 1)
		"sand":
			m.albedo_color = Color(0.85, 0.78, 0.55, 1)
		"metal":
			m.albedo_color = Color(0.72, 0.74, 0.78, 1)
			m.metallic = 0.85
			m.roughness = 0.40
		"ice":
			m.albedo_color = Color(0.75, 0.90, 1.00, 0.85)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.10
		"glass":
			m.albedo_color = Color(0.85, 0.95, 1.00, 0.35)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.05
		"lava":
			m.albedo_color = Color(1.00, 0.40, 0.10, 1)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.30, 0.05)
			m.emission_energy_multiplier = 1.2
		"water":
			m.albedo_color = Color(0.20, 0.55, 0.85, 0.70)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.25
		"path":
			m.albedo_color = Color(0.55, 0.40, 0.25, 1)
		_:
			m.albedo_color = Color(0.80, 0.80, 0.80, 1)
	return m


# Terrain per-cell surface kind ids — short enum so the runtime can
# decide footstep / damage / swim behaviour. Order matters: stored in
# PackedByteArray on the terrain patch.
const SURF_GRASS: int  = 0
const SURF_PATH: int   = 1
const SURF_STONE: int  = 2
const SURF_WATER: int  = 3
const SURF_SAND: int   = 4
const SURF_ICE: int    = 5
const SURF_LAVA: int   = 6

const SURFACE_COLORS := {
	SURF_GRASS: Color(0.30, 0.50, 0.26, 1),
	SURF_PATH:  Color(0.55, 0.40, 0.25, 1),
	SURF_STONE: Color(0.55, 0.55, 0.58, 1),
	SURF_WATER: Color(0.20, 0.55, 0.85, 1),
	SURF_SAND:  Color(0.85, 0.78, 0.55, 1),
	SURF_ICE:   Color(0.75, 0.90, 1.00, 1),
	SURF_LAVA:  Color(1.00, 0.45, 0.10, 1),
}

const SURFACE_NAMES := {
	SURF_GRASS: "Grass",
	SURF_PATH:  "Path",
	SURF_STONE: "Stone",
	SURF_WATER: "Water",
	SURF_SAND:  "Sand",
	SURF_ICE:   "Ice",
	SURF_LAVA:  "Lava",
}


static func surface_color(id: int) -> Color:
	return SURFACE_COLORS.get(id, Color(0.6, 0.6, 0.6, 1))


static func surface_name(id: int) -> String:
	return SURFACE_NAMES.get(id, "?")
