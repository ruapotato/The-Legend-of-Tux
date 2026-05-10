extends Node

# Autoloaded registry of the four songs from DESIGN.md §4. Each entry:
#
#   {
#     "id":      "<snake_case_id>",   # also the GameState.songs_known key
#     "name":    "Display Name",      # shown in pause-menu Songs tab
#     "glyphs":  ["up", "right", ...] # length-5; matches against picker
#     "summary": "What it does, one line.",
#     "effect":  Callable             # invoked when a known song plays;
#                                     # receives no args, runs in the
#                                     # context of the current scene
#   }
#
# `match_sequence(seq)` returns the song dict for an exact match or {} for
# unknown. `force_learn(id)` is the debug entry point — it's how the
# game grants a song before the NPC pass exists. The NPCs that will
# eventually teach each song are noted in the per-song TODO blocks
# below — they're DESIGN.md §4 verbatim and the NPC pass should wire
# `GameState.learn_song(id)` from inside whatever dialog tree the NPC
# uses (see dialog.gd's "give_item" pattern for the model).

# Glyph identifiers map 1:1 to picker buttons. The center diamond
# ("center") is unused by the four launch songs but is reserved so song
# UIs don't have to special-case a 5-vs-4 button count.
const GLYPH_UP:     String = "up"
const GLYPH_DOWN:   String = "down"
const GLYPH_LEFT:   String = "left"
const GLYPH_RIGHT:  String = "right"
const GLYPH_CENTER: String = "center"

const ALL_GLYPHS: Array[String] = [
    GLYPH_UP, GLYPH_DOWN, GLYPH_LEFT, GLYPH_RIGHT, GLYPH_CENTER,
]

# Pretty arrows for the pause-menu Songs tab + the picker labels.
const GLYPH_GLYPH: Dictionary = {
    GLYPH_UP:     "↑",
    GLYPH_DOWN:   "↓",
    GLYPH_LEFT:   "←",
    GLYPH_RIGHT:  "→",
    GLYPH_CENTER: "◇",
}

# Length each song must be. The picker enforces this on input.
const SONG_LENGTH: int = 5

var songs: Array = []


func _ready() -> void:
    # 1. Glim's Theme — restore HP at owl statues; saves the game.
    # TODO(NPC pass): teach via Glim, in Wyrdkin Glade after Dungeon 1.
    songs.append({
        "id":     "glim_theme",
        "name":   "Glim's Theme",
        "glyphs": [GLYPH_UP, GLYPH_RIGHT, GLYPH_DOWN, GLYPH_LEFT, GLYPH_UP],
        "summary": "Restores HP at owl statues. Saves the game.",
        "effect":  Callable(self, "_play_glim_theme"),
    })
    # 2. Sun Chord — opens sun-marked gates; lights torches.
    # TODO(NPC pass): teach via Striker Imm in The Forge.
    songs.append({
        "id":     "sun_chord",
        "name":   "Sun Chord",
        "glyphs": [GLYPH_RIGHT, GLYPH_UP, GLYPH_RIGHT, GLYPH_UP, GLYPH_LEFT],
        "summary": "Opens sun-marked gates. Lights nearby torches.",
        "effect":  Callable(self, "_play_sun_chord"),
    })
    # 3. Moon Chord — opens moon-marked gates; reveals night-only platforms.
    # TODO(NPC pass): teach via Watcher Velm at Null Door.
    songs.append({
        "id":     "moon_chord",
        "name":   "Moon Chord",
        "glyphs": [GLYPH_LEFT, GLYPH_DOWN, GLYPH_LEFT, GLYPH_DOWN, GLYPH_RIGHT],
        "summary": "Opens moon-marked gates. Reveals night-only platforms.",
        "effect":  Callable(self, "_play_moon_chord"),
    })
    # 4. Triglyph Chord — sets quest_flags.triglyph_assembled.
    # TODO(NPC pass): teach via Lirien at the Old Throne (Crown). Only
    # learnable if all three above are known — gate it in the dialog tree.
    songs.append({
        "id":     "triglyph_chord",
        "name":   "Triglyph Chord",
        "glyphs": [GLYPH_UP, GLYPH_DOWN, GLYPH_UP, GLYPH_LEFT, GLYPH_RIGHT],
        "summary": "Opens the Null Door. The Triglyph is whole.",
        "effect":  Callable(self, "_play_triglyph_chord"),
    })


