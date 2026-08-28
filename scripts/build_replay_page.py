#!/usr/bin/env python3
"""Re-derive the INHERITED head of client/replay_broadcast.html from the
coworld-ctf starter's page, so the inheritance can be diffed rather than
taken on trust.

The rule (coworld-builder playbooks/make-coworld.md, design note §Viewer ->
Chrome provenance): the page is the STARTER'S page with a game block appended,
never a rewrite that reuses its ids. This script is the audit trail for that.
It takes the starter's bytes, deletes exactly the elements and CSS rules the
design note lists as removed, and applies the enumerated label re-mappings.

It does NOT write client/replay_broadcast.html: that file is committed, it
carries the appended SNAKE-ROYALE block, and CI never regenerates it. What
this writes is the mechanically-derived head plus the starter chunks the block
was spliced around, into a SCRATCH directory, for a reviewer to diff:

  python3 scripts/build_replay_page.py [starter-root] [out-dir]
    -> <out>/_head_markup.html          the derived inherited head
    -> <out>/_chunk_<name>.js           the starter chunks, by name

  diff <(head -c "$(wc -c < <out>/_head_markup.html)" \
           client/replay_broadcast.html) <out>/_head_markup.html

Defaults: starter-root /workspace/starters/coworld-ctf, out-dir
dist/replay-page-provenance. Nothing is written under client/.
"""

import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

# Every id and class the design note §Viewer -> Chrome provenance lists as
# removed. #viewpanel goes ENTIRELY (zoom bar + minimap): all three boards are
# small fixed rectangles with no off-frame area, so relayout() letterboxes each
# whole at every width and there is nothing to pan to.
CSS_DROP = re.compile(
    r"#viewpanel|#minimap|#zoombar|#zoom-|\.zbtn|\.mm-cap"
    r"|#fpv|\.fpv-|#povBadge"
    r"|\.hillchip|\.hcap|\.flagicon|\.lives-num|\.lives-label"
    r"|\.squad-pip|\.pb-tags|\.squad\b|\.ec-heart"
    r"|\.beat-marker\.kill|\.beat-marker\.steal|\.beat-marker\.return"
    r"|\.beat-marker\.capture|\.beat-marker\.hillflip|\.beat-marker\.tagout"
    r"|\.beat-marker\.gamestart"
    r"|\.perk-badge|\.handicap|\.perkicon"
)

MARKUP_DROP_IDS = ["viewpanel", "povBadge", "fpv"]

# The enumerated re-labelings (design note §Endcard and chrome label
# re-mapping). A forked ctf endcard otherwise ships paintbot's vocabulary and
# nothing in the starter's tests covers spectator chrome strings.
RELABEL = [
    ("Filling hoppers with fresh paint&hellip;", "Coiling up&hellip;"),
    ("In the locker room", "Before the first move"),
    ("Replay hash mismatch &mdash; showing recorded inputs",
     "Replay hash mismatch — showing recorded moves"),
    ("Replay hash mismatch — showing recorded inputs",
     "Replay hash mismatch — showing recorded moves"),
    ("kills / flag story / winner on the timeline ahead of the playhead (o)",
     "deaths / head-ons / winner on the timeline ahead of the playhead (o)"),
    ("LIVES LEAD", "LENGTH"),
    ("Ctf &mdash; Broadcast Replay", "Snake Royale — Broadcast Replay"),
    ("Ctf — Broadcast Replay", "Snake Royale — Broadcast Replay"),
    ("Bot locker room &middot; Loading replay",
     "Snake pit &middot; Loading replay"),
]


def strip_css(style: str) -> str:
    """Drop every top-level rule whose selector names a removed element."""
    out = []
    i = 0
    n = len(style)
    while i < n:
        brace = style.find("{", i)
        if brace < 0:
            out.append(style[i:])
            break
        # at-rules with nested blocks (@media, @keyframes, @font-face)
        head = style[i:brace]
        depth = 0
        j = brace
        while j < n:
            if style[j] == "{":
                depth += 1
            elif style[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        block = style[i:j + 1]
        selector = head.strip()
        if selector.startswith("@media"):
            inner = block[block.index("{") + 1:block.rindex("}")]
            block = head + "{" + strip_css(inner) + "}"
            out.append(block)
        elif CSS_DROP.search(selector):
            pass                      # removed with its element
        else:
            out.append(block)
        i = j + 1
    return "".join(out)


def drop_element(markup: str, element_id: str) -> str:
    """Remove the <div id="..."> ... </div> subtree, comments included."""
    marker = 'id="%s"' % element_id
    at = markup.find(marker)
    if at < 0:
        return markup
    start = markup.rfind("<div", 0, at)
    # swallow the comment block immediately above it, if any
    comment_end = markup.rfind("-->", 0, start)
    if comment_end >= 0 and markup[comment_end + 3:start].strip() == "":
        comment_start = markup.rfind("<!--", 0, comment_end)
        if comment_start >= 0:
            start = comment_start
    depth = 0
    i = start
    while i < len(markup):
        if markup.startswith("<div", i):
            depth += 1
            i += 4
            continue
        if markup.startswith("</div>", i):
            depth -= 1
            i += 6
            if depth == 0:
                break
            continue
        i += 1
    return markup[:start] + markup[i:]


def lines(text, first, last):
    """Starter lines [first, last], 1-indexed inclusive."""
    return "\n".join(text.split("\n")[first - 1:last])


def main():
    starter_root = sys.argv[1] if len(sys.argv) > 1 else "/workspace/starters/coworld-ctf"
    out_dir = (sys.argv[2] if len(sys.argv) > 2
               else os.path.join(ROOT, "dist", "replay-page-provenance"))
    os.makedirs(out_dir, exist_ok=True)
    src = open(os.path.join(starter_root, "client",
                            "replay_broadcast.html")).read()

    head_markup = lines(src, 1, 1604)
    style_open = head_markup.index("<style>") + len("<style>")
    style_close = head_markup.index("</style>")
    head_markup = (head_markup[:style_open] +
                   strip_css(head_markup[style_open:style_close]) +
                   head_markup[style_close:])
    for element_id in MARKUP_DROP_IDS:
        head_markup = drop_element(head_markup, element_id)
    for old, new in RELABEL:
        head_markup = head_markup.replace(old, new)

    chunks = {
        "aliases": lines(src, 1606, 1639),
        "tempo": lines(src, 1704, 1739),
        "dollars": lines(src, 1740, 1744),
        "locker": lines(src, 1746, 1863),
        "embed": lines(src, 1865, 1920),
        "feed_banner": lines(src, 3555, 3605),
        "transport": lines(src, 3919, 3952),
        "relayout": lines(src, 4270, 4324),
    }
    for name, text in chunks.items():
        open(os.path.join(out_dir, "_chunk_%s.js" % name), "w").write(text)

    head_path = os.path.join(out_dir, "_head_markup.html")
    open(head_path, "w").write(head_markup)
    print("wrote %s and %d starter chunks" % (head_path, len(chunks)))
    print("diff the inheritance with:")
    print("  diff <(head -c %d client/replay_broadcast.html) %s"
          % (len(head_markup), head_path))


if __name__ == "__main__":
    main()
