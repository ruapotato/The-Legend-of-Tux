extends Node

# Autoloaded singleton for run-global player stats: HP (fish), stamina,
# pebble currency, small keys, owned items, and the B-button slot.
# Per-scene state lives in scenes, not here.

signal hp_changed(current: int, maximum: int)
signal stamina_changed(current: int, maximum: int)
signal pebbles_changed(amount: int)
signal arrows_changed(current: int, maximum: int)
signal seeds_changed(current: int, maximum: int)
signal bombs_changed(current: int, maximum: int)
signal heart_pieces_changed(amount: int)
# Per-dungeon small keys: emitted with the group whose count changed and
# the new count for that group. The HUD listens and re-reads the
# current group's count so the displayed total always matches the
# dungeon Tux is in.
signal keys_changed(group: String, amount: int)
signal item_acquired(item_name: String)
signal active_item_changed(item_name: String)
signal player_died()
# Fairy-bottle revival: emitted whenever the carried-bottle count or
# capacity changes (HUD redraws the readout). `fairy_revive_triggered`
# fires only on the auto-consume path inside damage(): the player would
# have died but a bottle popped instead. The HUD shows a sparkle
# overlay; the death overlay is suppressed for that frame.
signal fairy_bottles_changed(current: int, maximum: int)
signal fairy_revive_triggered()
# Emitted when the visited-scenes set or the unlocked-warps dict changes.
# The world map listens so it can repaint without polling.
signal visited_changed(scene_id: String)
signal warps_changed()

const HP_PER_FISH: int = 4
const MAX_STAMINA: int = 100

var max_fish: int = 3
var hp: int = 12

var stamina: int = MAX_STAMINA
var _stamina_remainder: float = 0.0

var pebbles: int = 0

# Ammo + consumable counts. Capacity tiers can be raised later via
# pickup chests (quiver / seed-bag / bomb-bag upgrades). Heart pieces
# accrue 0..3; on the 4th piece a heart container is granted instead.
var arrows: int = 0
var max_arrows: int = 30
var seeds: int = 0
var max_seeds: int = 30
var bombs: int = 0
var max_bombs: int = 10
var heart_pieces: int = 0    # 0..3, then promotes to a heart container

# Fairy bottles: consumable revives. Auto-pops on lethal damage if the
# player carries at least one — restores HP to full and skips the death
# overlay. Capacity tier (`max_fairy_bottles`) starts at 3; future
# upgrades can raise it. Bottles are refilled at fairy fountains
# (not implemented yet — for now they're only granted by chests/pickups).
var fairy_bottles: int = 0
var max_fairy_bottles: int = 3

# Small keys are per-dungeon (Ocarina-style): keys you find in
# Dungeon A only unlock doors in Dungeon A. `keys_by_group` maps a
# group id (typically the dungeon's `id`, set by dungeon_root.gd on
# scene load) to its remaining key count. `current_key_group` is the
# group all unqualified add/consume calls operate on.
var keys_by_group: Dictionary = {}
var current_key_group: String = ""

# Backward-compat property: code that still reads/writes `GameState.keys`
# transparently operates on the current group's count.
var keys: int:
    get: return get_keys()
    set(v): keys_by_group[current_key_group] = v

# Cross-scene transition state. When a LoadZone fires it sets
# next_spawn_id; the next scene's DungeonRoot reads it on _ready and
# positions Tux at the matching named spawn. Cleared once consumed so
# subsequent loads default to the "default" spawn.
var next_spawn_id: String = ""

# The spawn id the player is currently standing on, written by
# dungeon_root.gd whenever it consumes next_spawn_id. Persisted in
# saves so reloading drops the player back where they were.
var current_spawn_id: String = "default"

# Slot the player is currently bound to (set by the title menu's
# Load/New action). LoadZone autosaves to this slot during scene
# transitions. -1 means "unbound; do not autosave."
var last_slot: int = -1

# Inventory: name → true (owned). Active item is the one bound to the
# B-button (item_use input).
var inventory: Dictionary = {}
var active_b_item: String = ""

# Scene-id → true. dungeon_root.gd writes here on every _ready so the
# world map can colour-code which levels Tux has actually set foot in.
var visited_scenes: Dictionary = {}

# Owl-statue warp registry. Maps warp_id → {name, scene, spawn} so the
# warp menu can list every shrine the player has activated regardless
# of which scene they're standing in. Stored as a dict-of-dicts (rather
# than warp_id→bool plus a separate registry) so save files round-trip
# cleanly without needing a global static lookup.
var unlocked_warps: Dictionary = {}


