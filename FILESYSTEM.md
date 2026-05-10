# THE WYRDMARK FILESYSTEM

> *"Some directories are forests. Others are towers. Most are
> corridors between somewhere and somewhere else."*

This is the **structural map** of the Wyrdmark and the surrounding
Mount. It defines what each directory in the world IS, where it sits
in the filesystem, what other directories it connects to, and which
existing levels (if any) live there.

LORE.md governs **what the player sees and feels.**
FILESYSTEM.md governs **how the world is wired underneath.**

---

## 1. The whole filesystem at a glance

The realm is the entire Mount filesystem. Every directory the player
can stand in is a **level**. Every parent → child traversal is a
**load zone**. Some directories are large content levels; some are
small **passthrough corridors** that exist purely to make the
filesystem feel real. Both kinds matter — the corridors give the
world its **physical scale** of navigation.

Tree (existing-level alias in [brackets]):

```
/                                    The Crown — pale summit
├── boot/                            The Wake — military district
│   └── grub/                        sub-shrine
├── etc/                             The Scriptorium — bureaucratic vault
│   └── wyrdmark/                    [sigilkeep] — local priesthood keep
├── home/                            The Burrows — village commons
│   ├── hearthold/                   [hearthold] — Tux's nearest village
│   └── brookhold/                   [brookhold] — eastern farmstead
├── mnt/                             The Docks — external attachments
│   └── wyrdmark/                    Wyrdmark's outer mounts
│       └── stoneroost/              [stoneroost] — mountain trail
├── opt/                             The Optional Yard — preserves
│   └── wyrdmark/                    The Wyrdmark proper
│       ├── glade/                   [wyrdkin_glade] — Tux's home glade
│       ├── woods/                   [wyrdwood] — the deep forest
│       └── plain/                   [sourceplain] — the great central plain
├── proc/                            The Murk — fog-swamp of process-ghosts
├── tmp/                             The Drift — daily-amnesia city
│   └── burnt/                       [burnt_hollow] — scarred wasteland
├── usr/                             The Sprawl — vast and contested
│   ├── bin/                         The Binds — merchant ward
│   ├── share/                       The Sharers — cultural ward
│   │   └── games/                   The Old Plays — derelict carnival
│   └── local/                       The Locals — frontier settlements
├── var/                             The Library of Past Echoes
│   ├── cache/                       The Cache — fading memories
│   │   └── wyrdmark/
│   │       └── hollow/              [dungeon_first] — Hollow of the Last Wyrd
│   ├── lib/                         The Stacks — what the Library keeps
│   ├── log/                         The Ledger — what was written down
│   └── spool/                       The Backwater — overflowed buffers
│       └── mire/                    [mirelake] — brackish lake
└── dev/                             The Forge — ancient device-spirits
    └── null/                        The Null Door — Init's doorway
```

**38 directories.** 10 are existing levels with full content. 28 are
new. Some new ones become substantial content levels (the kingdoms);
many are small-but-distinct passthrough corridors.

---

## 2. Mounting the existing levels

The 10 existing levels keep their internal layout, scene id, and
load-zone names — only their **public path** in the filesystem
changes. The player sees the new path on the HUD; the engine still
uses `wyrdkin_glade.tscn` etc. as scene ids.

| Existing level | Filesystem path | Hud display name |
|---|---|---|
| `wyrdkin_glade` | `/opt/wyrdmark/glade` | "Wyrdkin Glade — `/opt/wyrdmark/glade`" |
| `wyrdwood` | `/opt/wyrdmark/woods` | "Wyrdwood — `/opt/wyrdmark/woods`" |
| `sourceplain` | `/opt/wyrdmark/plain` | "Sourceplain — `/opt/wyrdmark/plain`" |
| `hearthold` | `/home/hearthold` | "Hearthold — `/home/hearthold`" |
| `brookhold` | `/home/brookhold` | "Brookhold — `/home/brookhold`" |
| `sigilkeep` | `/etc/wyrdmark` | "Sigilkeep — `/etc/wyrdmark`" |
| `dungeon_first` | `/var/cache/wyrdmark/hollow` | "Hollow of the Last Wyrd — `/var/cache/wyrdmark/hollow`" |
| `stoneroost` | `/mnt/wyrdmark/stoneroost` | "Stoneroost — `/mnt/wyrdmark/stoneroost`" |
| `mirelake` | `/var/spool/mire` | "Mirelake — `/var/spool/mire`" |
| `burnt_hollow` | `/tmp/burnt` | "Burnt Hollow — `/tmp/burnt`" |

The HUD shows the **friendly name first, path second**. The path is
visible but quiet — players are never required to read it. Players
who do read it get the navigation feel.

---

## 3. The new directories — what each one IS

For each new directory we author: a **theme**, a **gameplay role**,
its **load-zone neighbours**, and its **scope** (small passthrough
vs. medium hub vs. large kingdom).

