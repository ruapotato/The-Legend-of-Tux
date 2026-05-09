extends Node

# Autoloaded music hub. Two AudioStreamPlayer voices:
#
#   _base   — the persistent track for whatever scene we're in.
#   _combat — an optional layer that fades in over the base when an
#             enemy aggros the player ("set_combat(true)") and back out
#             once combat ends.
#
# Crossfades are tween-driven on the bus volume_db. Track ids → resource
# paths live in TRACKS below; if the file is missing, play() just prints
# a warning and clears the voice — the system NEVER hard-faults so a
# brand-new project without OGGs still boots cleanly.
#
# API
#   MusicBank.play("hearthold")           # crossfade to a single track
#   MusicBank.play_layered("plain","boss")# base + combat layer
#   MusicBank.set_combat(true)            # combat layer audible
#   MusicBank.stop()                      # fade out everything

const MUSIC_DIR := "res://assets/music"

# Track id → relative file basename. Resolved lazily inside _load() so
# adding a new id is just one line. Keep these in sync with the dungeon
# level ids (build_dungeon.py emits "music_track" matching the level).
const TRACKS := {
    "sourceplain":    "sourceplain.ogg",
    "hearthold":      "hearthold.ogg",
    "wyrdwood":       "wyrdwood.ogg",
    "wyrdkin_glade":  "wyrdkin_glade.ogg",
    "dungeon_first":  "dungeon_first.ogg",
    "sigilkeep":      "sigilkeep.ogg",
    "stoneroost":     "stoneroost.ogg",
    "mirelake":       "mirelake.ogg",
    "burnt_hollow":   "burnt_hollow.ogg",
    "brookhold":      "brookhold.ogg",
    "boss":           "boss.ogg",
    "combat":         "combat.ogg",
    "title":          "title.ogg",
}

const MIN_DB := -60.0
const FULL_DB := 0.0
const COMBAT_DB := -3.0     # combat layer rests slightly under base when active

var _base: AudioStreamPlayer = null
var _combat: AudioStreamPlayer = null
var _current_track: String = ""
var _current_combat: String = ""
var _combat_active: bool = false


func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _base = AudioStreamPlayer.new()
    _base.name = "Base"
    _base.volume_db = MIN_DB
    _base.bus = "Master"
    add_child(_base)
    _combat = AudioStreamPlayer.new()
    _combat.name = "Combat"
    _combat.volume_db = MIN_DB
    _combat.bus = "Master"
    add_child(_combat)


# ---- public API --------------------------------------------------------

func play(track_id: String, fade_in: float = 0.6) -> void:
    if track_id == _current_track and _base.playing:
        return
    _current_track = track_id
    var stream: AudioStream = _load(track_id)
    _swap_stream(_base, stream, fade_in)
    # Solo mode: fade out any previously running combat layer.
    _current_combat = ""
    _combat_active = false
    _fade_to(_combat, MIN_DB, fade_in)


func stop(fade_out: float = 0.6) -> void:
    _current_track = ""
    _current_combat = ""
    _combat_active = false
    _fade_to(_base, MIN_DB, fade_out)
    _fade_to(_combat, MIN_DB, fade_out)


func play_layered(base_id: String, combat_id: String, fade_in: float = 0.6) -> void:
    if base_id != _current_track or not _base.playing:
        _current_track = base_id
        var base_stream: AudioStream = _load(base_id)
        _swap_stream(_base, base_stream, fade_in)
    if combat_id != _current_combat:
        _current_combat = combat_id
        var combat_stream: AudioStream = _load(combat_id)
        if combat_stream:
            _combat.stream = combat_stream
            _combat.volume_db = MIN_DB
            _combat.play()
        else:
            _combat.stop()
    if not _combat_active:
        _fade_to(_combat, MIN_DB, fade_in)


func set_combat(active: bool, fade: float = 0.5) -> void:
    if active == _combat_active:
        return
    _combat_active = active
    if _combat.stream == null:
        return
    _fade_to(_combat, COMBAT_DB if active else MIN_DB, fade)


# ---- internals ---------------------------------------------------------

func _load(track_id: String) -> AudioStream:
    if not TRACKS.has(track_id):
        if track_id != "":
            push_warning("MusicBank: unknown track id '%s'" % track_id)
        return null
    var path := "%s/%s" % [MUSIC_DIR, TRACKS[track_id]]
    if not ResourceLoader.exists(path):
        push_warning("MusicBank: missing audio file %s (silent)" % path)
        return null
    var s: AudioStream = load(path)
    if s == null:
        push_warning("MusicBank: failed to load %s" % path)
        return null
    # Loop the track if the stream type supports it. OggVorbis/MP3/Wav
    # all expose `loop` differently; we set the most common one and
    # silently move on otherwise.
    if "loop" in s:
        s.loop = true
    return s


func _swap_stream(player: AudioStreamPlayer, stream: AudioStream, fade: float) -> void:
    if stream == null:
        # Nothing to play — fade out whatever was there and stop.
        _fade_to(player, MIN_DB, fade)
        return
    # Crossfade: drop volume, swap stream, ramp back up.
    if player.playing:
        var t1 := create_tween()
        t1.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        t1.tween_property(player, "volume_db", MIN_DB, fade * 0.5)
        t1.tween_callback(func ():
            player.stream = stream
            player.play())
        t1.tween_property(player, "volume_db", FULL_DB, fade * 0.5)
    else:
        player.stream = stream
        player.volume_db = MIN_DB
        player.play()
        var t2 := create_tween()
        t2.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
        t2.tween_property(player, "volume_db", FULL_DB, fade)


func _fade_to(player: AudioStreamPlayer, db: float, dur: float) -> void:
    var t := create_tween()
    t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
    t.tween_property(player, "volume_db", db, max(0.01, dur))
    if db <= MIN_DB + 0.1:
        t.tween_callback(player.stop)
