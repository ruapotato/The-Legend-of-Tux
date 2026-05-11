#!/usr/bin/env python3
"""One-shot content injector for the 10 canonical-Unix sub-dirs added
in the latest content pass. Adds NPCs, signs, and chests with themed
dialog to each of:

  hearthold_desktop / hearthold_downloads
  wyrdkin_config / wyrdkin_cache / wyrdkin_bash_history
  etc_hosts / etc_motd / etc_fstab
  var_log_syslog / tmp_x11_unix

Idempotent on prop type+name+message — won't duplicate.

Run AFTER scaffold_directory.py, BEFORE grow_filesystem.py. The rooting
algorithm rebinds props to the nearest walking cell, so authored
positions only need to be roughly inside the scaffolded footprint.
"""

import json
import os

ROOT     = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUNGEONS = os.path.join(ROOT, "dungeons")


def npc(name, pos, body_color, hat_color, dialog_nodes,
        start="root", idle_hint="[E] Speak"):
    """Build an NPC prop dict with a small dialog tree.

    `dialog_nodes` is an ordered list of (key, text, [(label, next)]).
    The last node has no choices unless explicitly given. A `next` of
    None ends the conversation.
    """
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


def chest(pos, contents, msg, requires_flag=None):
    d = {
        "type": "chest",
        "pos": list(pos),
        "rotation_y": 0.0,
        "contents": contents,
        "open_message": msg,
    }
    if requires_flag:
        d["requires_flag"] = requires_flag
    return d


# ---------------------------------------------------------------------------
# Per-directory props
# ---------------------------------------------------------------------------

CONTENT = {}

