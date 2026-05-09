# Audio assets — drop files here and I'll wire them in

Two folders to fill:

- **Music**: `.ogg` files → eventually `godot/assets/music/` (the
  folder doesn't exist yet — I'll create it when files arrive).
- **Sound effects**: `.wav` files → `godot/assets/sounds/`.

Filenames must match the `name` column **exactly** — that's the key
the engine looks up. I'll move them from `TODO/` to the right folders
when you drop them in.

For Suno, all music prompts below are written in Suno's "describe a
song" style: genre + mood + instrumentation + tempo + structure.
Each track wants a clean **loop point** if Suno will let you mark one;
otherwise pick takes that fade in / out gracefully and I'll set
loop=true on the AudioStream.

Suno is great for the **music**; it's mediocre for short sound
effects. For the SFX list further down, I'd recommend ElevenLabs
Sound Effects, jsfxr, or freesound.org — but Suno works in a pinch
if you describe each as a "very short atmospheric snippet". I've
written the SFX prompts in tool-agnostic prose.

---

## MUSIC (13 tracks) — drop into `TODO/music/`

All ~2-4 minutes, looping. 80-110 BPM unless noted. Aim for a clean
last 4 seconds so the loop point is invisible.

| name | mood | Suno prompt |
|---|---|---|
| `title.ogg` | grand, hopeful, nostalgic | "Cinematic orchestral overture, 90 BPM, soaring strings opening into a hopeful french horn melody, harp arpeggios, light timpani, builds to a triumphant brass climax then settles into a quiet harp outro. 2:30 instrumental, fantasy adventure title theme." |
| `sourceplain.ogg` | sweeping, exploratory | "Pastoral fantasy adventure music, 100 BPM, lively flute and pizzicato strings carrying a memorable pentatonic melody, harp accompaniment, light snare for forward motion, occasional choral 'oo' pads, evokes vast green plains under a warm sun. 3:00 instrumental loop, joyful and questing." |
| `wyrdkin_glade.ogg` | gentle, sleepy, safe | "Quiet woodland lullaby, 70 BPM, solo nylon-string guitar with celesta sparkles and a soft pan-flute counter-melody, distant wind chimes, pastoral and intimate. 2:30 instrumental, peaceful starting-village feel." |
| `wyrdwood.ogg` | mysterious, watchful | "Ambient forest piece in a minor mode, 75 BPM, sparse fingerpicked harp and a mournful low flute, wooden-block percussion, occasional dissonant string swells, owls and breath in the air. 3:00 instrumental, lost-woods mystery." |
| `hearthold.ogg` | warm village bustle | "Renaissance-village folk tune, 110 BPM, recorder + lute + tambourine + light hand-drum, cheerful pentatonic melody with call-and-response between two voices, market-day energy. 2:30 instrumental loop, peaceful town." |
| `brookhold.ogg` | rustic, cozy farmstead | "Pastoral folk waltz, 90 BPM in 6/8, fiddle leading a sweet melody, accordion harmonies, brushed snare, gentle dulcimer, evokes a cozy farm at golden hour. 2:30 instrumental loop, warm and homey." |
| `sigilkeep.ogg` | solemn, sacred, ancient | "Sacred ambient piece, 60 BPM, sustained low organ pads, choral 'aah' voices, single tolling bell every 16 beats, harp arpeggios floating above. 3:00 instrumental, the feel of standing inside an ancient cathedral. Quiet and reverent." |
| `dungeon_first.ogg` | tense, claustrophobic | "Dark dungeon ambience, 70 BPM, low drone synths, bowed bass strings, occasional metallic clinks and dripping water, sparse off-beat tom hits, no melody just texture. 3:00 instrumental, oppressive and watchful, room tones for an ancient hollow." |
| `stoneroost.ogg` | windswept, lonely vista | "Mountain trail ambient, 80 BPM, pan flute melody (ney/quena style) over sustained string drones, occasional male choir 'oh', wooden flute trills, wind in the air. 3:00 instrumental, lonely highland feel." |
| `mirelake.ogg` | murky, watery, unsettled | "Wetland ambient, 65 BPM, slow harp arpeggios over reverb-soaked bass clarinet, distant frog and cricket textures, occasional swampy bass pluck, single woody log-drum hits. 3:00 instrumental, brackish and slightly mysterious." |
| `burnt_hollow.ogg` | scorched, hostile, ember-warm | "Dark fantasy desolation theme, 85 BPM, distorted hurdy-gurdy drone, low brass swells, ash-and-ember percussion (slow gong, bowed cymbal), no melody just slow tension that occasionally flares with a brief minor-mode horn motif. 3:00 instrumental, scarred wasteland." |
| `boss.ogg` | urgent, dramatic | "Cinematic boss-battle music, 130 BPM, driving timpani + low brass ostinato, frantic strings, choral 'fff' shouts on the off-beat, dissonant horn calls, builds tension throughout, with a brief intro 'sting' (4 bars) before the loop body. 2:30 instrumental, fantasy boss fight." |
| `combat.ogg` | rising tension overlay | "Combat tension layer, 100 BPM, percussive only — driving low toms, off-beat hi-hat clicks, occasional bass pulse, NO melodic content. Designed to layer ON TOP of any region track to add urgency when enemies are aggro'd. 2:30 instrumental loop." |