Themes draw on The Mount's regional bible (LORE.md §6 explains why
that's safe — players who haven't read The Mount get a coherent
fantasy world; players who have get the Mount references).

### Root and the high ground

#### `/` — **The Crown**
- Theme: pale, wind-blown summit. Snowless because the Wyrdmark has
  no ice biome, but bare and high. Cold.
- Scope: medium. Has one structure on it that doesn't appear on any
  current Wyrdmark map: the **Old Throne**.
- Connections: parent of every top-level. Reachable late game only.
- Mount-canon: nobody lives there. Lirien (the Colonel) has been.
  Annette has been recently. The Old Throne is the original boot
  shrine; if a player reaches it the music swaps to a hush version
  of `title.ogg`.

#### `/boot` — **The Wake**
- Theme: military shrine carved into cliffsides. Sunrise ritual — a
  short morning ceremony with light cues plays once per day-cycle in
  this scene only.
- Scope: medium hub. NPCs: a stiff captain, a young recruit, a
  veteran who does not look at people directly.
- Connections: parent `/`, child `/boot/grub`, sibling load zones at
  `/etc`, `/home`, `/usr`.
- Mount-canon: The Colonel's domain. The Colonel will not be present
  in the player's playthrough; he is implied through the captain's
  evasions.

#### `/boot/grub` — sub-shrine
- Theme: smaller anteroom. A wall of inscriptions naming everything
  the realm boots through every morning.
- Scope: small. Two NPCs and one inscription puzzle (read it for a
  reward).

### The middle and the warm

#### `/etc` — **The Scriptorium**
- Theme: ancient stone bureaucratic vault. Tall shelves, tall robes,
  tall expectations. The Archivist General lives here.
- Scope: medium. NPCs: scribes at desks, the Archivist General, an
  errant rule-breaker the player can sympathise with.