# --- /home/hearthold/Desktop -----------------------------------------------
CONTENT["hearthold_desktop"] = [
    # Quick-Launch Apprentice — points to other rooms.
    npc("Quick-Launch Apprentice", (-3, 0, -1),
        (0.78, 0.85, 0.95, 1.0), (0.55, 0.45, 0.78, 1.0),
        [
            ("root",
             "Oh, hello! You look like you came in from outside.\n"
             "Need a quick jump anywhere? I keep the shortcuts.",
             [("Where do the shopkeepers live?", "shops"),
              ("Where do I drop things off?", "drops"),
              ("Just looking.", None)]),
            ("shops",
             "Binds, in the Sprawl. That's `/usr/bin` — every named\n"
             "tool-spirit you'll ever want stocks a stall there. Apt,\n"
             "Pacman, Tar. They sell `+x` bits.",
             [("Thanks.", None)]),
            ("drops",
             "Downloads, next door. Tem is in charge. She has not yet\n"
             "looked at any of it.",
             [("Got it.", None)]),
        ],
        idle_hint="[E] Ask about shortcuts"),
    # Reminder Sticky-Note — humble Wyrdkin who repeats reminders.
    npc("Reminder Sticky-Note", (3, 0, -1),
        (0.95, 0.92, 0.55, 1.0), (1.0, 0.85, 0.45, 1.0),
        [
            ("root",
             "PICK UP MILK. PICK UP MILK. PICK UP MILK.\n"
             "...oh. Hello.",
             [("What are you doing?", "job"),
              ("Walk well.", None)]),
            ("job",
             "I am the day's reminder. One line, repeated until it is\n"
             "either done or forgotten. Today's line: pick up milk.",
             [("Whose milk?", "whose")]),
            ("whose",
             "I have never asked. That is not in my job description.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Read the sticky-note"),
    sign((0, 0, 4),
         "Desktop —\n\nWhat's in front of you, not what's filed away."),
    sign((-2, 0, 4),
         "A long low table dominates the room.\n\n"
         "Tools sit on it where someone put them down: a kettle, a\n"
         "ledger, a half-folded letter, a key with no chain."),
    sign((4, 0, 3),
         "Trash can sits in the corner, full.\n\n"
         "Nobody empties it. Nobody asks who should."),
    sign((-4, 0, 3),
         "A glass of water, half-drunk.\n\n"
         "It has been here since this morning. Perhaps yesterday morning."),
]

# --- /home/hearthold/Downloads ----------------------------------------------
CONTENT["hearthold_downloads"] = [
    npc("Tem the Hoarder", (0, 0, 0),
        (0.62, 0.45, 0.30, 1.0), (0.45, 0.30, 0.20, 1.0),
        [
            ("root",
             "Oh, friend, you've come at a busy time. I'm sorting.\n"
             "Or I'm about to sort. I've been about to sort for a while.",
             [("What are these chests?", "chests"),
              ("Why so many?", "why"),
              ("Walk well.", None)]),
            ("chests",
             "Things I asked for and meant to look at. Some of them I\n"
             "remember asking for. Most I do not.",
             [("Can I open them?", "open")]),
            ("open",
             "Please. If something rolls out and you can use it,\n"
             "it's yours. That's how it should work, isn't it.",
             [("Walk well.", None)]),
            ("why",
             "Have you ever clicked something and then walked away\n"
             "before it finished? I have done that for a lifetime.",
             [("...", None)]),
        ],
        idle_hint="[E] Speak with Tem"),
    # 5 chests of small contents.
    chest((-4, 0, -3), "pebble", "A small pile of pebbles. Tem doesn't remember asking for these."),
    chest((-2, 0, -3), "seed", "A few seeds in a paper twist. Probably still good."),
    chest((2, 0, -3),  "arrow", "Three arrows. The label says they were a recommendation."),
    chest((4, 0, -3),  "pebble", "More pebbles. A truly inexplicable amount of pebbles."),
    chest((0, 0, -4),  "pebble", "Pebbles. Always pebbles."),
    sign((-4, 0, 3),
         "Downloads —\n\nThings asked for, not yet opened."),
    sign((4, 0, 3),
         "Almost no one looks twice.\n\n"
         "When was the last time you read a thing you saved?"),
    sign((0, 0, 4),
         "A spider has built a web across one of the chests.\n\n"
         "Tem refuses to disturb it. \"It got here first.\""),
]

# --- /home/wyrdkin/.config ---------------------------------------------------
CONTENT["wyrdkin_config"] = [
    npc("Config Steward", (0, 0, 0),
        (0.78, 0.72, 0.85, 1.0), (0.55, 0.45, 0.62, 1.0),
        [
            ("root",
             "Welcome to the small ritual room. I tend the\n"
             "configurations. Would you like me to tune your shield?",
             [("How much?", "price"),
              ("What does it do?", "what"),
              ("Walk well.", None)]),
            ("price",
             "Five pebbles. A reasonable trade for a brief grace.\n"
             "The grace lasts until you change rooms.",
             [("Done.", "buy"),
              ("Maybe later.", None)]),
            ("buy",
             "Hold still. ...there. Your shield holds a little\n"
             "stronger now. Walk well.",
             [("Thank you.", None)]),
            ("what",
             "Your shield, briefly stronger. A small thing. The kind\n"
             "of small thing that happens here.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak with the Steward"),
    sign((-3, 0, -1),
         ".bashrc — read on every login.\n\n"
         "Every time you wake into this hold, this is the first\n"
         "thing the kin recite over you."),
    sign((0, 0, -2),
         ".inputrc — your keys.\n\n"
         "How your hands answer the world. Edit it gently."),
    sign((3, 0, -1),
         ".vimrc — your edits.\n\n"
         "What you change of yourself before you start changing\n"
         "anything else."),
    sign((0, 0, 4),
         "A curtain hangs across the doorway, ash-grey.\n\n"
         "The room behind it is quiet. The Wyrdkin step in here\n"
         "and step out a little different."),
]

# --- /home/wyrdkin/.cache ----------------------------------------------------
CONTENT["wyrdkin_cache"] = [
    npc("Cache Pantry-Keeper", (0, 0, 0),
        (0.62, 0.62, 0.55, 1.0), (0.45, 0.42, 0.35, 1.0),
        [
            ("root",
             "Mind your step. The shelves remember being full.\n"
             "Most of what's here is from yesterday. Some is older.",
             [("Is any of it good?", "good"),
              ("Why keep it?", "keep"),
              ("Walk well.", None)]),
            ("good",
             "Stale, but here. That's not nothing. Some days a stale\n"
             "thing close at hand is better than a fresh thing far away.",
             [("Walk well.", None)]),
            ("keep",
             "It costs nothing to keep, mostly. And clearing takes\n"
             "the kind of attention I don't always have.\n"
             "`rm -rf ~/.cache` — safe to clear, they say.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak to the Keeper"),
    sign((-3, 0, -1),
         "`rm -rf ~/.cache` — safe to clear.\n\n"
         "The kin repeat this like a prayer. Nobody ever does it."),
    sign((3, 0, -1),
         "A shelf of jars labelled by date.\n\n"
         "The newest is a week old. The oldest predates the\n"
         "Drawing-In."),
    sign((0, 0, 4),
         "Damp stone underfoot. The air smells like an offering\nleft out too long."),
    chest((0, 0, -3), "pebble", "Five pebbles. Worth keeping, for a little while."),
]

# --- /home/wyrdkin/.bash_history --------------------------------------------
# Long thin hall of carved-tablet signs along the walls.
CONTENT["wyrdkin_bash_history"] = [
    npc("The Reader of Lines", (0, 0, 0),
        (0.85, 0.85, 0.92, 1.0), (0.45, 0.42, 0.55, 1.0),
        [
            ("root",
             "Everything you have spoken, written down. I read it\n"
             "back when the hold is quiet.",
             [("Everything?", "all"),
              ("Even the mistakes?", "mistakes"),
              ("Walk well.", None)]),
            ("all",
             "Every command, in order. Some of these tablets are\n"
             "older than the kin who first carved them.",
             [("Walk well.", None)]),
            ("mistakes",
             "Especially the mistakes. The mistakes are how we know\n"
             "what we meant.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Listen to the Reader"),
    # Tablets along the walls.
    sign((-4, 0, -3), "Tablet carved deep:\n\n`ls`"),
    sign((-2, 0, -3), "Tablet carved shallow:\n\n`cd ..`"),
    sign((0, 0, -3),  "Tablet carved twice:\n\n`kill PID4321`"),
    sign((2, 0, -3),  "Tablet carved by a steady hand:\n\n`sudo apt update`"),
    sign((4, 0, -3),  "Tablet carved by a tired hand:\n\n`make`"),
    sign((-4, 0, 3),  "Tablet carved with corrections:\n\n`vim .bashrc`"),
    sign((-2, 0, 3),  "Tablet carved recently:\n\n`git status`"),
    sign((0, 0, 3),   "Tablet near a small disturbed crater in the floor:\n\n`rm -rf node_modules`"),
    sign((2, 0, 3),   "Tablet carved like a question:\n\n`history | grep wyrd`"),
    sign((4, 0, 3),
         "A long thin hall. The tablets continue past where you can see.\n\n"
         "Every command Tux has ever spoken. Walls of text."),
]

# --- /etc/hosts --------------------------------------------------------------
CONTENT["etc_hosts"] = [
    npc("Scribe Onel", (0, 0, 0),
        (0.85, 0.82, 0.78, 1.0), (0.55, 0.50, 0.45, 1.0),
        [
            ("root",
             "I am Onel of the scribe family. I keep the table of names.\n"
             "Every name that means a place. Every place that has a name.",
             [("How does it work?", "how"),
              ("Who is `the_oldest_one`?", "old"),
              ("Walk well.", None)]),
            ("how",
             "A name on the left. Four glyphs on the right. The glyphs\n"
             "point at a place. The place answers when you call the name.",
             [("Walk well.", None)]),
            ("old",
             "I do not know. I only copy what was given me. The address\n"
             "is `10.0.0.42`. The name has been on the tablet since before\n"
             "my grandfather sat at this desk.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Ask the scribe"),
    sign((0, 0, -3),
         "A stone tablet, the wall it leans against:\n\n"
         "127.0.0.1  localhost\n"
         "::1        localhost\n"
         "192.168.1.1  router\n"
         "10.0.0.42  the_oldest_one"),
    sign((-3, 0, 2),
         "Names mapped to places.\n\n"
         "The scribes say this is the only wall in the realm where\n"
         "everything is true at once."),
    sign((3, 0, 2),
         "A second smaller tablet, half-finished:\n\n"
         "0.0.0.0  nowhere\n"
         "255.255.255.255  everywhere\n"
         "                                  — someone's joke?"),
]

# --- /etc/motd ---------------------------------------------------------------
CONTENT["etc_motd"] = [
    npc("Crier of the Day", (0, 0, 0),
        (0.92, 0.85, 0.62, 1.0), (0.78, 0.55, 0.32, 1.0),
        [
            ("root",
             "Today's notice. Hear ye:\n\n"
             "\"Welcome to the Wyrdmark. Watch your step.\"",
             [("Read me another one.", "two"),
              ("Walk well.", None)]),
            ("two",
             "\"Maintenance window: never. The realm has been up since\n"
             "anyone can remember and will be up tomorrow.\"",
             [("And another?", "three"),
              ("Walk well.", None)]),
            ("three",
             "\"Today is a good day to whistle.\"",
             [("One more?", "four"),
              ("Walk well.", None)]),
            ("four",
             "\"The realm thanks you for your trust.\"\n\n"
             "That's all I have today. The board only takes four.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Hear the day's notice"),
    sign((0, 0, -3),
         "A banner stretches overhead, freshly painted:\n\n"
         "\"Welcome to the Wyrdmark. Watch your step.\""),
    sign((-3, 0, 2),
         "Message of the Day —\n\n"
         "Read once on entry. Replaced at dawn. The day's word, no more."),
    sign((3, 0, 2),
         "A small ledger of past banners hangs by the door.\n\n"
         "Yesterday: \"Mind the kettle.\"\n"
         "The day before: \"It is raining somewhere. Take a kindness.\""),
]

# --- /etc/fstab --------------------------------------------------------------
CONTENT["etc_fstab"] = [
    npc("Mounter Vest", (0, 0, 0),
        (0.55, 0.62, 0.78, 1.0), (0.32, 0.42, 0.55, 1.0),
        [
            ("root",
             "I keep the table of attachments. Every path to every place\n"
             "that hangs off the trunk of the realm.",
             [("What's `auto`?", "auto"),
              ("What's `noatime`?", "noatime"),
              ("Walk well.", None)]),
            ("auto",
             "It means the place attaches itself when the realm wakes.\n"
             "You don't have to ask. You don't have to remember.",
             [("Walk well.", None)]),
            ("noatime",
             "It means the place doesn't write down when you last\n"
             "visited. Some things are gentler that way.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Speak with the Mounter"),
    sign((-4, 0, -3),
         "Scrolled across the wall:\n\n"
         "/dev/sda1   /          ext4   defaults  0 1"),
    sign((-2, 0, -3),
         "/dev/sda2   /home      ext4   defaults  0 2"),
    sign((0, 0, -3),
         "/dev/sda3   /var       ext4   noatime   0 2"),
    sign((2, 0, -3),
         "tmpfs       /tmp       tmpfs  defaults  0 0"),
    sign((4, 0, -3),
         "proc        /proc      proc   defaults  0 0"),
    sign((0, 0, 4),
         "Six mounts. Every place attached, every place auto.\n\n"
         "Vest is proud of the auto column."),
]

# --- /var/log/syslog ---------------------------------------------------------
CONTENT["var_log_syslog"] = [
    npc("Syslog Keeper", (0, 0, 0),
        (0.62, 0.55, 0.62, 1.0), (0.42, 0.35, 0.42, 1.0),
        [
            ("root",
             "I am the Syslog Keeper. I read what just happened.\n\n"
             "Most recent: `[INFO] tux logged in`.",
             [("Read me an older one.", "warn"),
              ("Walk well.", None)]),
            ("warn",
             "`[WARN] Wyrdking memory low`.\n\n"
             "We're not sure what that meant. The Wyrdking did not say.",
             [("Another?", "err"),
              ("Walk well.", None)]),
            ("err",
             "`[ERROR] segfault in /dev/forge`.\n\n"
             "Something fell over in the Forge. Something always is.",
             [("One more.", "cron"),
              ("Walk well.", None)]),
            ("cron",
             "`[INFO] cron job at midnight succeeded`.\n\n"
             "Glim flickers when I read that one. I have not asked\n"
             "Glim why.",
             [("Walk well.", None)]),
        ],
        idle_hint="[E] Hear the latest entry"),
    sign((-3, 0, -3),
         "Running scroll, left wall:\n\n"
         "`[INFO] tux logged in`\n"
         "`[INFO] cd /opt/wyrdmark/glade`\n"
         "`[INFO] entered scene wyrdkin_glade`"),
    sign((3, 0, -3),
         "Running scroll, right wall:\n\n"
         "`[WARN] Wyrdking memory low`\n"
         "`[INFO] cron job at midnight succeeded`\n"
         "`[ERROR] segfault in /dev/forge`"),
    sign((0, 0, 4),
         "Records what happens, not what should.\n\n"
         "The Keeper says this often. The Keeper is correct."),
    chest((0, 0, -3), "heart_piece",
          "Tucked behind a long scroll — a Heart Piece. The Keeper\n"
          "doesn't recall when it appeared in the log.",
          requires_flag="triglyph_assembled"),
]

# --- /tmp/.X11-unix ----------------------------------------------------------
CONTENT["tmp_x11_unix"] = [
    npc("X-spirit (one)", (-2, 0, 0),
        (0.78, 0.55, 0.85, 1.0), (0.55, 0.30, 0.62, 1.0),
        [
            ("root",
             "Server gone.",
             [("...where?", "where"),
              ("Walk well.", None)]),
            ("where",
             "Not listening. DISPLAY — set, but —",
             [("...", None)]),
        ],
        idle_hint="[E] Wave at the X-spirit"),
    npc("X-spirit (two)", (2, 0, 0),
        (0.55, 0.85, 0.78, 1.0), (0.30, 0.62, 0.55, 1.0),
        [
            ("root",
             "Server lost.",
             [("Is anyone listening?", "no"),
              ("Walk well.", None)]),
            ("no",
             ":0 — nothing on :0. Try :1. Try :1. Try :1.",
             [("...", None)]),
        ],
        idle_hint="[E] Wave at the other X-spirit"),
    sign((0, 0, -3),
         "DISPLAY=:0\n\n"
         "But :0 is not listening."),
    sign((-3, 0, 3),
         "Fragments of display-protocol hover, glowing.\n\n"
         "They drift slowly. They almost form a picture, then don't."),
    sign((3, 0, 3),
         "Two confused user-spirits stand near the door.\n\n"
         "They have been here a long time. They will be here longer."),
]


# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

def already_has(props, kind, name=None, message=None):
    for p in props:
        if p.get("type") != kind:
            continue
        if name is not None and p.get("name") == name:
            return True
        if message is not None and p.get("message") == message:
            return True
    return False


def apply_to_level(level_id, new_props):
    path = os.path.join(DUNGEONS, level_id + ".json")
    if not os.path.exists(path):
        print("missing %s; skipping" % level_id)
        return 0
    with open(path) as f:
        data = json.load(f)
    props = data.get("props", [])

    # Strip the default "<Name>\n\n/fs/path" placeholder sign from the
    # scaffolder so we don't duplicate a path sign on top of authored
    # content. Identify it by the exact placeholder shape.
    placeholder = "%s\n\n%s" % (data.get("name", ""), data.get("fs_path", ""))
    props = [p for p in props
             if not (p.get("type") == "sign"
                     and p.get("message") == placeholder)]

    added = 0
    for p in new_props:
        kind = p.get("type")
        if kind == "npc":
            if already_has(props, "npc", name=p.get("name")):
                continue
        elif kind == "sign":
            if already_has(props, "sign", message=p.get("message")):
                continue
        elif kind == "chest":
            if already_has(props, "chest", message=p.get("open_message")):
                continue
        props.append(p)
        added += 1

    data["props"] = props
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    return added


def main():
    total = 0
    for lid, new_props in CONTENT.items():
        n = apply_to_level(lid, new_props)
        total += n
        print("%-24s + %d props" % (lid, n))
    print("\ntotal props added: %d" % total)


if __name__ == "__main__":
    main()
