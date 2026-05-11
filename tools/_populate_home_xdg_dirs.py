#!/usr/bin/env python3
"""One-shot content injector for the 18 canonical XDG user dirs added
across all five home villages:

  hearthold_documents / hearthold_music
  brookhold_desktop / brookhold_documents / brookhold_music / brookhold_downloads
  wyrdkin_desktop / wyrdkin_documents / wyrdkin_music / wyrdkin_downloads
  lirien_desktop / lirien_documents / lirien_music / lirien_downloads
  khorgaul_desktop / khorgaul_documents / khorgaul_music / khorgaul_downloads

Tone register:
  - hearthold + brookhold = warm village (Wyrdmark folk register)
  - wyrdkin = grandmother's lyrical sad
  - lirien = clean austere mystical
  - khorgaul = scorched silent mournful (NO NPC in some, just signs/ruin)

Idempotent on prop type+name+message — won't duplicate.

Run AFTER scaffold_directory.py, BEFORE grow_filesystem.py. The bulge
pass rebinds prop positions onto the actual walking surface.
"""

import json
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


def npc(name, pos, body_color, hat_color, dialog_nodes,
        start="root", idle_hint="[E] Speak"):
    nodes = {}
    for key, text, choices in dialog_nodes:
        n = {"speaker": name, "text": text}
        if choices:
            n["choices"] = [
                {"label": lab, "next": nxt} if nxt else {"label": lab}
                for lab, nxt in choices
            ]
        nodes[key] = n
    return {
        "type": "npc",
        "pos": list(pos),
        "rotation_y": 3.14159,
        "name": name,
        "body_color": list(body_color),
        "hat_color": list(hat_color),
        "idle_hint": idle_hint,
        "dialog_tree": {"start": start, "nodes": nodes},
    }


def sign(pos, message):
    return {
        "type": "sign",
        "pos": list(pos),
        "rotation_y": 3.14159,
        "message": message,
    }


def chest(pos, contents, msg, requires=None, amount=None):
    d = {
        "type": "chest",
        "pos": list(pos),
        "rotation_y": 0.0,
        "contents": contents,
        "open_message": msg,
    }
    if requires:
        # build_dungeon.py forwards JSON `requires` to the chest's
        # `requires_flag` GD export. The chest stays closed-but-visible
        # until GameState.has_flag(requires) returns true.
        d["requires"] = requires
    if amount is not None:
        d["amount"] = int(amount)
    return d


# ---------------------------------------------------------------------------
# Per-directory props
# ---------------------------------------------------------------------------

CONTENT = {}

# ============================================================
# HEARTHOLD (warm village — Wyrdmark folk register)
# ============================================================

CONTENT["hearthold_documents"] = [
    npc("Scriverer Den", (0, 0, 0),
        (0.78, 0.65, 0.45, 1.0), (0.55, 0.36, 0.22, 1.0),
        [
            ("root",
             "Aye, come in, come in. Wipe your boots — these scrolls\n"
             "are older than the village wall.",
             [("What do you keep here?", "what"),
              ("Anything for me to read?", "read"),
              ("Walk well.", None)]),
            ("what",
             "Household ledgers, mostly. Who owes whom a sack of\n"
             "barley, who borrowed the long ladder, whose hen is\n"
             "actually whose. Boring, important work.",
             [("Boring?", "boring"),
              ("Walk well.", None)]),
            ("boring",
             "Boring is good. Boring means no one is fighting over it.",
             [("Walk well.", None)]),
            ("read",
             "There's a child's drawing pinned above the desk. A\n"
             "small tux figure with a sword too big for him. Whose\n"
             "child? I won't say.",
             [("Mine, perhaps.", None)]),
        ],
        idle_hint="[E] Speak to Scriverer Den"),
    sign((-3, 0, -1),
         "Records —\n\n"
         "household ledgers, recipe books, a child's drawing."),
    sign((3, 0, -1),
         "The kin keep what they will need to find."),
    sign((0, 0, 4),
         "A long writing-table, four chairs, and the smell of\n"
         "pine-ink. Quiet here even in the busy season."),
]

