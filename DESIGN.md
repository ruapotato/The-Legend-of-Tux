# THE LEGEND OF TUX — GAME DESIGN

> *LORE.md governs world & feel.*
> *FILESYSTEM.md governs structural layout.*
> **DESIGN.md governs what the player DOES — items, bosses, songs, the
> moment-to-moment loop. This is the source of truth for the OoT-shaped
> build-out.**

---

## 1. The macro-loop

The Legend of Tux follows the Ocarina-of-Time shape:
overworld-hub → dungeon → item → new overworld access → dungeon → ...
A **playthrough** is roughly: 3 acts, 8 Dungeons, ~20 hours.

**Act 1 — The Wyrdmark.** Tutorial through Glade/Wyrdwood/Sourceplain.
Player finishes Dungeon 1 (Hollow of the Last Wyrd) and wakes the
Burrows. Receives Lirien's blessing.

**Act 2 — The Filesystem opens.** Sourceplain hub gives access to all
remaining `/`-children. Player tackles Dungeons 2–6 in roughly any
order (some are gated by items from earlier dungeons).

**Act 3 — The Crown and the Door.** Triglyph Chord assembled from
three regional songs. Player ascends to `/` and descends to `/dev/null`.
Final dungeon. Final boss.

---

## 2. The 8 Dungeons

Capital-D Dungeons are the only levels with bosses, dungeon items,
boss keys, mini-bosses, and locked progression. Other directories are
overworld / town / corridor.

