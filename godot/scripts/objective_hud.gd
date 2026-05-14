extends Label

# Persistent quest-objective hint. Lives as a small Label child of the
# main HUD CanvasLayer (top-right area, beneath the consumable rows).
# Re-evaluates the player's current objective on every GameState
# progression signal so it stays in sync without polling.
#
# Ordering. The objective text is a strict cascade — the FIRST entry
# whose precondition is unmet wins. The cascade is:
#
#   1.  Final-victory state         → "Realm restored. Find what you missed."
#   2.  Triglyph assembled          → "Open the Null Door."
#   3.  All 3 prior songs known     → "Hum the Triglyph Chord at the Crown."
#   4.  Glim's Theme not learned    → "Find Glim in the Glade."
#   5.  Dungeons in canonical order → "Defeat the <boss>." (in <scene>)
#   6.  All 8 dungeons clear, no triglyph yet → suggest the missing chord(s)
#   7.  Fallback                    → "Explore the Wyrdmark."
#
# The dungeon ordering follows DESIGN.md §2 (the eight Dungeons table).
# Boss ids match GameState.bosses_defeated keys (set by boss_arena.gd
# from the dungeon JSON's "boss_id" / boss_scene path).

const COLOR_GOLD := Color(0.98, 0.85, 0.30, 1.0)
const COLOR_DIM := Color(0.55, 0.52, 0.42, 1.0)
const COLOR_DROP := Color(0, 0, 0, 0.75)

# Canonical dungeon order — id → display label. Order matters: this is
# the cascade walked top-to-bottom. The "scene" hint is woven into the
# prompt so the player knows where to go.
const DUNGEON_ORDER: Array = [
    {"boss": "wyrdking",       "name": "the Wyrdking",        "where": "the Hollow"},
    {"boss": "codex_knight",   "name": "the Codex Knight",    "where": "Sigilkeep"},
    {"boss": "gale_roost",     "name": "the Gale Roost",      "where": "Stoneroost"},
    {"boss": "cinder_tomato",  "name": "the Cinder Tomato",   "where": "the Burnt Hollow"},
    {"boss": "forge_wyrm",     "name": "the Forge Wyrm",      "where": "the Forge"},
    {"boss": "backwater_maw",  "name": "the Backwater Maw",   "where": "Mirelake"},
    {"boss": "censor",         "name": "the Censor",          "where": "the Scriptorium"},
    {"boss": "init",           "name": "Init the Sleeper",    "where": "Init's Hollow"},
]

# Songs cascade after dungeons but before the final hum. Maps id →
# display name; mirrors SongBook entries for the three "prior" songs.
const PRIOR_SONGS: Array = [
    {"id": "glim_theme", "name": "Glim's Theme"},
    {"id": "sun_chord",  "name": "the Sun Chord"},
    {"id": "moon_chord", "name": "the Moon Chord"},
]


func _ready() -> void:
    # Style: small, gold, top-right aligned. Drop shadow keeps it
    # legible over bright terrain.
    add_theme_font_size_override("font_size", 14)
    add_theme_color_override("font_color", COLOR_GOLD)
    add_theme_color_override("font_shadow_color", COLOR_DROP)
    add_theme_constant_override("shadow_offset_x", 1)
    add_theme_constant_override("shadow_offset_y", 1)
    horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    vertical_alignment = VERTICAL_ALIGNMENT_TOP
    autowrap_mode = TextServer.AUTOWRAP_OFF
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    text = ""
    # Hook every progression signal — flag_changed is the catch-all
    # but song_learned and boss_defeated also fire on their own paths,
    # so listening narrowly avoids one redundant refresh per event.
    if Engine.has_singleton("GameState") or get_tree().root.has_node("GameState"):
        GameState.flag_changed.connect(_on_state_changed)
        GameState.boss_defeated.connect(_on_boss_defeated)
        GameState.song_learned.connect(_on_song_learned)
        GameState.item_acquired.connect(_on_item_acquired)
    refresh()


func _on_state_changed(_id: String, _value) -> void:
    refresh()


func _on_boss_defeated(_boss_id: String) -> void:
    refresh()


func _on_song_learned(_song_id: String) -> void:
    refresh()


func _on_item_acquired(_item_name: String) -> void:
    refresh()


func refresh() -> void:
    text = "Next: %s" % _compute_objective()


func _compute_objective() -> String:
    # Survival progression cascade — each step gates on a concrete
    # resource or crafted item so the player always knows the next
    # micro-goal. The dungeon arcs from the old game live in the
    # constants above but no longer drive the HUD; they'll come back
    # when bosses are reworked for the survival run.
    var wood: int = _res_count("wood")
    var stone: int = _res_count("stone")
    var has_sword: bool = bool(GameState.inventory.get("sapling_blade", false))
    var has_shield: bool = bool(GameState.inventory.get("bark_round", false))
    var has_hammer: bool = bool(GameState.inventory.get("hammer", false))
    var has_axe: bool = bool(GameState.inventory.get("stone_axe", false))

    if wood < 3 and not has_sword:
        return "Punch a bush — gather %d more wood." % (3 - wood)
    if not has_sword:
        return "Open the inventory (Esc) and craft the Sapling Blade."
    if _res_count("wood") < 4 and not has_shield:
        return "Punch more bushes — gather wood for a shield."
    if not has_shield:
        return "Craft the Bark Round shield from your inventory."
    if not has_axe and stone < 2:
        return "Find rocks — break two for stone."
    if not has_axe:
        return "Craft the Stone Axe so you can fell trees."
    if not has_hammer:
        return "Craft the Builder's Hammer (3 wood + 2 stone) to start a shelter."
    return "Place a shelter with the Builder's Hammer. (More soon.)"


# Safe resource-count read — the autoload may have no resources dict
# during fresh boot or save migration.
func _res_count(id: String) -> int:
    if GameState == null:
        return 0
    if "resources" in GameState and GameState.resources != null:
        return int(GameState.resources.get(id, 0))
    if GameState.has_method("resource_count"):
        return int(GameState.resource_count(id))
    return 0