CONTENT["hearthold_music"] = [
    npc("Lutenist Cael", (0, 0, 0),
        (0.62, 0.45, 0.78, 1.0), (0.95, 0.78, 0.45, 1.0),
        [
            ("root",
             "Oh, hello! Want to hear one? It's a short one. The kin\n"
             "sing it while the bread rises.",
             [("Please play.", "play"),
              ("What's it called?", "name"),
              ("Some other time.", None)]),
            ("play",
             "*Cael plucks three notes, then a fourth that hangs in the\n"
             "air a beat longer than the others. The room feels warmer.*",
             [("Beautiful.", None)]),
            ("name",
             "'The Long Loaf.' My grandmother taught it to me. Hers\n"
             "taught her. Probably nobody wrote it down — that would\n"
             "be how you'd lose it.",
             [("Please play.", "play")]),
        ],
        idle_hint="[E] Ask Cael to play"),
    sign((-3, 0, -1),
         "Songs the kin sing while the bread rises."),
    sign((3, 0, -1),
         "A lute on a wooden stand. Strings dark with use, smooth\n"
         "where fingers find them."),
    sign((0, 0, 4),
         "A small concert hall — three rows of benches, hand-carved.\n"
         "The acoustics are warmer than the size suggests."),
]

# ============================================================
# BROOKHOLD (warm village — Wyrdmark folk register, farm-flavoured)
# ============================================================