func reset() -> void:
    max_fish = 3
    hp = max_fish * HP_PER_FISH
    stamina = MAX_STAMINA
    _stamina_remainder = 0.0
    pebbles = 0
    arrows = 0; seeds = 0; bombs = 0; heart_pieces = 0
    fairy_bottles = 0
    keys_by_group.clear()
    inventory.clear()
    active_b_item = ""
    visited_scenes.clear()
    unlocked_warps.clear()
    hp_changed.emit(hp, max_fish * HP_PER_FISH)
    stamina_changed.emit(stamina, MAX_STAMINA)
    pebbles_changed.emit(pebbles)
    arrows_changed.emit(arrows, max_arrows)
    seeds_changed.emit(seeds, max_seeds)
    bombs_changed.emit(bombs, max_bombs)
    heart_pieces_changed.emit(heart_pieces)
    fairy_bottles_changed.emit(fairy_bottles, max_fairy_bottles)
    keys_changed.emit(current_key_group, get_keys())
    active_item_changed.emit(active_b_item)


# ---- Ammo ---------------------------------------------------------------

func add_arrows(n: int) -> void:
    arrows = clamp(arrows + n, 0, max_arrows)
    arrows_changed.emit(arrows, max_arrows)


func use_arrow() -> bool:
    if arrows <= 0: return false
    arrows -= 1
    arrows_changed.emit(arrows, max_arrows)
    return true


func add_seeds(n: int) -> void:
    seeds = clamp(seeds + n, 0, max_seeds)
    seeds_changed.emit(seeds, max_seeds)


func use_seed() -> bool:
    if seeds <= 0: return false
    seeds -= 1
    seeds_changed.emit(seeds, max_seeds)
    return true


func add_bombs(n: int) -> void:
    bombs = clamp(bombs + n, 0, max_bombs)
    bombs_changed.emit(bombs, max_bombs)


func use_bomb() -> bool:
    if bombs <= 0: return false
    bombs -= 1
    bombs_changed.emit(bombs, max_bombs)
    return true


# ---- Heart progression --------------------------------------------------

func add_heart_container() -> void:
    max_fish += 1
    hp = max_fish * HP_PER_FISH
    hp_changed.emit(hp, max_fish * HP_PER_FISH)


func add_heart_piece() -> void:
    heart_pieces += 1
    if heart_pieces >= 4:
        heart_pieces = 0
        add_heart_container()
    heart_pieces_changed.emit(heart_pieces)


# ---- HP -----------------------------------------------------------------

func damage(amount: int) -> void:
    if hp <= 0:
        return
    hp = max(hp - amount, 0)
    hp_changed.emit(hp, max_fish * HP_PER_FISH)
    if hp == 0:
        # Last-chance fairy bottle: if the blow would have killed Tux
        # but he's carrying a bottle, pop it. HP refills, the death
        # overlay is suppressed, and the HUD plays a sparkle burst
        # instead. Otherwise the death signal fires as normal.
        if consume_fairy():
            hp = max_fish * HP_PER_FISH
            hp_changed.emit(hp, max_fish * HP_PER_FISH)
            fairy_revive_triggered.emit()
        else:
            player_died.emit()


func heal(amount: int) -> void:
    hp = min(hp + amount, max_fish * HP_PER_FISH)
    hp_changed.emit(hp, max_fish * HP_PER_FISH)


# ---- Fairy bottles ------------------------------------------------------

func add_fairy(n: int = 1) -> void:
    fairy_bottles = min(fairy_bottles + n, max_fairy_bottles)
    # Sticky inventory marker so the HUD can keep its bottle counter
    # visible even after the player burns their last bottle (you've
    # seen the row, you should keep seeing it at "0 / 3").
    inventory["bottle_seen"] = true
    fairy_bottles_changed.emit(fairy_bottles, max_fairy_bottles)


func consume_fairy() -> bool:
    if fairy_bottles <= 0:
        return false
    fairy_bottles -= 1
    fairy_bottles_changed.emit(fairy_bottles, max_fairy_bottles)
    return true


# ---- Stamina ------------------------------------------------------------

func spend_stamina(amount: int) -> void:
    stamina = max(stamina - amount, 0)
    stamina_changed.emit(stamina, MAX_STAMINA)


# Per-tick regen. `rate_per_sec` may be 0 (e.g. while blocking).
func regen_stamina(rate_per_sec: float, delta: float) -> void:
    if stamina >= MAX_STAMINA or rate_per_sec <= 0.0:
        _stamina_remainder = 0.0
        return
    _stamina_remainder += rate_per_sec * delta
    var whole := int(_stamina_remainder)
    if whole > 0:
        _stamina_remainder -= whole
        stamina = min(stamina + whole, MAX_STAMINA)
        stamina_changed.emit(stamina, MAX_STAMINA)