---

## SOUND EFFECTS — drop into `TODO/sfx/`

All `.wav`, mono, 44.1 kHz, ≤ 1.5 s unless noted. Punchy, no long
tail. Fade out the last few ms cleanly.

### Already shipped (do not regenerate — they're in `godot/assets/sounds/`)

`jump`, `land`, `land_hard`, `hurt`, `death`, `step`, `pause`,
`enemy_squish`, `ground_pound`, `sword_swing`, `sword_jab`,
`sword_hit`, `sword_charge`, `sword_charge_ready`, `spin_attack`,
`jump_strike`, `shield_raise`, `shield_block`, `parry`, `roll`,
`pebble_get`, `crystal_hit`, `gate_open`, `gate_close`, `blob_alert`,
`blob_attack`, `blob_die`.

### NEW — needed (24 SFX)

| name | description |
|---|---|
| `arrow_fire` | Bowstring release — taut wood-bow twang, ~0.4 s, mid-range. |
| `arrow_hit_world` | Wooden thunk into wood, ~0.3 s. |
| `arrow_hit_flesh` | Damp thock + small squelch, ~0.3 s. |
| `seed_fire` | Soft slingshot snap with a pop on release, ~0.25 s. |
| `seed_hit` | Tiny pebble bonk on stone, ~0.15 s, high-pitched. |
| `bomb_fuse` | Sizzling fuse loop, ~0.6 s loop-friendly, gentle crackle. |
| `bomb_explode` | Punchy mid-range explosion, low boom + scattered debris, ~1.0 s. NO long tail (envelope cuts within 1 s). |
| `hookshot_fire` | Sharp metallic chain-launch — chain rattle + bowstring zip, ~0.5 s. |
| `hookshot_hit` | Metal spike into wood/stone with a heavy thunk, ~0.3 s. |
| `hookshot_pull` | Continuous chain-being-reeled-in clatter, ~0.8 s loop-friendly. |
| `bush_cut` | Wet leaf rustle + a small slice, ~0.3 s. |
| `rock_break` | Stone shatter — crunch + small debris, ~0.4 s. |
| `door_unlock` | Heavy lock turning + click, ~0.5 s. |
| `door_close` | Heavy wooden door thud, ~0.6 s. |
| `npc_talk_blip` | Single short voice-bleep (no language), 80-100 ms. Like a friendly text-blip. |
| `menu_select` | Subtle UI cursor move tick, ~80 ms. |
| `menu_confirm` | Bright UI confirm chime, ~0.25 s. |
| `menu_back` | Soft UI back tick, ~0.15 s, lower than confirm. |
| `heart_get` | Cheerful single chime — small ascending interval, ~0.35 s. |
| `heart_container_get` | Triumphant 4-note fanfare on harp + flute, ~1.5 s. THIS one can be longer. |
| `fairy_revive` | Magical sparkle flutter + soft rising harp glissando, ~1.2 s. |
| `boss_horn` | Single low brass blast for boss-arena entry, ~0.8 s. |
| `boss_clear` | Short triumphant 6-note brass+harp fanfare, ~2.0 s. THIS one can be longer. |
| `warp_song` | 6-note ocarina-style melody followed by a magical whoosh, ~2.5 s. THIS one can be longer. |

### NEW ambient loops (3) — drop into `TODO/sfx/`, mark as ambient

| name | description |
|---|---|
| `amb_day_wind` | Quiet outdoor wind layer, gentle birds occasionally, 30 s, seamless loop. |
| `amb_night_crickets` | Crickets + distant owl, 30 s seamless loop. |
| `amb_water_lap` | Slow water lapping for mirelake, 20 s loop. |

---

## Where I'll put them when you drop them

When the files land in `TODO/music/` and `TODO/sfx/`:

1. I move `TODO/music/*.ogg` → `godot/assets/music/`.
2. I move `TODO/sfx/*.wav` → `godot/assets/sounds/`.
3. I extend `SoundBank.SOUND_NAMES` with the new SFX so they preload.
4. I'll wire the new sounds into the right call sites (e.g. `arrow.gd`
   plays `arrow_fire` on spawn, `arrow_hit_*` on overlap; `bomb.gd`
   plays `bomb_explode` on detonate; etc.).
5. Music tracks already have engine support — just dropping the file
   is enough; `MusicBank.play("<id>")` will pick it up automatically.

You can ship them in batches; I don't need everything at once.