- Connections: parent `/`, children include `wyrdmark/` (the
  player's own Sigilkeep priesthood). Other siblings reachable.
- Easter egg: a posted notice citing **the seventeen laws against
  CHMOD throwbacks**. The player won't know what it means.

#### `/etc/wyrdmark` → **Sigilkeep** (existing)
- The Wyrdkin's own scriptorium subdirectory. Player has been here.

#### `/home` — **The Burrows**
- Theme: warm village commons. Smoke from chimneys. A market.
- Scope: medium hub. NPCs: a mayor-equivalent, a baker, a kid with a
  question, a long-distance walker resting between expeditions.
- Connections: parent `/`, children `hearthold`, `brookhold`, plus a
  *third* home directory called **`/home/wyrdkin`** that is the
  ancestral home of the Sigil-bearer line. Locked at game start;
  opens after Tux receives Lirien's blessing.

#### `/home/hearthold` → **Hearthold** (existing)
#### `/home/brookhold` → **Brookhold** (existing)
#### `/home/wyrdkin` — **The Old Hold**
- Theme: small overgrown homestead. Tux's grandparents lived here.
- Scope: small but emotionally heavy. One sign, one chest with a
  Heart Container, one ghost-NPC the player can briefly speak to.

### Outer attachments

#### `/mnt` — **The Docks**
- Theme: wide windy quayside. External things attach here. Smell of
  salt and ozone. Strange shipping crates with foreign labels.
- Scope: medium. NPCs: a dockmaster, a foreign trader speaking in
  a dialect that takes 3 attempts to understand (plays
  `npc_talk_blip` at a different pitch).
- Connections: parent `/`, child `/mnt/wyrdmark` (which contains the
  player's Stoneroost). Other children: **`/mnt/foreign`** — a small
  scene of a single mounted device-spirit who barely speaks. (Easter
  egg: a MOUNT throwback's bridge.)

#### `/mnt/wyrdmark` — passthrough — "Wyrdmark Mounts"
- Theme: a windy plateau where the Wyrdmark itself is anchored to
  the larger realm. A single bench, a sign, a view of distant
  Stoneroost.
- Scope: small passthrough. One NPC: a homesick Wyrdkin who looks
  out toward the realm and won't go back.

#### `/mnt/wyrdmark/stoneroost` → **Stoneroost** (existing)

#### `/mnt/foreign` — passthrough
- Theme: a single stone shrine where a foreign device-spirit hums.
  No combat. Just texture.
- Scope: tiny.

### The preserve

#### `/opt` — **The Optional Yard**
- Theme: a parkland of preserved old things. Lirien set old gardens
  here that nobody asked her to keep but nobody wanted her to
  remove. Quiet. Civic. Beautifully maintained.
- Scope: medium hub. NPCs: a groundskeeper Lirien-cult, a poet, a
  young Wyrdkin who came here to think.

#### `/opt/wyrdmark` — passthrough
- Theme: the gateway into the Wyrdmark proper. A simple stone arch
  with the realm's name carved across it.
- Scope: small passthrough. Sign: *"Wyrdmark — All who walk here, walk
  in Lirien's breath."*

#### `/opt/wyrdmark/glade` → **Wyrdkin Glade** (existing)
#### `/opt/wyrdmark/woods` → **Wyrdwood** (existing)
#### `/opt/wyrdmark/plain` → **Sourceplain** (existing)

### The fog and the temporary

#### `/proc` — **The Murk**
- Theme: foggy swamp full of process-ghosts. Half-lucid figures wander
  performing tasks they no longer remember the purpose of. Visibility
  10m. Damp. Quiet.
- Scope: medium. Combat-light. Mostly atmospheric.
- Mount-canon: where the orphaned ghosts of the Great Panic live.
- Mechanic: stepping into certain pockets of the swamp causes the
  player to temporarily lose facing (camera disorients). One sign
  here: *"This place is full of veterans."*

#### `/tmp` — **The Drift**
- Theme: a perpetually-cheerful festival town that resets every
  morning. Loud food, music, parties. Saddest place in the world.
- Scope: large hub. NPCs: a boisterous innkeeper, four festival-goers
  in different stages of forgetting yesterday, a quiet old woman
  reading a small book in a corner who remembers everything (this
  is **The Madam**; she is not announced).
- Mount-canon: yes, this is The Drift from the bible.

#### `/tmp/burnt` → **Burnt Hollow** (existing)

### The Sprawl

#### `/usr` — **The Sprawl**
- Theme: vast contested territory. Three factions in cold standoff:
  the Binds (merchants), the Sharers (cultural), the Locals
  (frontier).
- Scope: medium hub. Mostly a junction with three children.
- Connections: parent `/`, children `bin`, `share`, `local`.

#### `/usr/bin` — **The Binds**
- Theme: tight market alleyways, sharp commerce. Stalls, hagglers, a
  guild office.
- Scope: medium. NPCs: a stallkeeper, a guild bureaucrat, a kid with
  an item to trade.

#### `/usr/share` — **The Sharers**
- Theme: open courtyards, plinths, a bell. Cultural quarter — the
  Sharers consider themselves the soul of the Sprawl, which the
  Binds find insufferable.
- Scope: medium. NPCs: a Sharer poet, a Sharer historian, a Bind
  who wandered in to mock and stayed to listen.

#### `/usr/share/games` — **The Old Plays**
- Theme: derelict carnival grounds. Painted boards, faded banners, a
  swing that creaks in the wind. Half the games still work.
- Scope: small. One game (a target-archery side-quest if the player
  has the bow). One sign: *"Things kept here for play."*
- Easter egg: this is the directory the Wyrdmark itself was
  symlinked from in some earlier version of the Mount. A faded sign
  bears the name "Wyrdmark" with an arrow that points to nothing.

#### `/usr/local` — **The Locals**
- Theme: rough frontier town. Wood-and-stone homes, a sheriff,
  suspicion at outsiders.
- Scope: medium. NPCs: a sheriff, a settler family, a refugee from
  the Drift who came here to remember.

### Past echoes

#### `/var` — **The Library of Past Echoes**
- Theme: vast archive. Aisles of shelves, ladders, soft yellow
  lamps. Readers walking with quiet purpose.
- Scope: large hub. NPCs: a Head Reader, a young apprentice trying
  not to read aloud, **Cat** (a wandering NPC if the player has the
  Mount-bridge perception) — see Easter eggs §6 of LORE.md.

#### `/var/cache` — **The Cache**
- Theme: lower archive of fading memories. Dust. Old crates. Shelves
  with empty places where books used to be.
- Scope: medium passthrough with side rooms.

#### `/var/cache/wyrdmark` — passthrough
- Theme: small alcove of the Cache that holds the Wyrdmark's records.
- Scope: tiny passthrough. Sign + one NPC.

#### `/var/cache/wyrdmark/hollow` → **Hollow of the Last Wyrd** (existing)
- The dungeon. The unopenable door (LORE.md §6 Easter egg #1) is here.

#### `/var/lib` — **The Stacks**
- Theme: stable archive — the things the Library is keeping
  permanently. Every shelf labelled. Reverent atmosphere.
- Scope: medium. Combat-free. A puzzle: read three signs in the
  right order to receive a Heart Piece.

#### `/var/log` — **The Ledger**
- Theme: a long room full of running scrolls. The Daemon Court
  technically maintains this; surface Wyrdkin only see scribes
  copying inscriptions.
- Scope: medium. NPCs: a tired scribe, a Daemon Court representative
  in disguise.

#### `/var/spool` — **The Backwater**
- Theme: shallow stream with overflowed buffers. Wet feet. Sluggish.
- Scope: medium passthrough. Connects toward Mirelake.

#### `/var/spool/mire` → **Mirelake** (existing)

### The Forge and the Null

#### `/dev` — **The Forge**
- Theme: industrial. Hot, loud, ancient. Massive device-spirits.
- Scope: large kingdom. **Null** rules here, barely communicating in
  recognisable language. A boss fight is possible here in late game.
- Mount-canon: yes, this is The Forge from the bible.

#### `/dev/null` — **The Null Door**
- Theme: a single black doorway in a stone frame. Standing in front
  of it makes the world feel briefly meaningless. (Quiet, no
  damage; just a 1-second pulse where colour drains slightly.)
- Scope: tiny. Cannot be entered. Init's doorway. Players who try to
  walk through it find themselves walking out of it the way they
  came in.

---

## 4. Connection diagram

Adjacency list (edges are bidirectional unless marked →):

```
/              ↔ /boot, /etc, /home, /mnt, /opt, /proc, /tmp, /usr, /var, /dev
/boot          ↔ /, /boot/grub
/etc           ↔ /, /etc/wyrdmark
/home          ↔ /, /home/hearthold, /home/brookhold, /home/wyrdkin
/mnt           ↔ /, /mnt/wyrdmark, /mnt/foreign
/mnt/wyrdmark  ↔ /mnt, /mnt/wyrdmark/stoneroost
/opt           ↔ /, /opt/wyrdmark
/opt/wyrdmark  ↔ /opt, /opt/wyrdmark/glade, /opt/wyrdmark/woods,
                                /opt/wyrdmark/plain
/proc          ↔ /
/tmp           ↔ /, /tmp/burnt
/usr           ↔ /, /usr/bin, /usr/share, /usr/local
/usr/share     ↔ /usr, /usr/share/games
/var           ↔ /, /var/cache, /var/lib, /var/log, /var/spool
/var/cache     ↔ /var, /var/cache/wyrdmark
/var/cache/wyrdmark ↔ /var/cache, /var/cache/wyrdmark/hollow
/var/spool     ↔ /var, /var/spool/mire
/dev           ↔ /, /dev/null
```

Plus **non-tree shortcuts** (the realm doesn't have to be strictly
hierarchical):

- `/opt/wyrdmark/woods` ↔ `/var/cache/wyrdmark` — a hidden cliff-trail
  from the deep forest to the dungeon's outer cache.
- `/home/hearthold` ↔ `/etc/wyrdmark` — direct path the priesthood
  uses.
- `/usr/share/games` ↔ `/opt/wyrdmark` — the symlink-trail that hints
  the Wyrdmark used to live in the games directory.

These shortcuts are revealed as the player progresses; not all are
visible at game start.

---

## 5. The HUD path display

A small persistent label in the HUD top-left, beneath the heart row:

```
┌──────────────────────────────────────────┐
│  ♥ ♥ ♥ ♥                                  │
│  Wyrdkin Glade                            │
│  /opt/wyrdmark/glade                      │
└──────────────────────────────────────────┘
```

Friendly name in normal weight, path in monospace below in a quieter
colour. Both update on each scene transition. The path is **always
visible**, never required to read.

For Mount-canon players the path tells a story; for everyone else
it's pleasant texture.

---

## 6. Implementation cookie-trail

To execute this:

1. **Build skeleton JSONs** for all 28 new directories. A python
   helper at `tools/scaffold_directory.py` should take a path
   (`/usr/bin`) and a theme name and emit a minimal JSON with a
   default cell pattern, a default spawn, and the right load_zones
   to its tree neighbours.
2. **Wire load zones** so traversing the world matches the FHS. Each
   level's outgoing load zones include all immediate children +
   parent + any non-tree shortcut.
3. **Add path display** to `hud.gd`. Reads scene id and a `fs_path`
   exported on the dungeon root (build script writes it from a
   PATH_MAP it builds from this document).
4. **Author key kingdoms** as full content (Wake, Drift, Sprawl,
   Library, Forge). Passthrough corridors stay minimal — just the
   atmosphere note + 0-1 NPCs.
5. **Seed Easter eggs** per LORE.md §6.
6. **Music**: add region music ids per kingdom: `wake`, `drift`,
   `library`, `forge`, `sprawl`, `crown`, `murk`. AUDIO.md gets
   appended with Suno prompts for these.
7. **Enemy redesign**: refit enemies into the lore (see §7 below).

---

## 7. Enemy lineage

LORE.md says the bosses are Khorgaul's shaped daemons. The standard
enemies should also be threaded into the world rather than feeling
generic. Suggested mapping:

| Existing enemy | Lore lineage |
|---|---|
| **blob** | Source-residue. Where Khorgaul drained, what little remains coalesces and roams. Slow, sad, easily restored. |
| **bone bat** | A scavenger that picked at the bones of what Khorgaul left. Aerial. |
| **bone knight** | A skeleton of a fallen Sigil-bearer reanimated by Khorgaul's shaping. Carries some of their old discipline. |
| **tomato peahat (boss)** | A garden-spirit shaped into a weapon. Already documented. |
| **wyrdking bonelord (boss)** | The ancient Wyrd's bones reshaped into a gate-keeper. Already documented. |
| **spore drifter** | Murk-born. Came up from `/proc`. |
| **wisp hunter** | An aborted Daemon Court process Khorgaul tried to weaponize. |
| **skull spider** | A Reader that tried to "extended-read" something it couldn't process. |
| **(new — `process_ghost`)** | Murk-bound /proc dweller. Wanders, half-lucid, occasionally harmful, occasionally wistful. Dies easily. Drops a small lore-fragment. |
| **(new — `chmod_zealot`)** | A minor Khorgaul-aligned cultist; tries to lock down anything it touches. Will lock chests, doors, and pickups around it temporarily. |
| **(new — `fork_hydra`)** | When struck, splits into two smaller versions of itself for one generation. Three-tier max. |
| **(new — `init_shade`)** | Annette's footprint. Doesn't attack. Drains stamina if touched. Vanishes if the player approaches without rolling. |

(More enemy designs can come; the agent that ports the redesign
should treat this as starting list, not exhaustive.)

---

## 8. Order of operations

When this document is fully realized the world should grow in this
order:

1. **`LORE.md`** — done.
2. **`FILESYSTEM.md`** — this file.
3. **HUD path display** + per-scene `fs_path` export. Quick win;
   makes the upgrade visible immediately.
4. **Skeleton scaffolder** + run it for all 28 new directories.
5. **Re-wire load zones** so the existing 10 levels point at correct
   filesystem neighbours.
6. **Author key kingdoms** in passes (one or two per round, treat as
   real level work).
7. **Enemy redesign + 4 new enemy types** for the new directories.
8. **Easter egg pass** seeding the LORE.md §6 list.
9. **AUDIO.md addendum** for new region music.
10. **Final canonisation pass**: re-read every existing NPC's dialog
    against LORE.md tone do/don'ts and tighten where needed.

---

*The Wyrdmark Filesystem v1*

---

# v2 — THE FULL UNIX SHAPE

> *"Capture the early-Unix and early-Linux filesystem as faithfully
> as game-pacing allows. Reuse what we have. Add what's missing.
> Reshape what doesn't read as a filesystem."*

The v1 tree above sketched the bridge from the existing 10
hand-authored levels into FHS-shaped territory. v2 finishes the
job — adds the directories any reader of a 1993 Slackware install
would expect, and codifies the **shape rules** so the world reads as
a filesystem when you walk it, not just when you stop and read the
HUD path.

## v2.1 The directory tree, complete

Existing paths kept. **Bold** entries are NEW in v2.

```
/                                    The Crown
├── boot/                            The Wake
│   └── grub/                        sub-shrine
├── **bin/**                         The Toolshed
├── **sbin/**                        Sentinel Hall
├── **lib/**                         The Loomhouse
├── **lost+found/**                  Hall of Lost Things
├── **root/**                        Root's Hold
├── **srv/**                         The Servery
├── **sys/**                         The Heartworks
├── etc/                             The Scriptorium
│   ├── wyrdmark/                    [sigilkeep]
│   ├── **init.d/**                  The Initiates
│   └── **passwd/**                  The Names Hall
├── home/                            The Burrows
│   ├── hearthold/                   [hearthold]
│   ├── brookhold/                   [brookhold]
│   ├── wyrdkin/                     [old_hold]
│   ├── **lirien/**                  Lirien's Chamber
│   └── **khorgaul/**                The Khorgaul Roost (ruined)
├── mnt/                             The Docks
│   ├── wyrdmark/                    [wyrdmark_mounts]
│   │   └── stoneroost/              [stoneroost]
│   └── foreign/                     [docks_foreign]
├── opt/                             The Optional Yard
│   └── wyrdmark/                    [wyrdmark_gateway]
│       ├── glade/                   [wyrdkin_glade]
│       ├── woods/                   [wyrdwood]
│       └── plain/                   [sourceplain]
├── proc/                            The Murk
│   ├── **init/**                    The First Process
│   ├── **sys/**                     The Murk Senate
│   └── **42/**                      Process 42
├── tmp/                             The Drift
│   └── burnt/                       [burnt_hollow]
├── usr/                             The Sprawl
│   ├── bin/                         [binds]
│   ├── share/                       [sharers]
│   │   ├── games/                   [old_plays]
│   │   └── **man/**                 The Manuscripts
│   ├── local/                       [locals]
│   ├── **lib/**                     Sprawl Library (paired)
│   ├── **sbin/**                    Sprawl Outpost
│   ├── **src/**                     The Sourcerooms
│   └── **include/**                 Sprawl Index Hall
├── var/                             The Library of Past Echoes
│   ├── cache/                       [cache]
│   │   └── wyrdmark/                [cache_wyrdmark]
│   │       └── hollow/              [dungeon_first]
│   ├── lib/                         [stacks]
│   ├── log/                         [ledger]
│   ├── spool/                       [backwater]
│   │   └── mire/                    [mirelake]
│   ├── **mail/**                    The Postmark
│   ├── **run/**                     The Pulse Room
│   ├── **tmp/**                     The Long Drift
│   └── **games/**                   The Scoreroom
└── dev/                             The Forge
    ├── null/                        [null_door]
    ├── **zero/**                    The Quietness
    ├── **random/**                  The Wild Hum
    ├── **tty/**                     The Speaker's Room
    └── **loop/**                    The Recursion Hall
```

**67 directories total** = 40 existing + **27 new**. The 4 grottoes
(`grotto_glade`, `grotto_burrows`, `grotto_forge`,
`grotto_sourceplain`) remain as cul-de-sacs off their parents.

## v2.2 The 27 new directories — what each one IS

Each entry: theme · scope · parent · 1-line gameplay note.

### Top-level (7)

#### `/bin` — **The Toolshed**
- Theme: a long workshop wall hung with the realm's essential tools.
  Hammers, chisels, looms, kettles. Worn handles. Things that work.
- Scope: medium passthrough hub. **East exit to `/sbin`** (sister
  workshop). No combat.
- NPCs: an old toolwright; a young apprentice arguing about which
  hammer is canonical.
- Easter egg: a row of 27 tool silhouettes painted on the wall — the
  exact roster of `/bin` in 4.4BSD.

#### `/sbin` — **Sentinel Hall**
- Theme: spare stone hall of the realm's caretakers. Tall, austere.
  Quiet but watchful. Lit with steady cool light.
- Scope: medium. Single Sentinel NPC who does not move and does not
  initiate conversation; speaks if asked the right thing.
- Mount-canon: where the realm's automated wardens live.

#### `/lib` — **The Loomhouse**
- Theme: long tapestry-weaving hall. Looms running themselves — a
  shared loom is a shared library. Threads cross between booths.
- Scope: medium. A weaver who explains how everything else borrows
  from here. NPCs: 1 master weaver, 1 borrower returning a thread.
- Easter egg: a tapestry depicting every other room in the realm,
  woven in shared thread.

#### `/lost+found` — **Hall of Lost Things**
- Theme: a small overlit room where things rescued from broken
  storage are catalogued: orphaned scrolls, half-melted candles, a
  lone shoe. Everything labelled with a number that's lost its file.
- Scope: small. A keeper who knows every piece. Talks slowly.
- Reward: bring her three "claim tokens" (small items found in the
  world after fsck-style "you broke a chest"); get a heart piece.

#### `/root` — **Root's Hold**
- Theme: a single small cottage at the highest spur reachable from
  `/`. Plain. Modest. Rugs. A simple desk. **Locked at start** —
  opens once Tux carries the Triglyph Chord.
- Scope: small. One NPC: the **Sysadmin** (older Wyrdkin who tends
  the realm). Gives the player one piece of unique advice tied to
  whichever dungeon they have left.
- Mount-canon: this is The Root in The Mount lore — implied, not
  named.

#### `/srv` — **The Servery**
- Theme: a kitchen-and-pantry that serves the rest of the realm
  whatever it needs. Always cooking. Always feeding visitors.
- Scope: medium hub. NPCs: a head cook, two runners, a customer
  from `/usr/bin` complaining about portion size.
- Mechanic: 5 pebbles → full HP heal. Cheaper than fairies.

#### `/sys` — **The Heartworks**
- Theme: a glassed-in observatory lower than `/proc` — you can see
  the Source's heartbeats here. Each pulse is a kernel-thread.
- Scope: medium. No combat. NPCs: a Heart-Reader keeping count of
  the pulses; she gives the player a song-glyph hint.
- Mount-canon: the inner mirror of The Murk; where The Source is
  exposed to view.

### Under `/etc` (2)

#### `/etc/init.d` — **The Initiates**
- Theme: a candle-lit row of 12 priests-in-training, each
  responsible for starting one process at dawn. Reverent. Never
  silent — someone's always reciting an incantation.
- Scope: small. A novice asks for help with a forgotten recantation.

#### `/etc/passwd` — **The Names Hall**
- Theme: a long stone wall carved with every name in the realm. A
  scribe stands by with an iron stylus, adding new ones.
- Scope: tiny. Sign: *"Every name here was once a stranger.
  Strangers are how the realm grows."*
- Mount-canon: the "world.passwd" doc from The Mount lives here.

### Under `/home` (2)

#### `/home/lirien` — **Lirien's Chamber**
- Theme: a hooded blue-curtained study high in a stone tower. Books
  on stars. A telescope. Empty when Tux first visits — Lirien is at
  the Crown.
- Scope: small. Becomes meaningful late game: a journal entry the
  player can read after Lirien teaches the Triglyph Chord.

#### `/home/khorgaul` — **The Khorgaul Roost** (ruined)
- Theme: a burned-out hilltop hold. Charred furniture. Wind through
  broken stone. Some things are still warm.
- Scope: small. One NPC: a Khorgaul-cultist trying to clean up; he
  doesn't recognise the cult is dead.
- Mount-canon: where Khorgaul stayed before his absence.

### Under `/mnt` (already complete in v1) — none

### Under `/opt` (already complete in v1) — none

### Under `/proc` (3)

#### `/proc/init` — **The First Process**
- Theme: a small earthen mound in the centre of the Murk where the
  first process lives — an ancient Wyrdkin who has been sitting since
  the realm was started. Patient. Speaks in the present tense only.
- Scope: small. NPCs: just him.
- Easter egg: he'll answer one question about any other character in
  the realm with a single-line summary.

#### `/proc/sys` — **The Murk Senate**
- Theme: a roundtable of 7 process-ghosts arguing about kernel
  parameters they no longer remember setting. Never resolves.
- Scope: small. Combat-free. Comedy.

#### `/proc/42` — **Process 42**
- Theme: a single Wyrdkin who is utterly convinced she's the answer
  to something. Cheerful. Wrong.
- Scope: tiny. One sign: *"NOW SCHEDULED. DO NOT KILL."*

### Under `/usr` (4)

#### `/usr/share/man` — **The Manuscripts**
- Theme: a quiet sub-room of the Sharers, full of bound manuscripts
  arranged by section. Each section explains how some other place in
  the realm works.
- Scope: small. Combat-free. **Reading any 3 manuscripts unlocks a
  flagged hint** for that region.

#### `/usr/lib` — **Sprawl Library** (paired)
- Theme: a wing of `/usr/bin` where the merchants share their
  best tools (and their best secrets). Quieter than the market.
- Scope: small. NPCs: a Bind sharing a borrowed tool with a Local.

#### `/usr/sbin` — **Sprawl Outpost**
- Theme: a single guardpost at the edge of the Sprawl. The merchant
  faction's own hired sentinels.
- Scope: small. One Sentinel-NPC.

#### `/usr/src` — **The Sourcerooms**
- Theme: a vast hall of bound scrolls — the source-text for every
  shared loom in `/lib`. Half the scrolls are missing pages.
- Scope: medium. **The dungeon-key item for the final puzzle is
  hidden here**, not in a Dungeon — Mount-canon: this is where the
  realm was first written.

#### `/usr/include` — **Sprawl Index Hall**
- Theme: an alphabetised hall of header-scrolls. Each scroll declares
  the shape of one thing in `/usr`.
- Scope: small. Combat-free. Single NPC: a tired Indexer.

### Under `/var` (4)

#### `/var/mail` — **The Postmark**
- Theme: a small post-station with five named pigeon-cotes (one per
  village). Letters arrive. Letters depart.
- Scope: small. NPCs: a postmaster. **Tux can leave letters**: a
  side-quest where reading a letter at one village affects an NPC
  in another.

#### `/var/run` — **The Pulse Room**
- Theme: a chamber of beating drums — one per currently-living
  process in the realm. A drum stops if its process dies.
- Scope: small. Combat-free. NPCs: 1 drumkeeper.
- Easter egg: defeat a boss; come back; that boss's drum is silent.

#### `/var/tmp` — **The Long Drift**
- Theme: a quieter sister-festival to The Drift. Things here are
  forgotten across more than one day, but eventually still go.
- Scope: small. One festival-goer who's been here a year.

#### `/var/games` — **The Scoreroom**
- Theme: a wall of high-scores from games in The Old Plays.
- Scope: tiny. A keeper who'll add Tux to the wall if he wins
  any game.

### Under `/dev` (4)

#### `/dev/zero` — **The Quietness**
- Theme: a perfectly silent stone room. Even Tux's footsteps don't
  echo. No NPCs. A single chest in the centre.
- Scope: tiny. Chest gives the player **30 pebbles** (a pile of
  zeros). Sign: *"Take what you need. There is always more."*

#### `/dev/random` — **The Wild Hum**
- Theme: a chaotic room where the floor pattern changes every time
  the player enters. Wind from indeterminate directions.
- Scope: small. Combat: a single random-tier `fork_hydra` spawns
  per visit — different tier each time.
- Easter egg: chest contents are randomised per save (heart, fairy,
  pebbles, key — pick at random on first open).

#### `/dev/tty` — **The Speaker's Room**
- Theme: a small round room with a stone podium. Anyone who speaks
  here is heard everywhere in the realm. NPCs occasionally appear,
  speak one line, and leave.
- Scope: small. Combat-free.

#### `/dev/loop` — **The Recursion Hall**
- Theme: a corridor whose far door always brings the player back to
  its near door, no matter how many times they walk through. Until
  they walk it 7 times. Then a third door appears.
- Scope: tiny. Reward: a heart piece.

## v2.3 Shape rules (the compass + child-count system)

The world is a filesystem. **Walking should feel like navigating
one.** Two rules govern level shape and exit placement:

### Compass rule
- **North** (the level's `+Z` edge in scene space, cosmetically the
  top of the player's mini-map) leads to a **child** directory.
- **South** (`-Z` edge) leads to the **parent**.
- **East / West** (`+X` / `-X`) lead to **siblings or shortcuts**.

If you walk south, then south, then south, you eventually reach
`/`. (At least one south-bound exit per non-root level.)

### Child-count rule

| Children | Shape | Notes |
|---|---|---|
| 0 (leaf) | small dead-end room (~5×5 to ~8×8 cells) | one NPC or one chest is the destination |
| 1 | long thin corridor (~6×24 to ~8×40 cells) | the child exit is at the far north end |
| 2 | T-junction (~16×16) or two corridors meeting | one north + one east/west exit |
| 3 | Y or triangle (~20×20 to ~24×24) | three distinct edges |
| 4+ | large hub (~28×28 or bigger) | one exit per child + one south exit; each on a distinct edge |

Exception: **Dungeon-grade levels** (the 8 capital-D Dungeons in
DESIGN.md §2) keep their hand-authored shape regardless of child
count. The compass rule still applies to their load-zones.

### Combined: how it reads

- A long path in the filesystem (`/var/cache/wyrdmark/hollow`) is a
  long walk: corridor, corridor, corridor, dungeon. Each step
  visibly narrower, more enclosed.
- A wide directory (`/`, `/usr`, `/var`) is a hub with multiple
  visible exits at the compass points its children sit on.
- A cul-de-sac directory (`/lost+found`) is a small room you stop
  in, not pass through.

## v2.4 Connection diagram (v2 — adds 27 new edges + handful of shortcuts)

Adjacency list for the v2 expansion (only NEW edges shown — v1
edges still apply):

```
/              ↔ /bin, /sbin, /lib, /lost+found, /root, /srv, /sys
/etc           ↔ /etc/init.d, /etc/passwd
/home          ↔ /home/lirien, /home/khorgaul
/proc          ↔ /proc/init, /proc/sys, /proc/42
/usr           ↔ /usr/lib, /usr/sbin, /usr/src, /usr/include
/usr/share     ↔ /usr/share/man
/var           ↔ /var/mail, /var/run, /var/tmp, /var/games
/dev           ↔ /dev/zero, /dev/random, /dev/tty, /dev/loop
```

**v2 non-tree shortcuts** (revealed mid-game):

- `/sbin` ↔ `/usr/sbin` — sister-rooms; sentinels keep an open path.
- `/lib`  ↔ `/usr/lib`  — the Loomhouse and the Sprawl Library
  share threads.
- `/proc/init` ↔ `/sys` — the First Process can see the
  Heartworks (he's been watching since the start).
- `/var/mail` ↔ `/home/hearthold`, `/home/brookhold`, `/home/wyrdkin`,
  `/home/lirien` — mail loops.
- `/dev/loop` ↔ `/dev/loop` — the seventh traversal opens a third
  door (no other shortcut needed; the loop is its own).

## v2.5 Build sequence (Unix-shape pass)

1. **Scaffold the 27 new directories** — JSON skeletons with the
   shape rule applied (one corridor per single-child, one dead-end
   per leaf, one hub per multi-child).
2. **Reshape existing 40 levels** to match the compass + child-count
   rule. Big content levels keep their hand-authored interior;
   only their **load-zone positions** move to compass-correct edges.
3. **Re-emit `PATH_MAP`** in `tools/build_dungeon.py` to include
   all 67 directories.
4. **Wire load zones** — every new directory connects to its parent
   + its children + any v2.4 shortcut. Run
   `tools/ensure_back_spawns.py` after.
5. **Apply seamless-load-zone visuals** (gap-in-tree-wall + cleared
   path) to all new and reshaped levels. The seamless treatment is
   already coded — this is just propagating it.
6. **Per-directory aesthetic** — extend the palette table in
   DESIGN.md §8 with palettes for the 27 new directories.
7. **Per-directory enemy roster** — extend DESIGN.md §9 with rosters
   for the 27 new directories.
8. **Author NPCs and signs** — populate the 27 new directories with
   the NPCs hinted above. Tone per LORE.md.
9. **Heart-piece + grotto pass** — distribute additional heart pieces
   in the new dirs (target one per ~4 dirs).
10. **Final integration** — full build + boot + load-zone graph
    integrity check. Commit.

---

*The Wyrdmark Filesystem v2 — Unix-shape canonisation*