# ---- Currency -----------------------------------------------------------

func add_pebbles(amount: int) -> void:
    pebbles += amount
    pebbles_changed.emit(pebbles)
    SoundBank.play_2d("pebble_get")


# ---- Keys ---------------------------------------------------------------
#
# Keys are partitioned by group so a dungeon's keys can't be carried
# into another dungeon. Pass `group = ""` to mean "the current group"
# (set by dungeon_root.gd via set_key_group).

func set_key_group(group: String) -> void:
    if group == current_key_group:
        return
    current_key_group = group
    # Re-emit so listeners (HUD) can refresh to the new dungeon's count.
    keys_changed.emit(current_key_group, get_keys())


func _resolve_group(group: String) -> String:
    return current_key_group if group == "" else group


func get_keys(group: String = "") -> int:
    var g := _resolve_group(group)
    return int(keys_by_group.get(g, 0))


func add_key(group: String = "") -> void:
    var g := _resolve_group(group)
    var n := int(keys_by_group.get(g, 0)) + 1
    keys_by_group[g] = n
    keys_changed.emit(g, n)


func consume_key(group: String = "") -> bool:
    var g := _resolve_group(group)
    var n := int(keys_by_group.get(g, 0))
    if n <= 0:
        return false
    n -= 1
    keys_by_group[g] = n
    keys_changed.emit(g, n)
    return true


# ---- Inventory ----------------------------------------------------------

func acquire_item(item_name: String) -> void:
    if inventory.get(item_name, false):
        return
    inventory[item_name] = true
    item_acquired.emit(item_name)
    # Auto-equip the first item Tux ever picks up so the player has
    # something on the B-button without an inventory menu yet.
    if active_b_item == "":
        active_b_item = item_name
        active_item_changed.emit(active_b_item)


func has_item(item_name: String) -> bool:
    return inventory.get(item_name, false)


func set_active_b_item(item_name: String) -> void:
    if item_name != "" and not has_item(item_name):
        return
    active_b_item = item_name
    active_item_changed.emit(active_b_item)


# ---- Visited scenes / warps --------------------------------------------

func mark_visited(scene_id: String) -> void:
    if scene_id == "":
        return
    if visited_scenes.get(scene_id, false):
        return
    visited_scenes[scene_id] = true
    visited_changed.emit(scene_id)


func is_visited(scene_id: String) -> bool:
    return bool(visited_scenes.get(scene_id, false))


# Owl statues call this when activated. `info` is {name, scene, spawn};
# stored under warp_id so the warp menu and world-map UI can rebuild the
# button list from one dict.
func unlock_warp(warp_id: String, info: Dictionary = {}) -> void:
    if warp_id == "":
        return
    var existing: Variant = unlocked_warps.get(warp_id, null)
    if typeof(existing) == TYPE_DICTIONARY and info.is_empty():
        return
    var entry: Dictionary = {}
    if typeof(existing) == TYPE_DICTIONARY:
        entry = (existing as Dictionary).duplicate(true)
    for k in info.keys():
        entry[k] = info[k]
    unlocked_warps[warp_id] = entry
    warps_changed.emit()


func is_warp_unlocked(warp_id: String) -> bool:
    var v: Variant = unlocked_warps.get(warp_id, null)
    return v != null


func get_unlocked_warps() -> Array:
    # Returns an array of {id, name, scene, spawn} dicts, in insertion
    # order — matches the order owls were activated, which is also a
    # rough proxy for "first visited" ordering.
    var out: Array = []
    for warp_id in unlocked_warps.keys():
        var info: Variant = unlocked_warps[warp_id]
        if typeof(info) != TYPE_DICTIONARY:
            continue
        var d: Dictionary = info as Dictionary
        out.append({
            "id":    String(warp_id),
            "name":  String(d.get("name",  warp_id)),
            "scene": String(d.get("scene", "")),
            "spawn": String(d.get("spawn", "default")),
        })
    return out


# ---- Save / Load --------------------------------------------------------

# Save files live at user://save_<slot>.json (slot 0..2). The schema is
# a flat JSON dict; bumping SAVE_VERSION lets future loaders migrate.

const SAVE_VERSION: int = 1


func _save_path(slot: int) -> String:
    return "user://save_%d.json" % slot


func _current_scene_id() -> String:
    var scene := get_tree().current_scene
    if scene == null:
        return ""
    var p: String = scene.scene_file_path
    if p.begins_with("res://scenes/"):
        p = p.substr("res://scenes/".length())
    if p.ends_with(".tscn"):
        p = p.substr(0, p.length() - ".tscn".length())
    return p