CONTENT["brookhold_desktop"] = [
    npc("Farmer Tess", (0, 0, 0),
        (0.65, 0.55, 0.32, 1.0), (0.85, 0.72, 0.40, 1.0),
        [
            ("root",
             "Just out here doing the day's reading. Field-bench is\n"
             "warmer than the kitchen this time of year.",
             [("What are you reading?", "what"),
              ("Day's reading?", "day"),
              ("Walk well.", None)]),
            ("what",
             "Same as ever. The sky, the wind, the way the wheat\n"
             "leans. Books come later, when the light goes.",
             [("Walk well.", None)]),
            ("day",
             "Every morning. You read the field before you work it.\n"
             "If you don't, you waste a whole day arguing with it.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Farmer Tess"),
    sign((-3, 0, -1),
         "Field-bench. Sun-warmed at noon."),
    sign((3, 0, -1),
         "An open workbench in the middle of the wheat. Just a\n"
         "plank on two stones, but the seat is worn smooth."),
    chest((0, 0, -3), "heart_piece",
          "Tucked under the workbench — a Heart Piece. Tess kept\n"
          "it here through the storm; the gale didn't think to look\n"
          "at the field-bench.",
          requires="gale_roost_defeated"),
]

CONTENT["brookhold_documents"] = [
    npc("Almanac-Keeper Olber", (0, 0, 0),
        (0.55, 0.62, 0.40, 1.0), (0.78, 0.55, 0.32, 1.0),
        [
            ("root",
             "Welcome to the almanac. Every planting, every harvest,\n"
             "every queer year — it's all on this shelf.",
             [("What's the last entry?", "last"),
              ("How far back does it go?", "back"),
              ("Walk well.", None)]),
            ("last",
             "Last entry says: 'a stranger asked the cows.' I didn't\n"
             "write that. I don't know who did.",
             [("What did the cows say?", "cows")]),
            ("cows",
             "Cows don't speak to me. Perhaps they spoke to the stranger.",
             [("Walk well.", None)]),
            ("back",
             "Four generations. The earliest pages are in my\n"
             "great-grandmother's hand. She used a different\n"
             "calendar; we still don't quite agree which days were\n"
             "Tuesday.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Olber"),
    sign((-3, 0, -1),
         "Almanac —\n\n"
         "when to plant, when to harvest."),
    sign((3, 0, -1),
         "Last entry: 'a stranger asked the cows.'"),
    sign((0, 0, 4),
         "A row of clothbound books, each labelled with a year.\n"
         "The newest is open. The pen sits across the page."),
]

CONTENT["brookhold_music"] = [
    npc("Fiddler Marn", (0, 0, 0),
        (0.85, 0.55, 0.32, 1.0), (0.62, 0.42, 0.22, 1.0),
        [
            ("root",
             "Eh! Come sit. You ever learn a tune you couldn't read?\n"
             "Best way. Hands learn faster than eyes.",
             [("Who taught you?", "uncle"),
              ("Play me one?", "play"),
              ("Walk well.", None)]),
            ("uncle",
             "Uncles. Three of 'em. Couldn't read a word between 'em\n"
             "but they could pull a wedding out of a Tuesday.",
             [("Walk well.", None)]),
            ("play",
             "*Marn draws the bow. A short, bright tune that sounds\n"
             "like running water and stamping feet at once. Then a\n"
             "long note that fades just as you notice it's there.*",
             [("Thank you.", None)]),
        ],
        idle_hint="[E] Ask Marn to play"),
    sign((-3, 0, -1),
         "Fiddle-on-the-fence —\n\n"
         "taught by uncles who could not read."),
    sign((3, 0, -1),
         "A fiddle leans against the fence-post, bow tucked under\n"
         "the strings. Anyone who passes can pick it up. Most do."),
]

CONTENT["brookhold_downloads"] = [
    npc("Trader Pem", (0, 0, 0),
        (0.78, 0.62, 0.40, 1.0), (0.95, 0.85, 0.55, 1.0),
        [
            ("root",
             "Sacks just came in from the dock-wagons. I'd weigh 'em\n"
             "but the miller's gone and forgotten, and I'm no miller.",
             [("Will they spoil?", "spoil"),
              ("What's in them?", "what"),
              ("Walk well.", None)]),
            ("spoil",
             "Grain keeps. People forget faster than grain spoils,\n"
             "which is most of my problem.",
             [("Walk well.", None)]),
            ("what",
             "Mostly barley. Some oats. One sack is suspiciously\n"
             "light — I think a child opened it and never said.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Pem"),
    sign((-3, 0, -1),
         "Sacks of grain, not opened.\n\n"
         "The miller meant to weigh them last week."),
    sign((3, 0, -1),
         "Eight sacks against the wall. Dust on the topmost.\n"
         "The barn-cat sleeps on the lightest one."),
    chest((0, 0, -3), "seed",
          "Five seeds, slipped between the sacks. Pem says you can\n"
          "have them; she'll never get to planting them all.",
          amount=5),
]

# ============================================================
# WYRDKIN (Tux's grandparents' Old Hold — lyrical sad)
# ============================================================

CONTENT["wyrdkin_desktop"] = [
    npc("Grandmother's Ghost", (0, 0, 0),
        (0.78, 0.72, 0.85, 1.0), (0.55, 0.45, 0.62, 1.0),
        [
            ("root",
             "Oh — it's you. Come here, child. The pen is where I\n"
             "set it down. I meant to come back to it.",
             [("What were you writing?", "writing"),
              ("Are you alright?", "alright"),
              ("Walk well.", None)]),
            ("writing",
             "A letter. To you, perhaps. To someone I would not see\n"
             "again. The words ran out before the meaning did.",
             [("I'll read it.", "read"),
              ("Some other time.", None)]),
            ("read",
             "It is folded in the next room. Read it when you are\n"
             "old enough — though I suspect you already are.",
             [("Walk well.", None)]),
            ("alright",
             "I am as I am. The kin remember; that is enough work\n"
             "for the realm. Don't sit too long here, child. The\n"
             "light is going.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Grandmother"),
    sign((-3, 0, -1),
         "Grandmother's desk.\n\n"
         "The pen is where she set it down."),
    sign((3, 0, -1),
         "Untouched. The kin do not move anything in this room."),
    sign((0, 0, 4),
         "A wooden desk under a small window. A pen, an inkwell,\n"
         "a stack of paper. The chair is pushed back as if she\n"
         "had only just stood."),
]

CONTENT["wyrdkin_documents"] = [
    sign((-3, 0, -1),
         "A folded paper:\n\n"
         "'For Tux, when he is old enough.'"),
    sign((3, 0, -1),
         "A small chest of family papers. Birth-letters, sigil-marks,\n"
         "names of the kin who came before."),
    sign((0, 0, 4),
         "The chest is heavy with what cannot be re-written. The\n"
         "lid is unlocked, but nobody opens it idly."),
    chest((0, 0, -3), "heart_piece",
          "A Heart Piece, slipped between the papers by hands that\n"
          "knew you would one day come looking. The Triglyph is\n"
          "what made you ready to find it.",
          requires="triglyph_assembled"),
]

CONTENT["wyrdkin_music"] = [
    sign((-3, 0, -1),
         "The harp.\n\n"
         "Grandmother could play three songs from memory."),
    sign((3, 0, -1),
         "Strung yet, though the lowest string has gone slack.\n"
         "No one has tuned it since."),
    sign((0, 0, 4),
         "A single harp hangs on the wall on a worn leather strap.\n"
         "The wood is dark; the strings are dust-pale."),
]

CONTENT["wyrdkin_downloads"] = [
    npc("Postal-Wyrd Hessa", (0, 0, 0),
        (0.45, 0.42, 0.55, 1.0), (0.62, 0.55, 0.65, 1.0),
        [
            ("root",
             "Mm. I keep leaving it here. The pile by the door. I\n"
             "mean to read it, and then a day goes by, and the pile\n"
             "grows.",
             [("Anything from far away?", "far"),
              ("Why not just open one?", "open"),
              ("Walk well.", None)]),
            ("far",
             "A folded scroll on top — from somewhere I cannot place.\n"
             "Could be the Drift. Could be older than the Drift.",
             [("Walk well.", None)]),
            ("open",
             "Because then there will be a thing to do, child. And\n"
             "I am not yet ready for a thing to do.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Hessa"),
    sign((-3, 0, -1),
         "Things to read — never read.\n\n"
         "The pile by the door grows."),
    sign((3, 0, -1),
         "Letters, scrolls, three folded broadsides. Most are\n"
         "still sealed. The seals are unfamiliar."),
]

# ============================================================
# LIRIEN (clean austere mystical)
# ============================================================

CONTENT["lirien_desktop"] = [
    npc("Lirien's Apprentice", (0, 0, 0),
        (0.65, 0.78, 0.95, 1.0), (0.45, 0.55, 0.78, 1.0),
        [
            ("root",
             "You came up here? Few do. Lirien is below, with the\n"
             "Sigilkeep. I keep the instruments clean.",
             [("What are these?", "what"),
              ("Where did you come from?", "where"),
              ("Walk well.", None)]),
            ("what",
             "Astrolabe — for the slow walkers. Quadrant — for the\n"
             "one that does not move. Ruler — it knows the realm\n"
             "has a curve to it.",
             [("A curved realm?", "curve")]),
            ("curve",
             "A small one. Most cannot feel it. Some instruments can.",
             [("Walk well.", None)]),
            ("where",
             "Sigilkeep, originally. Wandered up. The air here is\n"
             "different — drier, older.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to the Apprentice"),
    sign((-3, 0, -1),
         "Astrolabe. Quadrant.\n\n"
         "A ruler that knows the realm's curve."),
    sign((3, 0, -1),
         "Everything set parallel, square, true. Even the dust\n"
         "seems to land in rows."),
    sign((0, 0, 4),
         "A clean desk under a slanted skylight. Brass instruments\n"
         "rest in their cradles, each catching its own slice of star."),
]

CONTENT["lirien_documents"] = [
    npc("Sky-Scribe Vell", (0, 0, 0),
        (0.55, 0.62, 0.78, 1.0), (0.35, 0.42, 0.62, 1.0),
        [
            ("root",
             "I file the sky. Charts on the left; tablets on the\n"
             "right. The middle drawer is the one that does not\n"
             "move.",
             [("The one that does not move?", "fixed"),
              ("The seven that walk slow?", "seven"),
              ("Walk well.", None)]),
            ("fixed",
             "Every chart has one. The pivot of the great wheel.\n"
             "Sailors call it North; Lirien calls it the Stayer.",
             [("Walk well.", None)]),
            ("seven",
             "Seven slow walkers cross the sky over a year. The\n"
             "tablets record where they pause. Lirien predicts the\n"
             "next pause; she is usually right.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Sky-Scribe Vell"),
    sign((-3, 0, -1),
         "Star-charts.\n\n"
         "The seven that walk slow. The one that does not move."),
    sign((3, 0, -1),
         "Sky-tablets stacked by season. Each is a thin slate\n"
         "etched with sigil-points and faint compass lines."),
]

CONTENT["lirien_music"] = [
    npc("Bowl-Tender Veen", (0, 0, 0),
        (0.78, 0.78, 0.92, 1.0), (0.55, 0.55, 0.78, 1.0),
        [
            ("root",
             "Quietly, please. The bowl wants only one strike at a\n"
             "time, and only with the rim of one's nail.",
             [("May I try?", "try"),
              ("Why so quiet?", "quiet"),
              ("Walk well.", None)]),
            ("try",
             "*Veen guides your hand. The bowl rings a clear note,\n"
             "high and watery. The sound hangs in the air longer than\n"
             "you expect — then fades, and the room is louder for\n"
             "having held it.*",
             [("Beautiful.", None)]),
            ("quiet",
             "Because one struck bowl makes you listen for the next.\n"
             "Two struck bowls makes you stop listening.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Veen"),
    sign((-3, 0, -1),
         "Glass bowl, water-tuned.\n\n"
         "Strike with the rim of one's nail."),
    sign((3, 0, -1),
         "Half-filled with still water. The bowl sits on a wooden\n"
         "stand carved with a single sigil for *patience*."),
]

CONTENT["lirien_downloads"] = [
    sign((-3, 0, -1),
         "Letters from places that did not give their names."),
    sign((3, 0, -1),
         "From the Drift, from the Sprawl, from somewhere called\n"
         "the Stoneroost-That-Never-Was."),
    sign((0, 0, 4),
         "A small basket on a shelf. Each letter is sealed with a\n"
         "different sigil. None of them are open."),
]

# ============================================================
# KHORGAUL (scorched silent mournful — minimal NPCs)
# ============================================================

# khorgaul_desktop — NO NPC, atmosphere only.
CONTENT["khorgaul_desktop"] = [
    sign((-3, 0, -1),
         "Burned through.\n\n"
         "The corner is gone."),
    sign((3, 0, -1),
         "Soot rings the floor where the desk used to stand. The\n"
         "shape of it is still there — paler stone where the wood\n"
         "shielded it."),
    sign((0, 0, 4),
         "Quiet. The kind of quiet that comes after a thing happens\n"
         "and nobody comes back to clean up."),
]

CONTENT["khorgaul_documents"] = [
    npc("Drev the Cultist", (0, 0, 0),
        (0.55, 0.32, 0.28, 1.0), (0.32, 0.20, 0.18, 1.0),
        [
            ("root",
             "He believed it, you understand. He wrote it on every\n"
             "page he could find. The fire ate most of them.",
             [("Believed what?", "what"),
              ("Who was he?", "who"),
              ("Walk well.", None)]),
            ("what",
             "That he would be the one to keep what the realm\n"
             "couldn't lose. He called himself 'the Hoarder.' The\n"
             "name is on the half-page.",
             [("And was he?", "was"),
              ("Walk well.", None)]),
            ("was",
             "The realm lost him. So no.",
             [("Walk well.", None)]),
            ("who",
             "Khorgaul. Before he was the burned thing. Before the\n"
             "Hoarder ate the man.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to Drev"),
    sign((-3, 0, -1),
         "Half a page. Legible:\n\n"
         "'I will keep what the realm cannot lose.'"),
    sign((3, 0, -1),
         "He believed it."),
    sign((0, 0, 4),
         "Charred edges. The legible portion is in a careful, even\n"
         "hand — the hand of someone who took his time."),
]

# khorgaul_music — NO NPC.
CONTENT["khorgaul_music"] = [
    sign((-3, 0, -1),
         "A drum.\n\n"
         "Cracked through. Burnt strap."),
    sign((3, 0, -1),
         "Silent. The skin is split along a long char-line; the\n"
         "shell is warped and will not hold a beat."),
    sign((0, 0, 4),
         "It was a war-drum, once. Nobody has struck it since the\n"
         "Roost burned."),
]

# khorgaul_downloads — NO NPC, NO chest. Empty room.
CONTENT["khorgaul_downloads"] = [
    sign((0, 0, 4),
         "Empty.\n\n"
         "Whatever was here was taken."),
    sign((-3, 0, -1),
         "Soot on the floor in the shape of a stack of something —\n"
         "boxes, crates, sacks. Long gone."),
    sign((3, 0, -1),
         "The door-frame is scorched on both sides. Someone in,\n"
         "someone out."),
]


# ---------------------------------------------------------------------------

def merge_props(existing: list, new: list) -> list:
    """Append new props skipping ones that already match (type+name+message)."""
    def key(p):
        return (p.get("type", ""), p.get("name", ""), p.get("message", ""),
                p.get("open_message", ""))
    have = {key(p) for p in existing}
    out = list(existing)
    for p in new:
        if key(p) in have:
            continue
        out.append(p)
        have.add(key(p))
    return out


def main():
    edits = 0
    for level_id, new_props in CONTENT.items():
        path = os.path.join(DUNGEONS, level_id + ".json")
        if not os.path.exists(path):
            print("MISSING: %s (run scaffold_directory.py first)" % path)
            continue
        with open(path) as f:
            data = json.load(f)
        before = len(data.get("props", []))
        data["props"] = merge_props(data.get("props", []), new_props)
        after = len(data["props"])
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        added = after - before
        edits += added
        print("%-22s  + %d props (now %d)" % (level_id, added, after))
    print("\ntotal props added: %d" % edits)


if __name__ == "__main__":
    main()
