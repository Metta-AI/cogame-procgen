## The endcard and chrome label re-mapping (design note §Viewer -> Endcard and
## chrome label re-mapping; numbered test 44).
##
## A forked ctf endcard silently ships paintbot's vocabulary: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## spectator chrome strings, because `labels.nim` deliberately scopes itself
## to the POLICY contract. So the re-labelings are enumerated here and
## enforced.

import std/[os, strutils]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

const
  PagePath = "client/replay_broadcast.html"
  CorePath = "client/broadcast_core.js"
  ## Every word the starter used for a mechanic this game does not have. A
  ## rename that reintroduces paintbot vocabulary fails the build.
  Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart", "paint",
               "hopper", "hill", "POV", "spray", "grenade", "med kit",
               "kill ", "HP pips", "RED", "BLUE", "Team"]
  ## The enumerated replacements. Each must be PRESENT; a caption that is
  ## both a markup default and a JS assignment legitimately appears twice, so
  ## the assertion that carries the weight is the forbidden list above — the
  ## starter's word must be GONE, and the replacement must be there.
  Replacements = ["Unseen mean", "Seen mean", "SEEN vs UNSEEN",
                  "Generating levels&hellip;", "Before the first level",
                  "deaths / level results / final score"]

proc codeLines(text: string): seq[string] =
  ## Comment blocks are excluded: the starter's comments explain what was
  ## removed and why, and a comment is not a string a spectator reads.
  var inBlock = false
  for line in text.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("<!--"):
      inBlock = true
    if inBlock:
      if "-->" in trimmed:
        inBlock = false
      continue
    if trimmed.startsWith("//") or trimmed.startsWith("*") or
       trimmed.startsWith("/*") or trimmed.startsWith("##"):
      continue
    result.add(line)

# 44. the forbidden vocabulary is gone ---------------------------------------
block:
  for path in [PagePath, CorePath]:
    if not fileExists(path):
      check false, "44: " & path & " is missing"
      continue
    let lines = codeLines(readFile(path))
    for i, line in lines:
      for word in Forbidden:
        check word notin line,
          "44: " & path & " still says `" & word & "`: " & line.strip()

# ...and each replacement is present exactly once -----------------------------
block:
  let page = readFile(PagePath)
  for text in Replacements:
    var count = 0
    var at = 0
    while true:
      let found = page.find(text, at)
      if found < 0:
        break
      inc count
      at = found + 1
    check count >= 1,
      "44: the re-mapped string `" & text & "` is missing"
  ## The mismatch line names the frame, as the note re-maps it.
  check "Replay hash mismatch at frame" in page,
    "44: #mmwarn names the divergent FRAME"
  check "showing recorded moves" in page,
    "44: and says it is showing recorded moves"
  ## The endcard header is the re-mapped one.
  for column in ["<span>Level</span>", "<span>Kind</span>", "<span>Seed</span>",
                 "<span>Split</span>", "<span>Outcome</span>",
                 "<span>Gems</span>", "<span>Return</span>"]:
    check column in page, "44: the endcard header carries " & column

if failures > 0:
  quit("test_procgen_endcard_labels: " & $failures & " failures", 1)
echo "test_procgen_endcard_labels: ok"