func save_game(slot: int) -> bool:
    if slot < 0 or slot > 2:
        return false
    var data: Dictionary = {
        "version": SAVE_VERSION,
        "hp": hp,
        "max_fish": max_fish,
        "stamina": stamina,
        "pebbles": pebbles,
        "keys_by_group": keys_by_group.duplicate(true),
        "current_key_group": current_key_group,
        "inventory": inventory.duplicate(true),
        "active_b_item": active_b_item,
        "current_scene_id": _current_scene_id(),
        "current_spawn_id": current_spawn_id,
        "visited_scenes":   visited_scenes.duplicate(true),
        "unlocked_warps":   unlocked_warps.duplicate(true),
        "fairy_bottles":     fairy_bottles,
        "max_fairy_bottles": max_fairy_bottles,
    }
    var f := FileAccess.open(_save_path(slot), FileAccess.WRITE)
    if f == null:
        push_warning("save_game: cannot open %s for write" % _save_path(slot))
        return false
    f.store_string(JSON.stringify(data, "  "))
    f.close()
    return true


func _read_save(slot: int) -> Dictionary:
    var path := _save_path(slot)
    if not FileAccess.file_exists(path):
        return {}
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return {}
    var raw := f.get_as_text()
    f.close()
    var parsed: Variant = JSON.parse_string(raw)
    if typeof(parsed) != TYPE_DICTIONARY:
        return {}
    return parsed


func load_game(slot: int) -> bool:
    var data := _read_save(slot)
    if data.is_empty():
        return false
    max_fish = int(data.get("max_fish", 3))
    hp = int(data.get("hp", max_fish * HP_PER_FISH))
    stamina = int(data.get("stamina", MAX_STAMINA))
    _stamina_remainder = 0.0
    pebbles = int(data.get("pebbles", 0))
    # Migrate legacy saves that stored a single `keys` int into the
    # current group bucket; new saves use keys_by_group directly.
    var saved_groups: Variant = data.get("keys_by_group", null)
    if typeof(saved_groups) == TYPE_DICTIONARY:
        keys_by_group = (saved_groups as Dictionary).duplicate(true)
    else:
        keys_by_group = {}
    current_key_group = String(data.get("current_key_group", ""))
    if saved_groups == null and data.has("keys"):
        keys_by_group[current_key_group] = int(data.get("keys", 0))
    inventory = (data.get("inventory", {}) as Dictionary).duplicate(true)
    active_b_item = String(data.get("active_b_item", ""))
    current_spawn_id = String(data.get("current_spawn_id", "default"))
    fairy_bottles     = int(data.get("fairy_bottles",     0))
    max_fairy_bottles = int(data.get("max_fairy_bottles", 3))
    last_slot = slot

    var saved_visited: Variant = data.get("visited_scenes", null)
    if typeof(saved_visited) == TYPE_DICTIONARY:
        visited_scenes = (saved_visited as Dictionary).duplicate(true)
    else:
        visited_scenes = {}
    var saved_warps: Variant = data.get("unlocked_warps", null)
    if typeof(saved_warps) == TYPE_DICTIONARY:
        unlocked_warps = (saved_warps as Dictionary).duplicate(true)
    else:
        unlocked_warps = {}
    warps_changed.emit()

    hp_changed.emit(hp, max_fish * HP_PER_FISH)
    stamina_changed.emit(stamina, MAX_STAMINA)
    pebbles_changed.emit(pebbles)
    keys_changed.emit(current_key_group, get_keys())
    active_item_changed.emit(active_b_item)
    fairy_bottles_changed.emit(fairy_bottles, max_fairy_bottles)

    var scene_id := String(data.get("current_scene_id", "wyrdkin_glade"))
    next_spawn_id = current_spawn_id
    var scene_path := "res://scenes/%s.tscn" % scene_id
    var err := get_tree().change_scene_to_file(scene_path)
    return err == OK


func delete_save(slot: int) -> void:
    var path := _save_path(slot)
    if FileAccess.file_exists(path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
        # Fallback: some platforms prefer the user:// path directly.
        if FileAccess.file_exists(path):
            var d := DirAccess.open("user://")
            if d:
                d.remove("save_%d.json" % slot)


func save_summary(slot: int) -> Dictionary:
    var data := _read_save(slot)
    if data.is_empty():
        return {"exists": false}
    return {
        "exists": true,
        "scene": String(data.get("current_scene_id", "?")),
        "pebbles": int(data.get("pebbles", 0)),
        "hp": int(data.get("hp", 0)),
        "max_hp": int(data.get("max_fish", 3)) * HP_PER_FISH,
    }
