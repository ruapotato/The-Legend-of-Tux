#!/usr/bin/env python3
"""One-shot populator for the /var-branch skeletons.

Loads each of library / cache / cache_wyrdmark / stacks / ledger / backwater
and APPENDS lights, enemies, and props (NPCs, signs, chests, bushes, rocks).
Spawns and load_zones are left untouched. Re-running clears any previously
appended content from this script (see _PURGE_TAG below) so the script is
idempotent.
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")

# A small marker we put into a sign that exists in the skeleton already
# (the `/var/...` placeholder sign at the south of each room). We do NOT
# touch that sign — we leave it as-is. Idempotency comes from the fact
# that we always replace lights/enemies and rebuild props by category.

# We only blow away what the skeleton authored: a single placeholder sign.
# We then re-append everything fresh. The skeleton's spawns + load_zones
# stay.

# ---- helpers ------------------------------------------------------------

def npc(name, pos, body_color=None, hat_color=None, idle_hint=None,
        rotation_y=3.14159, dialog_tree=None):
    p = {
        "type":       "npc",
        "pos":        pos,
        "rotation_y": rotation_y,
        "name":       name,
    }
    if body_color is not None: p["body_color"] = body_color
    if hat_color  is not None: p["hat_color"]  = hat_color
    if idle_hint:              p["idle_hint"]  = idle_hint
    if dialog_tree is not None: p["dialog_tree"] = dialog_tree
    return p


def sign(pos, message, rotation_y=3.14159):
    return {"type": "sign", "pos": pos, "rotation_y": rotation_y,
            "message": message}


def chest(pos, contents, open_message=None, key_group=None, amount=None,
          rotation_y=0.0):
    p = {"type": "chest", "pos": pos, "rotation_y": rotation_y,
         "contents": contents}
    if open_message: p["open_message"] = open_message
    if key_group:    p["key_group"] = key_group
    if amount is not None: p["amount"] = amount
    return p


def bush(pos):    return {"type": "bush", "pos": pos, "rotation_y": 0.0}
def rock(pos):    return {"type": "rock", "pos": pos, "rotation_y": 0.0}


def light(pos, color, energy=0.7, rng=8.0):
    return {"pos": pos, "color": color, "energy": energy, "range": rng}


def enemy(t, pos):
    return {"type": t, "pos": pos}


# ---- LIBRARY ------------------------------------------------------------

def yvenn_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Mistress Yvenn",
                "text": "Welcome to the Library of Past Echoes, little walker. Speak softly. The old voices listen here.",
                "choices": [
                    {"label": "What is this place?",            "next": "mission"},
                    {"label": "Who walks the aisles?",          "next": "readers"},
                    {"label": "Have you read of the Sigils?",   "next": "sigils"},
                    {"label": "How is the Wyrdmark faring?",    "next": "slip"},
                    {"label": "What lies deeper?",              "next": "deeper"},
                    {"label": "I should walk on.",              "next": "bye"},
                ],
            },
            "mission": {
                "speaker": "Mistress Yvenn",
                "text": "We keep what was, so what is can know it was real. That is the whole of our craft, said simply. Said well, it would take a longer life than mine.",
                "choices": [
                    {"label": "Who walks the aisles?",          "next": "readers"},
                    {"label": "Have you read of the Sigils?",   "next": "sigils"},
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "readers": {
                "speaker": "Mistress Yvenn",
                "text": "Readers. We do not call ourselves scholars. A scholar adds. A Reader only listens. Apprentice Yawen is somewhere up a ladder. Pell is back from the field, though he will not say from where.",
                "choices": [
                    {"label": "And the others?",                "next": "others"},
                    {"label": "What is this place?",            "next": "mission"},
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "others": {
                "speaker": "Mistress Yvenn",
                "text": "Theln tends the Wyrdmark records. Olm has bent his life around the Drawing-In, the poor soul. And there is one more, who comes and goes. We do not name her aloud.",
                "choices": [
                    {"label": "Why not?",                       "next": "cat_unspoken"},
                    {"label": "Back.",                          "next": "readers"},
                ],
            },
            "cat_unspoken": {
                "speaker": "Mistress Yvenn",
                "text": "She is a Reader who left, and came back. That is all I will say of her, and all you should ask.",
                "choices": [
                    {"label": "Back.",                          "next": "readers"},
                ],
            },
            "sigils": {
                "speaker": "Mistress Yvenn",
                "text": "Three marks of the Source. Lirien's Sight. Khorgaul's Shaping. And the third — Sharing — has not walked the realm in a long age. We keep the records, and we wait.",
                "choices": [
                    {"label": "What of the Drawing-In?",        "next": "drawing"},
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "drawing": {
                "speaker": "Mistress Yvenn",
                "text": "Khorgaul pulls. The Source thins. We catalogue the thinning here, page by page. By the Source, I had hoped to be retired before the shelves grew this heavy.",
                "choices": [
                    {"label": "Back.",                          "next": "sigils"},
                    {"label": "Back to the start.",             "next": "root"},
                ],
            },
            "slip": {
                "speaker": "Mistress Yvenn",
                "text": "Faring? Oh — better, I think, than when the breath nearly stilled last week. We had three Readers in the south aisle holding hands when it happened. A bad hour. But the breath came back.",
                "choices": [
                    {"label": "I should walk on.",              "next": "bye"},
                ],
            },
            "deeper": {
                "speaker": "Mistress Yvenn",
                "text": "Down: the Cache, where memories fade. The Stacks east, where they are kept. The Ledger west, where each day is written. And the Backwater, beyond — the stream that overflows toward Mirelake.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Mistress Yvenn",
                "text": "Walk well, little walker. Tread softly. The pages remember footfalls.",
            },
        },
    }


def yawen_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Apprentice Yawen",
                "text": "Oh — hello! Do you need a book? I can find a book. Probably. I'm still learning the aisles.",
                "choices": [
                    {"label": "Tell me of the Mistress.",       "next": "mistress"},
                    {"label": "What do apprentices do?",        "next": "duties"},
                    {"label": "Have you read everything here?", "next": "joke"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "mistress": {
                "speaker": "Apprentice Yawen",
                "text": "Mistress Yvenn? Oh, she knows everything. I mean — everything that's been written. She remembers shelves the way I remember songs. I want to be like her one day. If I last that long.",
                "choices": [
                    {"label": "Back.", "next": "root"},
                ],
            },
            "duties": {
                "speaker": "Apprentice Yawen",
                "text": "I dust. I copy out faded lines. I climb a lot of ladders. The Mistress says reading is mostly climbing, in the end.",
                "choices": [
                    {"label": "Back.", "next": "root"},
                ],
            },
            "joke": {
                "speaker": "Apprentice Yawen",
                "text": "Lirien's breath, no! I'd be three hundred. Pell laughs at me when I try.",
                "choices": [
                    {"label": "Back.", "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Apprentice Yawen",
                "text": "Walk well! Mind the third ladder, it wobbles.",
            },
        },
    }


def pell_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Reader-on-Sabbatical Pell",
                "text": "Hm. A walker. Don't mind me. I'm not on duty. I'm — between things.",
                "choices": [
                    {"label": "Where have you been?",           "next": "field"},
                    {"label": "What's the book?",               "next": "book"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "field": {
                "speaker": "Reader-on-Sabbatical Pell",
                "text": "Out. In the realm. Reading the kind of pages that aren't bound. I'd rather not say where, not yet. Some things you say aloud and they stop being true.",
                "choices": [
                    {"label": "Fair enough.",                   "next": "root"},
                ],
            },
            "book": {
                "speaker": "Reader-on-Sabbatical Pell",
                "text": "(He keeps one hand flat on the cover, as if it might open if he stopped.) It's not for reading. Not by me. Not yet.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Reader-on-Sabbatical Pell",
                "text": "Walk well. And don't read in straight lines. Nothing useful is ever in a straight line.",
            },
        },
    }


def theln_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Reader Theln",
                "text": "You smell of the outside. Good. Come, come — I work the Wyrdmark records, the small ones in the alcove down at the Cache. Have you been to the Hollow yet?",
                "choices": [
                    {"label": "Tell me of the Hollow.",         "next": "hollow"},
                    {"label": "What worries you?",              "next": "worry"},
                    {"label": "Tell me of the Wyrdking.",       "next": "wyrdking"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "hollow": {
                "speaker": "Reader Theln",
                "text": "The Hollow of the Last Wyrd. Old. Old past my reading. Down through the Cache and into the small alcove there — Recorder Thav can tell you more than I can. He keeps the closer pages.",
                "choices": [
                    {"label": "What worries you?",              "next": "worry"},
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "worry": {
                "speaker": "Reader Theln",
                "text": "The Hollow has been louder, of late. Pages move on the desk between morning and morning. Khorgaul's grip, I would rather it stayed quiet, the way old things should.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "wyrdking": {
                "speaker": "Reader Theln",
                "text": "The Wyrdking Bonelord. He sits at the bottom of the Hollow and does not want to. Khorgaul shaped him from the bones of the Last Wyrd, and the bones do not forget being a creature.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Reader Theln",
                "text": "Walk well. And if you go to the Hollow — go with a Sigil. Not without.",
            },
        },
    }


def olm_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Reader Olm",
                "text": "Sit, walk on, do as you like. I am reading. Always reading. The Drawing-In is my whole shelf and I have not finished a page in three years.",
                "choices": [
                    {"label": "What is the Drawing-In?",        "next": "what"},
                    {"label": "Tell me of Khorgaul.",           "next": "khorgaul"},
                    {"label": "What can be done?",              "next": "done"},
                    {"label": "Why does he do it?",             "next": "why"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "what": {
                "speaker": "Reader Olm",
                "text": "The slow loss. The Source pulled out of glades, out of doors, out of the names of streams. A thinning. You will not see it. You will only feel something missing, where something used to lean toward you.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "khorgaul": {
                "speaker": "Reader Olm",
                "text": "The Hoarder. Bearer of the Sigil of Shaping. He gathers. He has been gathering for a long age, and a long age is a long time to gather.",
                "choices": [
                    {"label": "Why does he do it?",             "next": "why"},
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "why": {
                "speaker": "Reader Olm",
                "text": "Because the Sigil of Shaping wants substance, and the substance is nearby, and he is hungry. He does not hate the Wyrdmark. That is the saddest part of any reading I have done.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "done": {
                "speaker": "Reader Olm",
                "text": "The Sigil of Sharing. Lirien's third mark. It returns what is held. It has not walked the realm in a hundred years. We wait. We have always waited.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Reader Olm",
                "text": "Walk well. Read what you can. Forget what you must.",
            },
        },
    }


def cat_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Cat",
                "text": "(She glances at you sideways. She touches the wall beside a sign. A single line of an old text comes out of her, without her wanting it to.) ...the lamp does not know it is a lamp.",
                "choices": [
                    {"label": "Who are you?",                   "next": "who"},
                    {"label": "What did you just say?",         "next": "said"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "who": {
                "speaker": "Cat",
                "text": "A Reader who left, and came back. That is all anyone says of me. They are right not to say more.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "said": {
                "speaker": "Cat",
                "text": "(She looks at her hand, surprised.) The wall said it. I only carried it the rest of the way out.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Cat",
                "text": "Walk well. The pages already know you walked.",
            },
        },
    }


def populate_library(d):
    # Lights — soft yellow lamps, energy 0.7, range 8, color [1.0, 0.92, 0.65]
    lights = []
    lamp_color = [1.0, 0.92, 0.65, 1.0]
    lamp_positions = [
        # outer ring
        [-22, 3.0, -22], [-22, 3.0, -10], [-22, 3.0, 0], [-22, 3.0, 10], [-22, 3.0, 22],
        [22, 3.0, -22], [22, 3.0, -10], [22, 3.0, 0], [22, 3.0, 10], [22, 3.0, 22],
        [-10, 3.0, -22], [10, 3.0, -22], [-10, 3.0, 22], [10, 3.0, 22],
        # inner aisles
        [-12, 3.0, -8], [12, 3.0, -8], [-12, 3.0, 8], [12, 3.0, 8],
        [-6, 3.0, -16], [6, 3.0, -16], [-6, 3.0, 16], [6, 3.0, 16],
        # near central plinth
        [-3, 3.2, 0], [3, 3.2, 0], [0, 3.2, -3], [0, 3.2, 3],
    ]
    for p in lamp_positions:
        lights.append(light(p, lamp_color, energy=0.7, rng=8.0))
    d["lights"] = lights

    # Add a small raised plinth as a second floor (no walls/roof). 4x4
    # cells centered on origin, raised +0.4m.
    plinth_cells = [[i, j] for i in range(-2, 2) for j in range(-2, 2)]
    plinth_floor = {
        "y":             0.4,
        "name":          "study_plinth",
        "cells":         plinth_cells,
        "wall_height":   0.4,
        "wall_color":    [0.36, 0.30, 0.24, 1.0],
        "floor_color":   [0.45, 0.38, 0.30, 1.0],
        "wall_material": "stone",
        "has_floor":     True,
        "has_walls":     False,
        "has_roof":      False,
    }
    # Insert plinth as additional floor
    d["grid"]["floors"].append(plinth_floor)

    # No enemies — sacred space.
    d["enemies"] = []

    props = []

    # Keep the existing south placeholder sign and re-author it as the
    # arrival sign; replace its message.
    props.append(sign([0, 0, 24], "The Library of Past Echoes.\n\nKeep your voice low. The pages remember footfalls.", rotation_y=3.14159))

    # 8-10 lore signs
    props.append(sign([-18, 0, -14],
        "Posted, in a careful hand:\n\n\"Silence is asked of every walker in the Stacks. The deepest reading is what looks back at you. Do not surprise it.\""))
    props.append(sign([18, 0, -14],
        "An older notice, the ink running:\n\n\"Three Readers were lost to a long inscription in the year of the second thinning. Their names are kept in the west aisle. Speak them only when alone.\""))
    props.append(sign([-18, 0, 14],
        "Roster of the Readers, freshly inked:\n\nMistress Yvenn (Head)\nApprentice Yawen\nPell (sabbatical)\nTheln (Wyrdmark records)\nOlm (the Drawing-In)\n— and one entry, scratched out long ago.",
        rotation_y=1.5708))
    props.append(sign([18, 0, 14],
        "A page-marker pinned to the shelf:\n\n\"What is forgotten was loved by something. The Library remembers on its behalf.\"",
        rotation_y=-1.5708))
    props.append(sign([-8, 0, -22],
        "An inscription carved into the lintel above the north stair:\n\n\"All who walk here walk in Lirien's breath. Walk softly. The breath is thin in the next room.\""))
    props.append(sign([8, 0, -22],
        "A folded notice, weighted with a stone:\n\n\"Climbing of ladders by visitors is permitted. Climbing of shelves is not. The shelves were not built to be climbed and they remember.\""))
    props.append(sign([-22, 0, 0],
        "A small wood plaque:\n\n\"In memory of the year of the long quiet, when no Reader spoke for a season, that the pages might be heard.\"",
        rotation_y=1.5708))
    props.append(sign([22, 0, 0],
        "A reader's marginalia, framed and posted:\n\n\"The deepest reading is what looks back at you. I have read this line three times this week and it has read me twice. — Olm\"",
        rotation_y=-1.5708))
    props.append(sign([0, 0, -8],
        "A note tied to a lamp-post with a faded cord:\n\n\"To whomever oils these lamps: the third from the south flickers when something old is being read aloud. Please do not adjust it. It is doing its work.\""))

    # 4 chests
    props.append(chest([-12, 0, -10], "pebble", amount=10,
        open_message="A handful of small smooth stones, kept for some reading-tally long forgotten."))
    props.append(chest([12, 0, -10], "fairy",
        open_message="A glass vessel. Inside, a small bright thing turns once and looks at you."))
    props.append(chest([-12, 0, 12], "heart_piece" if False else "heart",
        open_message="A pressed heart-flower from the Sourceplain, dry as paper, still warm to the touch."))
    props.append(chest([12, 0, 12], "key", key_group="library",
        open_message="A small brass key. The Library keeps a few of these for its inner aisles."))

    # 8 bushes — small potted plants
    bush_positions = [
        [-20, 0, -20], [20, 0, -20], [-20, 0, 20], [20, 0, 20],
        [-15, 0, 0], [15, 0, 0], [0, 0, 18], [0, 0, -18],
    ]
    for bp in bush_positions:
        props.append(bush(bp))

    # 3 rocks
    for rp in [[-8, 0, -2], [8, 0, -2], [0, 0, -16]]:
        props.append(rock(rp))

    # NPCs
    props.append(npc("Mistress Yvenn", [-4, 0.5, -2],
        body_color=[0.4, 0.32, 0.55, 1.0],
        hat_color=[0.18, 0.14, 0.28, 1.0],
        idle_hint="[E] Speak with the Mistress",
        rotation_y=0.5,
        dialog_tree=yvenn_dialog()))
    props.append(npc("Apprentice Yawen", [4, 0.5, -2],
        body_color=[0.55, 0.7, 0.5, 1.0],
        hat_color=[0.3, 0.4, 0.25, 1.0],
        idle_hint="[E] Speak with Yawen",
        rotation_y=-0.5,
        dialog_tree=yawen_dialog()))
    props.append(npc("Reader-on-Sabbatical Pell", [-15, 0.5, -18],
        body_color=[0.35, 0.3, 0.25, 1.0],
        hat_color=[0.2, 0.16, 0.12, 1.0],
        idle_hint="[E] Speak with Pell",
        rotation_y=2.0,
        dialog_tree=pell_dialog()))
    props.append(npc("Reader Theln", [15, 0.5, -18],
        body_color=[0.45, 0.4, 0.55, 1.0],
        hat_color=[0.25, 0.22, 0.32, 1.0],
        idle_hint="[E] Speak with Theln",
        rotation_y=-2.0,
        dialog_tree=theln_dialog()))
    props.append(npc("Reader Olm", [-15, 0.5, 14],
        body_color=[0.5, 0.48, 0.42, 1.0],
        hat_color=[0.28, 0.25, 0.22, 1.0],
        idle_hint="[E] Speak with Olm",
        rotation_y=1.0,
        dialog_tree=olm_dialog()))
    props.append(npc("Cat", [10, 0.5, 18],
        body_color=[0.18, 0.15, 0.16, 1.0],
        hat_color=[0.10, 0.08, 0.10, 1.0],
        idle_hint="[E] Speak with the Reader",
        rotation_y=3.14159,
        dialog_tree=cat_dialog()))

    d["props"] = props


# ---- CACHE --------------------------------------------------------------

def meld_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Curator Meld",
                "text": "Mind the dust, walker. The Cache is older than its keepers, and we are not young.",
                "choices": [
                    {"label": "What is kept here?",             "next": "kept"},
                    {"label": "What is lost?",                  "next": "lost"},
                    {"label": "Why is it dim?",                 "next": "dim"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "kept": {
                "speaker": "Curator Meld",
                "text": "What the Library above could not bear to throw away, and could not bear to file. Half-pages. Half-thoughts. The almost-said.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "lost": {
                "speaker": "Curator Meld",
                "text": "More than I can say. Whole shelves used to hold the names of glades. The shelves are still here. The names are not. We do not say what we have lost. To say it would be to lose it again.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "dim": {
                "speaker": "Curator Meld",
                "text": "Pages do not love light. Memory does not love noise. The Cache loves neither. The lamps are kept low and the curators speak slowly. That is the whole rule of this room.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Curator Meld",
                "text": "Walk well. Step softly past the empty places.",
            },
        },
    }


def brael_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Junior Catalogger Brael",
                "text": "Khorgaul's grip — every time I think I have a shelf catalogued, another book is gone. Or there's a gap where I'm sure a book used to be.",
                "choices": [
                    {"label": "Surely you wrote it down?",      "next": "wrote"},
                    {"label": "Why are there gaps?",            "next": "gaps"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "wrote": {
                "speaker": "Junior Catalogger Brael",
                "text": "I wrote down what I could see. The catalog has gaps too. Curator Meld says the catalog is ALSO a memory, and memories thin. I am beginning to believe him. I would rather not.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "gaps": {
                "speaker": "Junior Catalogger Brael",
                "text": "The Drawing-In, they say. Khorgaul gathers, and what he gathers is here, sometimes. We dust the empty places. There is nothing else to do with them.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Junior Catalogger Brael",
                "text": "Walk well. Mind the third aisle. There used to be a step there.",
            },
        },
    }


def ghost_reader_dialog():
    # Empty-tree-NPC behavior is "..."; we provide a single nodding line
    # for warmth.
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Ghost-Reader",
                "text": "(The faint Reader nods to you, slowly, and goes back to her shelf.)",
            },
        },
    }


def populate_cache(d):
    lights = []
    amber = [0.95, 0.7, 0.4, 1.0]
    for p in [
        [-12, 3.0, -12], [12, 3.0, -12], [-12, 3.0, 12], [12, 3.0, 12],
        [0, 3.0, -8], [0, 3.0, 8], [-8, 3.0, 0], [8, 3.0, 0],
    ]:
        lights.append(light(p, amber, energy=0.5, rng=7.0))
    d["lights"] = lights

    # 3 spore drifters
    d["enemies"] = [
        enemy("spore", [-6, 0.5, -4]),
        enemy("spore", [6, 0.5, -4]),
        enemy("spore", [0, 0.5, 6]),
    ]

    props = []
    # Replace the placeholder sign as arrival sign
    props.append(sign([0, 0, 12],
        "The Cache.\n\nWhat the Library above could not bear to throw away. The dust is older than the catalog.",
        rotation_y=3.14159))

    # 6 lore signs
    props.append(sign([-12, 0, -10],
        "A catalog card pinned crookedly to the shelf:\n\n\"Aisle three, shelves one through four — contents recovered after the second thinning. Twenty-two volumes. Fourteen partial. Six titled.\""))
    props.append(sign([12, 0, -10],
        "A weathered notice pasted to a beam:\n\n\"THIS SHELF: empty since the Drawing-In began. Do not refill. Do not dust. The empty place is itself the record.\""))
    props.append(sign([-12, 0, 8],
        "A folded courtesy:\n\n\"Visitors are kindly asked not to disturb the dust. The dust is filed.\""))
    props.append(sign([12, 0, 8],
        "A small wooden tag:\n\n\"In memory of the volumes that thinned in the year of the long quiet. Their pages went elsewhere. We do not know where.\""))
    props.append(sign([0, 0, -10],
        "A loose page, slipped under glass:\n\n\"...and the lamp at the end of the aisle, when it flickered, named us each in turn — and we who heard it have never named ourselves the same way since.\""))
    props.append(sign([-6, 0, 4],
        "A faded label hanging from a hook with no shelf beneath it:\n\n\"This shelf has been gone longer than I have been a curator. — Meld\""))

    # 2 chests
    props.append(chest([-10, 0, 6], "heart",
        open_message="A small heart-flower wrapped in tissue. Whoever set this here did not write a note."))
    props.append(chest([10, 0, 6], "key", key_group="cache",
        open_message="A small dark key. The Cache keeps these for its dustier corners."))

    # 6 bushes (dried herbs)
    for bp in [[-14, 0, -14], [14, 0, -14], [-14, 0, 14], [14, 0, 14],
               [-4, 0, 0], [4, 0, 0]]:
        props.append(bush(bp))

    # 4 rocks
    for rp in [[-10, 0, -2], [10, 0, -2], [-2, 0, 10], [2, 0, -8]]:
        props.append(rock(rp))

    # NPCs
    props.append(npc("Curator Meld", [-3, 0.5, -2],
        body_color=[0.45, 0.4, 0.42, 1.0],
        hat_color=[0.2, 0.18, 0.20, 1.0],
        idle_hint="[E] Speak with the Curator",
        rotation_y=1.0,
        dialog_tree=meld_dialog()))
    props.append(npc("Junior Catalogger Brael", [3, 0.5, -2],
        body_color=[0.55, 0.5, 0.4, 1.0],
        hat_color=[0.3, 0.27, 0.22, 1.0],
        idle_hint="[E] Speak with Brael",
        rotation_y=-1.0,
        dialog_tree=brael_dialog()))
    props.append(npc("A faint Reader", [-8, 0.5, 8],
        body_color=[0.7, 0.72, 0.78, 1.0],
        hat_color=[0.6, 0.62, 0.68, 1.0],
        idle_hint="[E] Greet the faint Reader",
        rotation_y=2.5,
        dialog_tree=ghost_reader_dialog()))

    d["props"] = props


# ---- CACHE_WYRDMARK -----------------------------------------------------

def thav_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Recorder Thav",
                "text": "Welcome, walker. This alcove keeps the Wyrdmark's own records — small, but very old. The Hollow lies through that door.",
                "choices": [
                    {"label": "Tell me of the Wyrdking.",       "next": "wyrdking"},
                    {"label": "What is the Last Wyrd?",         "next": "wyrd"},
                    {"label": "Any hint for the Hollow?",       "next": "hint"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "wyrdking": {
                "speaker": "Recorder Thav",
                "text": "The Wyrdking Bonelord. The last shaping Khorgaul put on the Wyrd's bones. He guards the inner door. He does not, in the deepest part of him, want to.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "wyrd": {
                "speaker": "Recorder Thav",
                "text": "An ancient creature. Old before the Wyrdkin walked. The Hollow is named for it because it hollowed the place out, slowly, by lying still in it for a long time. That is all the records say with certainty.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "hint": {
                "speaker": "Recorder Thav",
                "text": "A line from a faded page: \"Three triggers, three Sigils, all must answer the door.\" I do not know what it means in full. But I would mark it down, walker. The Hollow loves a thing said three times.",
                "choices": [
                    {"label": "Thank you.",                     "next": "bye"},
                ],
            },
            "bye": {
                "speaker": "Recorder Thav",
                "text": "Walk well. And go in with a Sigil-bearer's blessing, or do not go in at all.",
            },
        },
    }


def populate_cache_wyrdmark(d):
    d["lights"] = [
        light([-3, 3.0, -3], [0.95, 0.78, 0.55, 1.0], energy=0.6, rng=7.0),
        light([ 3, 3.0,  3], [0.95, 0.78, 0.55, 1.0], energy=0.6, rng=7.0),
    ]
    d["enemies"] = []

    props = []
    # Replace placeholder sign with a richer arrival sign
    props.append(sign([0, 0, 2],
        "Wyrdmark Records.\n\nA small alcove of the Cache. Older pages live here. The Hollow lies through the inner door.",
        rotation_y=3.14159))

    # 3 lore signs
    props.append(sign([-4, 0, -2],
        "A short genealogy, freshly copied:\n\n\"...Wyrdking the Eighth, son of the Seventh, who shaped his own bones; the Last Wyrd, of whom no name remains.\"",
        rotation_y=1.5708))
    props.append(sign([4, 0, -2],
        "An old map of the Hollow, most of it faded. Only the entry chamber and a single inner room are still legible. The rest is a brown haze the ink could not hold.",
        rotation_y=-1.5708))
    props.append(sign([0, 0, -3],
        "A pinned warning, lettered carefully:\n\n\"Do not enter the Hollow without a Sigil-bearer's blessing. Do not enter alone. Do not enter without first reading what is here. — Recorder Thav\""))

    # 1 chest with fairy
    props.append(chest([3, 0, 0], "fairy",
        open_message="A glass vessel with a small bright thing inside. Recorder Thav left a note: \"For what is coming.\""))

    # 1 NPC
    props.append(npc("Recorder Thav", [-3, 0.5, 0],
        body_color=[0.4, 0.34, 0.55, 1.0],
        hat_color=[0.2, 0.16, 0.28, 1.0],
        idle_hint="[E] Speak with the Recorder",
        rotation_y=1.5708,
        dialog_tree=thav_dialog()))

    d["props"] = props


# ---- STACKS -------------------------------------------------------------

def nanre_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Master Archivist Nanre",
                "text": "Welcome to the Stacks, walker. Speak softly. What is here is here forever.",
                "choices": [
                    {"label": "What is kept here?",             "next": "kept"},
                    {"label": "Why permanent memory?",          "next": "why"},
                    {"label": "What of the Cache, then?",       "next": "cache"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "kept": {
                "speaker": "Master Archivist Nanre",
                "text": "What Lirien herself agreed should remain. Names of the founders. The shape of the Triglyph. The first inscriptions. Things that, if forgotten, would unmake the Wyrdmark.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "why": {
                "speaker": "Master Archivist Nanre",
                "text": "Because the Source remembers what is held. If the Wyrdkin forget, the Source thins where the memory used to be. The Stacks are the ballast under our walking.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "cache": {
                "speaker": "Master Archivist Nanre",
                "text": "The Cache holds what may be lost. The Stacks hold what may not. Curator Meld and I argue, gently, about which of us has the harder craft.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Master Archivist Nanre",
                "text": "Walk well. Read in the right order. Lirien sees the readers.",
            },
        },
    }


def rilin_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Younger Archivist Rilin",
                "text": "Please — softer steps. I am minding the inscriptions on the east wall, and the dust here is centuries old.",
                "choices": [
                    {"label": "What are the three signs?",      "next": "signs"},
                    {"label": "How is it studying with Nanre?", "next": "nanre"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "signs": {
                "speaker": "Younger Archivist Rilin",
                "text": "An old saying, broken into three pieces and laid in three places. A reader's test. Find them, read them in order, and the saying becomes whole. The first is at the front. The third is at the back.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "nanre": {
                "speaker": "Younger Archivist Rilin",
                "text": "Like studying with the wall itself. Nanre says nothing for a long time, and then a single thing that you remember for a year. I am two years in. I have remembered three things.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Younger Archivist Rilin",
                "text": "Walk well. Read in order, if you would.",
            },
        },
    }


def populate_stacks(d):
    # 15 cool blue-white lamp lights
    cool = [0.85, 0.88, 0.95, 1.0]
    lights = []
    for p in [
        [-12, 3.0, -12], [-12, 3.0, 0], [-12, 3.0, 12],
        [12, 3.0, -12], [12, 3.0, 0], [12, 3.0, 12],
        [0, 3.0, -12], [0, 3.0, 0], [0, 3.0, 12],
        [-6, 3.0, -6], [6, 3.0, -6], [-6, 3.0, 6], [6, 3.0, 6],
        [-12, 3.0, 6], [12, 3.0, 6],
    ]:
        lights.append(light(p, cool, energy=0.7, rng=8.0))
    d["lights"] = lights

    d["enemies"] = []

    props = []
    # Replace placeholder sign with arrival sign
    props.append(sign([0, 0, 12],
        "The Stacks.\n\nWhat the Library keeps forever. Speak softly. Read in order.",
        rotation_y=3.14159))

    # The 3-sign puzzle
    # Sign #1 — front (south)
    props.append(sign([-6, 0, 10],
        "Sign 1 — \"The first reading is the eye that finds the page...\"",
        rotation_y=3.14159))
    # Sign #2 — middle
    props.append(sign([6, 0, 0],
        "Sign 2 — \"...the second reading is the breath that holds it open...\"",
        rotation_y=-1.5708))
    # Sign #3 — back (north), with chest near it
    props.append(sign([-2, 0, -10],
        "Sign 3 — \"...and the third reading is the hand that carries it home.\"",
        rotation_y=0.0))

    # Heart-piece chest near sign #3
    props.append(chest([2, 0, -10], "heart",
        open_message="You have read in the right order. Lirien sees the readers."))

    # Fairy bottle chest
    props.append(chest([-12, 0, -4], "fairy",
        open_message="A glass vessel. The Stacks keep one or two of these for the long readings."))

    # 5 additional lore signs
    props.append(sign([12, 0, -8],
        "An inscription cut deep into the wall:\n\n\"Here is kept what the Wyrdmark agreed to remember. Forgetting these things would thin the Source itself.\"",
        rotation_y=-1.5708))
    props.append(sign([-12, 0, 8],
        "A stone plaque, polished by centuries of touching:\n\n\"The names of the first walkers — Vael, Anth, and the third whose name is no longer spoken.\"",
        rotation_y=1.5708))
    props.append(sign([6, 0, -12],
        "A small wood plaque set into the floor:\n\n\"Master Archivist Tannen, who kept these stacks for sixty years and never raised her voice. Walk well.\""))
    props.append(sign([-6, 0, -12],
        "A folded cloth notice, weighted with a stone:\n\n\"Reading aloud is permitted in the Stacks if you are alone. If you are not alone, ask first. Most readings are gentle. Some are not.\""))
    props.append(sign([0, 0, 6],
        "A page set under glass:\n\n\"Lirien's eye is on the page when the page is opened. The reader is, briefly, also read.\""))

    # 6 bushes — small ferns in alcoves
    for bp in [[-14, 0, -14], [14, 0, -14], [-14, 0, 14], [14, 0, 14],
               [-8, 0, 0], [8, 0, 0]]:
        props.append(bush(bp))

    # 4 rocks
    for rp in [[-4, 0, -2], [4, 0, -2], [-2, 0, 6], [2, 0, -6]]:
        props.append(rock(rp))

    # NPCs
    props.append(npc("Master Archivist Nanre", [-3, 0.5, 4],
        body_color=[0.3, 0.3, 0.45, 1.0],
        hat_color=[0.15, 0.15, 0.25, 1.0],
        idle_hint="[E] Speak with the Master Archivist",
        rotation_y=1.0,
        dialog_tree=nanre_dialog()))
    props.append(npc("Younger Archivist Rilin", [3, 0.5, 4],
        body_color=[0.45, 0.5, 0.6, 1.0],
        hat_color=[0.22, 0.25, 0.32, 1.0],
        idle_hint="[E] Speak with Rilin",
        rotation_y=-1.0,
        dialog_tree=rilin_dialog()))

    d["props"] = props


# ---- LEDGER -------------------------------------------------------------

def vonn_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Senior Scribe Vonn",
                "text": "(He looks up from a scroll that runs off the desk and onto the floor.) Mm. A walker. What can the Ledger do for you?",
                "choices": [
                    {"label": "What is the Ledger?",            "next": "ledger"},
                    {"label": "How much do you write?",         "next": "volume"},
                    {"label": "Who else maintains this?",       "next": "who"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "ledger": {
                "speaker": "Senior Scribe Vonn",
                "text": "The running record of the realm. Every birth, every door opened, every shrine renewed, every un-quieted in the Murk. We copy what arrives. We do not write what is not given to us.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "volume": {
                "speaker": "Senior Scribe Vonn",
                "text": "Lirien's breath, walker — they never stop arriving. Every breath of every Wyrdkin, every footfall, every cooking pot. We keep only the ones the Hidden Choir marks. Even that is too many.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "who": {
                "speaker": "Senior Scribe Vonn",
                "text": "We scribes copy. The marking, the choosing of what to copy — that is older work, done by older voices. We do not see them. They leave the inscriptions on the desk overnight, in a hand none of us writes.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Senior Scribe Vonn",
                "text": "Walk well. If you do anything noteworthy, we will hear of it. Try not to make our scrolls any longer.",
            },
        },
    }


def hidden_choir_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "A grey Reader",
                "text": "Walker. You are scheduled. I have logged you. Pleased to meet you.",
                "choices": [
                    {"label": "Scheduled?",                     "next": "scheduled"},
                    {"label": "Logged?",                        "next": "logged"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "scheduled": {
                "speaker": "A grey Reader",
                "text": "(She looks at you with a precise small smile. She does not answer the question. She tilts her head a little, as though listening to something.) The Wyrdmark walks. We attend.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "logged": {
                "speaker": "A grey Reader",
                "text": "An old habit of speech. Forgive it. Some of the older Readers had the habit too. They worked here a long time.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "A grey Reader",
                "text": "Walk well, walker. We have your line.",
            },
        },
    }


def penn_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Scribe Penn",
                "text": "Hey — sorry, you startled me. Have you been in the realm lately? Have you noticed anything... I don't know. Strange?",
                "choices": [
                    {"label": "What do you mean?",              "next": "mean"},
                    {"label": "The breath, you said?",          "next": "breath"},
                    {"label": "I'll keep an eye out.",          "next": "bye"},
                ],
            },
            "mean": {
                "speaker": "Scribe Penn",
                "text": "The inscriptions arriving lately have been... uneven. Long days of nothing. Then a flood at once. The Senior Scribe says it's normal. I don't think it is.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "breath": {
                "speaker": "Scribe Penn",
                "text": "The breath has been odd. Walking out at dawn, sometimes the Source feels — held. As if Lirien were paying close attention to something else and not quite to us. Khorgaul's grip, maybe I'm imagining it.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Scribe Penn",
                "text": "Walk well. If you do see anything — come back and tell us. We'll write it down.",
            },
        },
    }


def populate_ledger(d):
    cool = [0.78, 0.82, 0.92, 1.0]
    lights = []
    for p in [
        [-12, 3.0, -12], [12, 3.0, -12], [-12, 3.0, 12], [12, 3.0, 12],
        [-12, 3.0, 0], [12, 3.0, 0], [0, 3.0, -12], [0, 3.0, 12],
        [-4, 3.0, 0], [4, 3.0, 0],
    ]:
        lights.append(light(p, cool, energy=0.7, rng=8.0))
    d["lights"] = lights

    # 2 wisp_hunter (aborted Hidden Choir processes)
    d["enemies"] = [
        enemy("wisp_hunter", [-8, 0.5, -6]),
        enemy("wisp_hunter", [8, 0.5, 6]),
    ]

    props = []
    # Replace placeholder sign
    props.append(sign([0, 0, 12],
        "The Ledger.\n\nThe running record of the realm. Speak softly — the scribes are listening for inscriptions.",
        rotation_y=3.14159))

    # 8 lore signs
    props.append(sign([-12, 0, -8],
        "A pinned snippet, recently inked:\n\n\"...the seventh wardstone in Sigilkeep dimmed at the third hour of the morning, and brightened at the fourth, with no walker seen near it.\"",
        rotation_y=-1.5708))
    props.append(sign([12, 0, -8],
        "A folded notice, weighted with a stone:\n\n\"NOTICE. An unusually large number of un-quieted appeared in the Murk last cycle. The Hidden Choir is consulted. Walkers are advised to keep to lit paths.\"",
        rotation_y=1.5708))
    props.append(sign([-12, 0, 6],
        "A wood plaque polished by hands:\n\n\"In memory of the Senior Scribes — Vael the elder, Anth the long-handed, Tarn who kept the longest scroll, and Pell the first.\"",
        rotation_y=-1.5708))
    props.append(sign([12, 0, 6],
        "A small inscription card:\n\n\"...and on the morning of the fourth thinning, the Source was held for the length of one breath, and three Readers fainted, and the realm continued.\"",
        rotation_y=1.5708))
    props.append(sign([-6, 0, -10],
        "A loose page held under a stone weight:\n\n\"...a child in Hearthold asked where her grandfather was buried. The Senior Scribe noted the question. The answer was not given.\""))
    props.append(sign([6, 0, -10],
        "A small marker pinned to a beam:\n\n\"Inscriptions from the Burnt Hollow have been arriving in a hand none of us writes. We copy them faithfully. We do not ask.\""))
    props.append(sign([-6, 0, 0],
        "A weather-stained note:\n\n\"...the rooks of Hearthold sang at first light, and the Source was full in the air, and a small walker passed under the gate. We marked the line. Walk well.\""))
    props.append(sign([6, 0, 0],
        "An old proclamation, framed:\n\n\"By the keepers of the Ledger: the running scroll shall not be cut. What is begun is recorded entire. Brevity is for kinder rooms.\""))

    # 3 chests
    props.append(chest([-10, 0, -4], "pebble", amount=10,
        open_message="A handful of small pebbles, set aside for some scribe's tally."))
    props.append(chest([10, 0, -4], "heart",
        open_message="A pressed heart-flower, the petals still soft. Whoever set this here did not write a note."))
    props.append(chest([0, 0, -8], "key", key_group="ledger",
        open_message="A small dark key. The Ledger keeps these for its inner cabinets."))

    # 5 bushes
    for bp in [[-14, 0, -14], [14, 0, -14], [-14, 0, 14], [14, 0, 14],
               [0, 0, 8]]:
        props.append(bush(bp))

    # 3 rocks
    for rp in [[-4, 0, 6], [4, 0, 6], [0, 0, -2]]:
        props.append(rock(rp))

    # NPCs
    props.append(npc("Senior Scribe Vonn", [-3, 0.5, 2],
        body_color=[0.4, 0.38, 0.35, 1.0],
        hat_color=[0.22, 0.20, 0.18, 1.0],
        idle_hint="[E] Speak with the Senior Scribe",
        rotation_y=0.5,
        dialog_tree=vonn_dialog()))
    props.append(npc("A grey Reader", [-12, 0.5, -2],
        body_color=[0.18, 0.18, 0.20, 1.0],
        hat_color=[0.10, 0.10, 0.12, 1.0],
        idle_hint="[E] Speak with the grey Reader",
        rotation_y=1.5708,
        dialog_tree=hidden_choir_dialog()))
    props.append(npc("Scribe Penn", [4, 0.5, 4],
        body_color=[0.55, 0.5, 0.42, 1.0],
        hat_color=[0.30, 0.27, 0.22, 1.0],
        idle_hint="[E] Speak with Penn",
        rotation_y=-1.0,
        dialog_tree=penn_dialog()))

    d["props"] = props


# ---- BACKWATER ----------------------------------------------------------

def wenn_dialog():
    return {
        "start": "root",
        "nodes": {
            "root": {
                "speaker": "Sluice-keeper Wenn",
                "text": "Mind your boots, walker. The buffer's full again. I dredged it yesterday. It does not stay clean. It never has.",
                "choices": [
                    {"label": "What flows here?",               "next": "flows"},
                    {"label": "Why doesn't it stay clean?",     "next": "clean"},
                    {"label": "Where does the stream go?",      "next": "downstream"},
                    {"label": "Walk well.",                     "next": "bye"},
                ],
            },
            "flows": {
                "speaker": "Sluice-keeper Wenn",
                "text": "What the Library could not file fast enough. What the Cache forgot. What the Ledger ran out of scroll for. It all comes here, and from here it goes downstream. Down to the Mire.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "clean": {
                "speaker": "Sluice-keeper Wenn",
                "text": "The realm makes more than the realm can keep. That is the whole of it. The buffer overflows. I dredge. The Source sighs. The Mire downstream gets worse every year.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "downstream": {
                "speaker": "Sluice-keeper Wenn",
                "text": "Mirelake. A brackish lake. People walk down there and sometimes they do not walk back. Khorgaul's grip is stronger in the wet places. Mind yourself if you go.",
                "choices": [
                    {"label": "Back.",                          "next": "root"},
                ],
            },
            "bye": {
                "speaker": "Sluice-keeper Wenn",
                "text": "Walk well. Dry feet, if you can manage it. I never can.",
            },
        },
    }


def populate_backwater(d):
    cool_mist = [0.6, 0.75, 0.85, 1.0]
    lights = [
        light([-4, 3.0, -4], cool_mist, energy=0.5, rng=7.0),
        light([ 4, 3.0, -4], cool_mist, energy=0.5, rng=7.0),
        light([-4, 3.0,  4], cool_mist, energy=0.5, rng=7.0),
        light([ 4, 3.0,  4], cool_mist, energy=0.5, rng=7.0),
        light([ 0, 3.0,  0], cool_mist, energy=0.5, rng=7.0),
        light([ 0, 3.0, -3], cool_mist, energy=0.5, rng=7.0),
    ]
    d["lights"] = lights

    # 3 spore drifters in wet pockets
    d["enemies"] = [
        enemy("spore", [-3, 0.5, -1]),
        enemy("spore", [ 3, 0.5,  1]),
        enemy("spore", [ 0, 0.5,  3]),
    ]

    props = []
    # Replace placeholder sign
    props.append(sign([0, 0, 2],
        "The Backwater.\n\nWhere the buffer overflows. Wet feet. The stream runs on toward Mirelake.",
        rotation_y=3.14159))

    # 3 atmospheric signs
    props.append(sign([-4, 0, -2],
        "A weather-stained warning, half-legible:\n\n\"OVERFLOW. The buffer is not a path. Step where it is dry, or do not step at all.\"",
        rotation_y=1.5708))
    props.append(sign([4, 0, -2],
        "A small wood marker driven into the bank:\n\n\"In memory of those who walked downstream and did not walk back. We do not list them. They were known.\"",
        rotation_y=-1.5708))
    props.append(sign([0, 0, 3],
        "A loose hand-painted board, leaning against a reed:\n\n\"Mirelake lies down the stream. The water gets darker. The names of things get fewer. Mind yourself, walker.\"",
        rotation_y=3.14159))

    # 1 chest near the Mirelake load_zone (which is at z=4)
    props.append(chest([2, 0, 3], "fairy",
        open_message="A glass vessel. Sluice-keeper Wenn left a small note: \"For the wet road.\""))

    # 4 reed bushes
    for bp in [[-4, 0, 0], [4, 0, 0], [-2, 0, 2], [2, 0, -2]]:
        props.append(bush(bp))

    # 3 rocks
    for rp in [[-3, 0, 1], [3, 0, -1], [0, 0, 1]]:
        props.append(rock(rp))

    # 1 NPC
    props.append(npc("Sluice-keeper Wenn", [-2, 0.5, -1],
        body_color=[0.35, 0.45, 0.4, 1.0],
        hat_color=[0.18, 0.22, 0.20, 1.0],
        idle_hint="[E] Speak with the Sluice-keeper",
        rotation_y=1.0,
        dialog_tree=wenn_dialog()))

    d["props"] = props


# ---- main ---------------------------------------------------------------

POPULATORS = {
    "library":         populate_library,
    "cache":           populate_cache,
    "cache_wyrdmark":  populate_cache_wyrdmark,
    "stacks":          populate_stacks,
    "ledger":          populate_ledger,
    "backwater":       populate_backwater,
}


def main():
    for name, fn in POPULATORS.items():
        path = os.path.join(DUNGEONS, name + ".json")
        with open(path) as f:
            d = json.load(f)
        fn(d)
        with open(path, "w") as f:
            json.dump(d, f, indent=2)
        print("populated", name)


if __name__ == "__main__":
    main()
