## The scripted baselines and the reply validator (design note §Tests,
## numbered blocks 20-25).
##
## Both baselines emit the SAME object an LLM emits, so one validator covers
## both; every veto is computed by running the RESOLVER'S OWN `stepFrame` over
## a scratch copy, so a symbol a baseline rejects as fatal is exactly a symbol
## the resolver would have killed the cog for.

import std/[json, os, strutils, unicode]
import procgen/[baselines, control, directives, engine, gen, levels, sim,
                sim_types, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

proc statesToTest(): seq[LevelState] =
  ## 500 pseudo-random level states: all four archetypes, all three
  ## difficulties, every phase from full to nearly cleared.
  var i = 0
  for kind in LevelKind.low .. LevelKind.high:
    for difficulty in Difficulty.low .. Difficulty.high:
      for trial in 1 .. 42:
        inc i
        var st = newLevel(kind, 600000 + i * 7717, difficulty)
        ## Advance it a few frames so the state is not always the spawn.
        var guard = 0
        while guard < trial mod 9 and st.alive and not st.finished:
          inc guard
          discard stepFrame(st, "RDLU."[guard mod 5], 1, 4)
        ## And clear some collectibles, so the "nearly cleared" phase and the
        ## OPEN exit are both covered.
        if trial mod 3 == 0:
          for index in 0 ..< BoardCells:
            if st.grid.cells[index].collectible() and
                st.collected + 1 < st.collectTotal:
              st.grid.setTile(cellAt(index), tEmpty)
              inc st.collected
        result.add(st)

let states = statesToTest()

# 20. baselines are bounded --------------------------------------------------
block:
  check states.len >= 500, "20: 500 states under test (" & $states.len & ")"
  for kind in [blPathfinder, blScavenger]:
    for st in states:
      let order = scriptedPlan(st, kind, 6, 4)
      check order.moves.len >= 1 and order.moves.len <= 6,
        "20: " & $kind & " emits 1..6 symbols (" & $order.moves.len & ")"
      check legalAlphabet(order.moves),
        "20: " & $kind & " only ever emits LRUDX. (" & order.moves & ")"
      check order.say.len == 0 and order.notes.len == 0,
        "20: a scripted baseline emits no say and no notes"
      check order.source == dsScripted, "20: it says it is scripted"
      let record = boundedDirectiveRecord(order, 3, 2, "COG-alpha", "")
      check record.len <= 1024,
        "20: a serialised scripted directive is under 1024 bytes"

# 21. baselines never leave the cog unactuated -------------------------------
block:
  for kind in [blPathfinder, blScavenger]:
    for st in states:
      ## Seal the cog in: every direction fatal or blocked.
      var sealed = st
      for d in DirOrder:
        sealed.grid.setTile(sealed.cog.step(d), tWall)
      let order = scriptedPlan(sealed, kind, 6, 4)
      check order.moves.len >= 1,
        "21: a sealed cog still gets a plan (" & $kind & ")"
      check legalAlphabet(order.moves),
        "21: the sealed plan is still legal"

# 22. baselines agree with the resolver --------------------------------------
block:
  for kind in [blPathfinder, blScavenger]:
    for st in states:
      let order = scriptedPlan(st, kind, 6, 4)
      var scratch = st
      for i, symbol in order.moves:
        let predicted = applyAction(scratch, symbol)
        let before = scratch.cog
        discard stepFrame(scratch, symbol, 1, 4)
        if predicted.effect == aeBlocked:
          check scratch.cog == before or scratch.kind == lkClimber,
            "22: a blocked symbol does not move the cog (except under gravity)"
        if not scratch.alive:
          break
      ## `pathfinder` projects the WHOLE plan, so its plan never kills the cog
      ## on a frame it looked at -- that is what lookaheadFrames buys.
      if kind == blPathfinder and st.alive:
        var probe = st
        var killed = false
        for symbol in order.moves:
          discard stepFrame(probe, symbol, 1, 4)
          if not probe.alive:
            killed = true
            break
        check (not killed) or order.moves == ".",
          "22: a pathfinder plan never walks into a death it could see"

# 23. the fallback IS the pathfinder proc ------------------------------------
block:
  check FallbackBaseline == blPathfinder,
    "23: the published fallback baseline is pathfinder"
  for st in states:
    let
      fallback = fallbackPlan(st, 6, 4)
      pathfinder = scriptedPlan(st, blPathfinder, 6, 4)
    check fallback.moves == pathfinder.moves,
      "23: the fallback path and the pathfinder baseline are the same proc"
    check fallback.source == dsFallback,
      "23: only the SOURCE differs, so a fallback is countable"

# 24. reply validation -------------------------------------------------------
block:
  proc parsed(text: string): PlanOrder =
    parsePlanOrder(extractJsonObject(text), 6)
  check parsed("""{"moves":"RRXDDL"}""").moves == "RRXDDL",
    "24: the schema is accepted"
  check parsed("""{"moves":"rrx"}""").moves == "RRX",
    "24: lower case is uppercased"
  let junk = parsed("""{"moves":"R!R@ X"}""")
  check junk.moves == "RRX" and junk.repaired,
    "24: junk characters are DROPPED and the repair is counted"
  let long = parsed("""{"moves":"RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR"}""")
  check long.moves.len == 6 and long.repaired,
    "24: a 40-character plan is truncated to six"
  check parsed("""{"moves":""}""").moves == ".",
    "24: an empty plan becomes one wait"
  check parsed("""{"say":"hi"}""").moves == ".",
    "24: an absent plan becomes one wait"
  check parsed("""{"moves":7}""").moves == ".",
    "24: a non-string plan becomes one wait"
  check parsed("""{"moves":"LL"}""").moves == "LL",
    "24: a reply with only `moves` is accepted"
  var rejected = false
  try:
    discard parsePlanOrder(parseJson("[1,2]"), 6)
  except DirectiveError:
    rejected = true
  check rejected, "24: a non-object is rejected (and the retry exists for it)"
  ## Markdown fences and surrounding prose survive.
  check parsed("here you go:\n```json\n{\"moves\":\"UD\"}\n```\nthanks").moves ==
    "UD", "24: the extraction is fence- and prose-tolerant"
  ## RUNE boundaries, with a 4-byte emoji sitting exactly on each cap.
  let emoji = "\u{1F600}"          ## 4 bytes, 1 rune
  var say = ""
  for _ in 0 ..< 40: say.add(emoji)
  let capped = parsed("""{"moves":"L","say":"""" & say & """","notes":"""" &
    say & """"}""")
  check capped.notes.runeLen <= MaxNoteRunes,
    "24: notes is truncated to 160 RUNES"
  for rune in capped.notes.runes:
    check int(rune) > 0, "24: the note is still valid UTF-8 after the cut"
  ## `say` is rune-truncated FIRST and then printable-ASCII filtered, so a
  ## 4-byte emoji leaves nothing behind rather than half a codepoint.
  check capped.say.runeLen <= MaxSayRunes,
    "24: say is truncated to 24 RUNES"
  ## The 4096-byte read cap, cut on a rune boundary.
  var huge = ""
  while huge.len < MaxReplyBytes + 400:
    huge.add(emoji)
  let bounded = boundedReply(huge)
  check bounded.len <= MaxReplyBytes, "24: the read cap is 4096 bytes"
  check bounded.len mod 4 == 0,
    "24: the read cap backs off to a rune boundary"
  ## And the validator never leaves the cog without a plan.
  for text in ["""{"moves":"...."}""", """{"moves":"zzz"}""",
               """{"moves":null}""", """{}"""]:
    check parsed(text).moves.len >= 1,
      "24: every repairable reply still actuates the cog: " & text

# 25. the tuning is the swept pick -------------------------------------------
block:
  const TuningPath = "tools/ci/baseline_tuning.json"
  if not fileExists(TuningPath):
    check false, "25: tools/ci/baseline_tuning.json is missing"
  else:
    let recorded = parseJson(readFile(TuningPath))
    let p = recorded{"pathfinder"}
    check p{"lookaheadFrames"}.getInt() == PathfinderTunables.lookaheadFrames and
      p{"digCost"}.getInt() == PathfinderTunables.digCost and
      p{"commitFrames"}.getInt() == PathfinderTunables.commitFrames and
      p{"detourBudget"}.getInt() == PathfinderTunables.detourBudget,
      "25: the shipped pathfinder tunables ARE the recorded pick"
    let s = recorded{"scavenger"}
    check s{"lookaheadFrames"}.getInt() == ScavengerTunables.lookaheadFrames and
      s{"digCost"}.getInt() == ScavengerTunables.digCost and
      s{"detourBudget"}.getInt() == ScavengerTunables.detourBudget,
      "25: the shipped scavenger tunables ARE the recorded pick"
    ## The margin band itself is asserted by `tools/tune_baselines.nim --check`
    ## in ci.yml, which replays the whole twelve-pair ladder; repeating that
    ## ladder in every test file would triple the suite's runtime for the same
    ## assertion.
    check recorded.hasKey("marginMin") and recorded.hasKey("marginMax"),
      "25: the recorded ladder carries the margin band CI checks"

if failures > 0:
  quit("test_procgen_control: " & $failures & " failures", 1)
echo "test_procgen_control: ok"