| # | Dungeon | FS path | Item awarded | Boss | Key gating item |
|---|---|---|---|---|---|
| 1 | **Hollow of the Last Wyrd** (existing `dungeon_first`) | `/var/cache/wyrdmark/hollow` | **Boomerang** (Glim's Throw) | Wyrdking *(existing)* | none — first dungeon |
| 2 | **Sigilkeep Bow Hall** (existing `sigilkeep`) | `/etc/wyrdmark` | **Recurve Bow** | **Codex Knight** *(NEW)* | Boomerang |
| 3 | **Stoneroost Spire** (existing `stoneroost`) | `/mnt/wyrdmark/stoneroost` | **Hookshot** | **Gale Roost** *(NEW)* | Bow |
| 4 | **Burnt Hollow Crucible** (existing `burnt_hollow`) | `/tmp/burnt` | **Bomb Bag** | **Cinder Tomato** *(NEW)* | Hookshot OR Bow |
| 5 | **The Forge** (new `forge`) | `/dev` | **Striker's Maul** *(NEW)* | **Forge Wyrm** *(NEW — multi-tier hydra)* | Bombs |
| 6 | **Mirelake Sunken Halls** (existing `mirelake`) | `/var/spool/mire` | **Anchor Boots** *(NEW)* | **Backwater Maw** *(NEW)* | Hookshot |
| 7 | **Scriptorium Shadow Vault** (new `scriptorium`) | `/etc` | **Glim Sight** *(NEW — lens)* | **Censor** *(NEW)* | Anchor Boots |
| 8 | **Init's Hollow** (new sub-area off `null_door`) | `/dev/null` | **Glim Mirror** *(NEW — mirror shield)* | **Init the Sleeper** *(NEW — 3-phase final)* | Triglyph Chord + Glim Sight |

**Wake Grub** (`/boot/grub`) is a half-dungeon — single floor, no
boss, but a chest puzzle gives the **Slingshot** here in pre-Dungeon-1
play if the player explored Wake before the Hollow. Optional content.

---

## 3. Item progression

The full Tux toolkit:

| Slot | Item | How obtained |
|---|---|---|
| Sword | **Twigblade → Brightsteel → Glimblade** | start; upgrade in Hearthold smith; upgrade in Wake |
| Shield | **Wood shield → Iron shield → Glim Mirror** | start; bought in Binds; final dungeon |
| B (start) | **Slingshot** | optional Wake Grub or Hearthold gift |
| B | **Boomerang** *(Glim's Throw)* | Dungeon 1 |
| B | **Recurve Bow** | Dungeon 2 |
| B | **Hookshot** | Dungeon 3 |
| B | **Bomb Bag** | Dungeon 4 |
| B | **Striker's Maul** *(hammer — NEW)* | Dungeon 5 — smashes crystal locks, hard rocks, bell-switches |
| Passive | **Anchor Boots** *(iron boots — NEW)* | Dungeon 6 — toggle on, sink + walk underwater |
| B | **Glim Sight** *(lens — NEW)* | Dungeon 7 — reveals invisible figures, fake walls, hidden chests |
| Passive | **Glim Mirror** *(mirror shield — NEW)* | Dungeon 8 — reflects light/spells, blocks last-boss attacks |
| Bottle | **Fairy bottles** | various — already wired |
| Quiver / Bag | upgraded ammo capacity | side-quests; mini-grottoes |

**B-slot rule:** any held item can be assigned to B. Hammer + Hookshot
+ Bow are mutually exclusive (only one is "out" at a time). Anchor
Boots + Glim Mirror are passive toggles, separate slot.

---

## 4. Songs — the Triglyph Chord

Tux carries no instrument. **He hums.** The system mimics OoT's
ocarina: pause → press a sequence of 5 face-button glyphs → if the
melody matches a known song, the effect fires.

Four songs total, learned over the playthrough:

| # | Song | Aspect | Taught by | Glyph sequence | Effect |
|---|---|---|---|---|---|
| 1 | **Glim's Theme** | Tux | Glim, in Wyrdkin Glade after Dungeon 1 | ↑ → ↓ ← ↑ | Restores HP at owl statues. Saves the game. |
| 2 | **Sun Chord** | Khorgaul (warm/strength) | Striker Imm in The Forge | → ↑ → ↑ ← | Opens **sun-marked** gates. Lights extinguished torches. |
| 3 | **Moon Chord** | Lirien (cool/sight) | Watcher Velm at Null Door | ← ↓ ← ↓ → | Opens **moon-marked** gates. Reveals night-only platforms. |
| 4 | **Triglyph Chord** | All three | Lirien at the Old Throne (Crown), only after all 3 above are known | ↑ ↓ ↑ ← → | Opens the Null Door. **Final-dungeon unlock.** |

The melody UI is a 5-step picker driven by the existing pause-menu
input. Songs persist via the new `quest_flags` layer (§7).

---

## 5. Bosses

Every Dungeon has one boss. Each follows the existing
`boss_arena.gd` framework (cylindrical barrier, hp bar, music swap,
heart container drop on death). Each boss is a unique Node3D with a
`died` signal and an `hp` property — no shared base class is needed.

| Dungeon | Boss | Hook |
|---|---|---|
| 1 | **Wyrdking** *(exists)* | sword + dodge |
| 2 | **Codex Knight** | swings a chained quill in arcs; vulnerable when its inkpot is shattered with the Bow |
| 3 | **Gale Roost** | flying; only reachable via the Hookshot — pulls Tux up to its perch |
| 4 | **Cinder Tomato** | rolls around the arena; segmented body — bombs blow off its outer hide layer-by-layer |
| 5 | **Forge Wyrm** | a fork_hydra of tier 0 with 12 HP per head; Striker's Maul one-shots heads |
| 6 | **Backwater Maw** | submerged; Anchor Boots required to walk down to its core |
| 7 | **Censor** | invisible without Glim Sight; throws "censorship blocks" that delete chunks of the floor |
| 8 | **Init the Sleeper** | three phases — child form, true form, awakening form. Glim Mirror reflects its final attack. |

---

## 6. Heart Pieces

Sixteen pieces hidden across the overworld. Four pieces = one Heart
Container. Existing pickup pipeline (`heart_piece_pickup.gd` already
wired) handles the math.

Heart Pieces are placed one-per-directory on the surface, behind a
small environmental puzzle:

- 9 in pure-overworld directories (no dungeon)
- 4 in cul-de-sac sub-corridors (Wake Grub, Old Hold, Optional Yard, Old Plays)
- 3 hidden in dungeon non-critical paths

Each piece's hiding pattern uses an item the player already has by
the time it's reachable — no soft-locks. Specific placement is
authored in the heart-piece distribution pass.

---

## 7. Quest Flags — cross-scene state

`WorldEvents` resets per-scene; that's correct for puzzle switches
inside one dungeon. For **cross-scene** progression we need a parallel
flag layer:

- `GameState.quest_flags: Dictionary` (saved + loaded)
- `GameState.set_flag(id: String, value = true)`
- `GameState.has_flag(id: String) -> bool`
- `GameState.songs_known: Dictionary` — separate set for the four songs
- `GameState.bosses_defeated: Dictionary` — separate set, used by HUD

Flag id convention: `"<topic>_<verb>"` lowercase snake. Examples:
`"glim_theme_learned"`, `"wyrdking_defeated"`, `"lirien_blessing"`,
`"old_hold_visited"`, `"trade_step_3"`.

---

## 8. Per-directory aesthetics

Each of the 36 directories needs visible distinction. Currently the
TerrainMesh exposes per-cell color but the **sky, fog, ambient light,
sun color** are global. Fix: extend `dungeon_root.gd` with four
exports — `sky_color`, `fog_color`, `ambient_color`, `sun_color` —
and apply a `WorldEnvironment` + `DirectionalLight3D` at runtime per
scene.

Palettes (R, G, B as 0–1 floats):

| Region | sky | fog | ambient | sun | mood |
|---|---|---|---|---|---|
| `wyrdkin_glade`, `wyrdwood`, `optional_yard` | (0.6, 0.78, 0.85) | (0.7, 0.85, 0.75) | (0.55, 0.6, 0.5) | (1.0, 0.95, 0.8) | warm-noon forest |
| `sourceplain`, `wyrdmark_gateway` | (0.7, 0.82, 0.9) | (0.85, 0.9, 0.85) | (0.6, 0.62, 0.55) | (1.0, 0.94, 0.78) | wide-sky plain |
| `hearthold`, `brookhold`, `burrows` | (0.65, 0.72, 0.78) | (0.78, 0.75, 0.65) | (0.55, 0.5, 0.45) | (1.0, 0.85, 0.6) | hearth-amber dusk |
| `wake`, `wake_grub` | (0.85, 0.7, 0.55) | (0.9, 0.78, 0.65) | (0.7, 0.6, 0.5) | (1.0, 0.78, 0.5) | sunrise red-gold |
| `crown` | (0.72, 0.78, 0.88) | (0.85, 0.88, 0.92) | (0.65, 0.68, 0.72) | (1.0, 0.98, 0.95) | thin pale altitude |
| `scriptorium`, `sigilkeep` | (0.45, 0.42, 0.48) | (0.5, 0.48, 0.55) | (0.4, 0.4, 0.45) | (0.85, 0.8, 0.75) | dim stone vault |
| `library`, `cache`, `cache_wyrdmark`, `stacks`, `ledger` | (0.5, 0.42, 0.35) | (0.55, 0.48, 0.4) | (0.5, 0.45, 0.4) | (1.0, 0.85, 0.6) | warm lamp library |
| `forge`, `null_door` | (0.18, 0.12, 0.1) | (0.25, 0.15, 0.1) | (0.4, 0.25, 0.2) | (1.0, 0.55, 0.3) | ember and shadow |
| `murk`, `mirelake`, `backwater` | (0.4, 0.55, 0.55) | (0.55, 0.65, 0.6) | (0.4, 0.5, 0.5) | (0.7, 0.85, 0.85) | cold green fog |
| `drift`, `burnt_hollow` | (0.55, 0.45, 0.4) | (0.5, 0.42, 0.38) | (0.5, 0.42, 0.38) | (0.95, 0.7, 0.5) | washed-out scorched |
| `sprawl`, `binds`, `sharers`, `old_plays`, `locals` | (0.6, 0.65, 0.7) | (0.7, 0.72, 0.7) | (0.5, 0.5, 0.5) | (1.0, 0.9, 0.7) | mid-day urban |
| `docks`, `docks_foreign`, `wyrdmark_mounts`, `stoneroost` | (0.55, 0.7, 0.85) | (0.7, 0.8, 0.85) | (0.55, 0.6, 0.65) | (1.0, 0.92, 0.85) | high-wind salt |
| `old_hold` | (0.5, 0.55, 0.6) | (0.65, 0.62, 0.58) | (0.45, 0.45, 0.42) | (0.85, 0.78, 0.7) | overgrown homestead |

---

## 9. Per-directory enemy roster

Each directory's enemy mix matches its tone. Replace the universal
blob/knight/bat spam with these rosters:

| Region | Enemies |
|---|---|
| Forest (`wyrdkin_glade`, `wyrdwood`, `optional_yard`) | tomato, blob, rare knight |
| Plain (`sourceplain`, `wyrdmark_gateway`) | knight, blob, bat at night |
| Village (`hearthold`, `brookhold`, `burrows`) | none — safe zones |
| Wake (`wake`, `wake_grub`) | knight, wisp_hunter |
| Crown (`crown`) | none — atmospheric |
| Library / Records (`library`, `cache`, `cache_wyrdmark`, `stacks`, `ledger`) | init_shade, spore_drifter (subtle, contemplative) |
| Murk (`murk`) | process_ghost, spore_drifter |
| Backwater / Mirelake (`backwater`, `mirelake`) | spore_drifter, bat, blob |
| Forge (`forge`, `null_door`) | fork_hydra, chmod_zealot, knight |
| Scriptorium (`scriptorium`) | chmod_zealot, init_shade, knight |
| Sigilkeep (`sigilkeep`) | knight, chmod_zealot |
| Drift (`drift`, `burnt_hollow`) | tomato, knight, process_ghost |
| Stoneroost / Docks (`stoneroost`, `docks`, `docks_foreign`, `wyrdmark_mounts`) | bat, wisp_hunter |
| Sprawl (`sprawl`, `binds`, `sharers`, `old_plays`, `locals`) | rare knight only — these are urban; minimal combat |
| Old Hold (`old_hold`) | none — sacred ground |
| Hollow of the Last Wyrd (`dungeon_first`) | knight, bat, wisp_hunter, blob |

---

## 10. Build sequence

Authoring order so the doc-driven build doesn't deadlock:

1. **Quest-flags + Songs** (§4 + §7) — unblocks every dungeon's
   "boss defeated" state and the Triglyph chord gate.
2. **New items** (§3) — Striker's Maul, Anchor Boots, Glim Sight,
   Glim Mirror. Each needs scene + script + B-button activation +
   pickup variant.
3. **Per-directory aesthetics** (§8) — palette + light per scene.
4. **New bosses** (§5) — 7 boss scripts + boss arenas wired into
   each Dungeon.
5. **Per-directory enemy roster** (§9) — rewrite enemy lists in the
   36 dungeon JSONs, rebuild scenes.
6. **Heart pieces** (§6) — 16 placements.
7. **Polish pass** — owl statue placement, final boss tuning, intro
   cutscene, save-slot rename.

---

# v2 — THE COMMAND-PIPELINE OVERLAY

> *"Items are commands. Combat is pipelines. Progression is permission bits."*

The v1 item progression in §3 still names the right gameplay verbs.
v2 *re-skins* them: every item displays as a Unix command (or
pipeline), and the gameplay's ground truth is **permission bits on
binaries.** See `LORE.md §v2.3`–`v2.5` for the canon.

## v2.1 Display rename

| §3 item | v2 command (display) | Subtle subtitle |
|---|---|---|
| Sword | **`kill`** | (Twigblade=`kill`, Brightsteel=`kill -TERM`, Glimblade=`kill -9`) |
| Shield | **`chmod 000`** | self-perms denied — incoming attacks fail their permission check |
| Slingshot | **`ping`** | cheap distant tap |
| Boomerang | **`wget`** | fetch + return |
| Bow | **`ps \| grep \| kill`** | 3-stage pipeline; grep step IS the aim reticle |
| Hammer | **`ps \| sort -k pos \| head -5 \| kill -9`** | top 5 nearest force-killed |
| Bombs | **`rm -rf`** | recursive area destroy |
| Hookshot | **`cd <visible-tile>`** | warp to seen tile |
| Anchor Boots | **`chroot /lower`** | confine to deeper layer |
| Glim Sight | **`ls -la`** | reveal dotfiles in cone |
| Glim Mirror | **`chmod 777 . \| tee`** | reflect to source |
| Bottle | **`mktemp -d`** | container |
| Songs | **`crontab`** | scheduled jobs |

## v2.2 Permissions = the character sheet

The Trophy Wall's "bosses defeated" display is replaced with a
literal `ls -l` of the player's permissions (`LORE.md §v2.4`). New
GameState API:

```gdscript
var permissions: Dictionary = {
    "/opt/wyrdmark":  "rwxr-xr-x",
    "/var":           "r-x------",
    "~/bin/grep":     "--x",
    # ...
}
func has_perm(path: String, perm: String) -> bool
func grant_perm(path: String, perm: String) -> void
```

Boss-defeat hooks into `grant_perm` (see LORE.md §v2.4 table for
specific grants).

Doors / chests / NPCs check permissions instead of bare quest_flags.
The "locked" message tells the player exactly which bit they need:
*"chmod denied — needs `r:var/log`."*

## v2.3 Terminal HUD corner

Bottom-left, 4-6 monospace lines, faded background. Flashes the
command Tux just executed. Subtle but constant. Players who don't
read it get the Wyrdmark fantasy uninterrupted; players who do get
a shell session.

## v2.4 Shopkeepers are package managers

NPCs in `/usr/bin` and `/bin` are named tool-spirits — `apt`,
`pacman`, `make`, `tar`, `gcc`. Buying = `apt install <wares>` =
adds `+x` on `/usr/bin/<wares>`. The shopkeeper's name IS the tool
they sell. (Living legendary tools are the shopkeepers; their
descendants are the villagers.)

## v2.5 Build sequence (overlay pass)

1. **Permissions system + Status Screen** — game_state.gd extension,
   pause_menu Trophies → `ls -l` rewrite.
2. **Terminal HUD corner** — new file + hud.gd extension.
3. **Weapon-pipeline display** — when bow fires, show the 3-stage
   pipeline animation; when hammer swings, show the 4-stage.
4. **Door / chest / NPC permission reframe** — semantically
   relabel quest_flags + key_group as permissions; locked-message
   shows the missing bit.
5. **Shop reframe** — rename the four shopkeepers to package-manager
   names (`apt`, `pacman`, `make`, `tar`); their wares display as
   binaries with prices.
6. **Filesystem rooting algorithm** — `tools/grow_filesystem.py`
   (see `FILESYSTEM.md §v3`) to regrow the algorithm-owned
   directories with organic shapes + pillared gaps.

Steps 1-5 can be parallelized after #1 lands. Step 6 is independent.