# ---- Lookup -------------------------------------------------------------

func get_by_id(song_id: String) -> Dictionary:
    for s in songs:
        if String(s.get("id", "")) == song_id:
            return s
    return {}


# Returns the song dict whose glyph sequence equals `seq`, or an empty
# dict for "no melody recognized". Sequence comparison is exact — no
# subset / partial match.
func match_sequence(seq: Array) -> Dictionary:
    if seq.size() != SONG_LENGTH:
        return {}
    for s in songs:
        var g: Array = s.get("glyphs", [])
        if g.size() != seq.size():
            continue
        var ok := true
        for i in g.size():
            if String(g[i]) != String(seq[i]):
                ok = false
                break
        if ok:
            return s
    return {}


# Pretty glyph string for UI. Example: "↑ → ↓ ← ↑".
func format_glyphs(glyphs: Array) -> String:
    var parts: Array = []
    for g in glyphs:
        parts.append(String(GLYPH_GLYPH.get(String(g), "?")))
    return "  ".join(parts)


# ---- Effects ------------------------------------------------------------
#
# Each effect runs when the player successfully plays a song. They
# touch the live scene tree (torches, gates) via the existing
# WorldEvents bus + group lookups; nothing here mutates dungeon JSON.

func _play_glim_theme() -> void:
    # The actual "restore HP" step lives in owl_statue.gd — it watches
    # for Tux standing on a statue *and* having the song known. The
    # playback alone is the "save" half: stamp the slot if we have one.
    if GameState.last_slot >= 0:
        GameState.save_game(GameState.last_slot)


func _play_sun_chord() -> void:
    # Open every sun-marked gate in the world. Per-scene listeners on
    # the WorldEvents bus pick this up; the per-id deduplication inside
    # WorldEvents.activate makes a repeat play a no-op.
    WorldEvents.activate("sun_gate")
    # Light any extinguished torches in the current scene.
    var tree := Engine.get_main_loop() as SceneTree
    if tree == null:
        return
    for node in tree.get_nodes_in_group("torch"):
        if node and node.has_method("_light_up"):
            node.call("_light_up")


func _play_moon_chord() -> void:
    WorldEvents.activate("moon_gate")
    # Reveal night-only platforms. The terrain pass will eventually mark
    # these with the "moon_platform" group; until then this is a no-op
    # but the WorldEvents.activate above already does the heavy lifting
    # for any moon_gate listeners present today.
    var tree := Engine.get_main_loop() as SceneTree
    if tree == null:
        return
    for node in tree.get_nodes_in_group("moon_platform"):
        if node and node.has_method("reveal"):
            node.call("reveal")


func _play_triglyph_chord() -> void:
    GameState.set_flag("triglyph_assembled", true)
    WorldEvents.activate("null_door")


# ---- Debug / progression helpers ---------------------------------------

# Grant a song without going through an NPC. Used by the eventual NPC
# pass (which will wrap this in a dialog tree) and by quick-test
# shortcuts. Returns true if the song was newly learned.
func force_learn(song_id: String) -> bool:
    if get_by_id(song_id).is_empty():
        push_warning("SongBook.force_learn: unknown song %s" % song_id)
        return false
    return GameState.learn_song(song_id)


# Convenience: can the Triglyph Chord be learned right now? The Lirien
# NPC pass should gate its teaching dialog on this.
func can_learn_triglyph() -> bool:
    return GameState.has_song("glim_theme") \
        and GameState.has_song("sun_chord") \
        and GameState.has_song("moon_chord")
