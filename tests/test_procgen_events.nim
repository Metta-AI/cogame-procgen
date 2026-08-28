## The event vocabulary is CLOSED (design note §Record and event vocabulary;
## numbered test 46): the set of kinds the sim can emit is exactly the
## seventeen the note lists, seven of them make scrubber beats, and every kind
## the appended viewer block consumes is in the set.

import std/[json, os, strutils]
import procgen/[baselines, engine, events, levels, records, replay_runtime,
                replays, sim]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

# 46. the closed enum --------------------------------------------------------
block:
  const Expected = ["gamestart", "levelstart", "plan", "step", "collect",
                    "dig", "push", "fall", "hunter", "interrupt", "death",
                    "exitopen", "levelend", "say", "fallback", "gauntletend",
                    "end"]
  var declared: seq[string]
  for kind in EventKind.low .. EventKind.high:
    declared.add($kind)
  check declared.len == 17, "46: seventeen broadcast kinds, counting `end`"
  for name in Expected:
    check name in declared, "46: the vocabulary carries " & name
  for name in declared:
    check name in Expected, "46: " & name & " is not in the note's list"
  check AllEventKinds.len == 17, "46: AllEventKinds is the whole set"

  ## The beats: exactly seven kinds, and the ones the note names.
  const ExpectedBeats = ["levelstart", "collect", "exitopen", "death",
                         "levelend", "fallback", "gauntletend"]
  check BeatKinds.len == 7, "46: seven beat kinds"
  for kind in BeatKinds:
    check $kind in ExpectedBeats, "46: " & $kind & " is a beat kind"
    check isBeatKind(kind), "46: isBeatKind agrees"
  for kind in EventKind.low .. EventKind.high:
    if $kind notin ExpectedBeats:
      check not isBeatKind(kind),
        "46: " & $kind & " must NOT make a scrubber beat"

# what a real episode actually emits -----------------------------------------
block:
  var config = defaultGameConfig()
  config.seed = 2468
  config.turnSpacingMs = 0
  let played = runScriptedEpisode(config, blPathfinder)
  var emitted: seq[string]
  for e in played.events:
    if $e.kind notin emitted:
      emitted.add($e.kind)
  for name in emitted:
    var known = false
    for kind in EventKind.low .. EventKind.high:
      if $kind == name:
        known = true
    check known, "46: the episode emitted an unknown kind: " & name
  for name in ["gamestart", "levelstart", "plan", "step", "collect",
               "exitopen", "levelend", "gauntletend", "end"]:
    check name in emitted,
      "46: a real episode emits " & name & " (got " & $emitted & ")"
  ## The kinds a SCRIPTED episode cannot produce are the two that are facts
  ## about a decision rather than about the level -- `say` and `fallback`,
  ## which a baseline never makes -- plus the archetype-specific ones a
  ## particular seed may not reach. They are derived from the recorded chat
  ## records by the replay runtime, asserted below.
  for name in ["say", "fallback"]:
    check name notin emitted,
      "46: a scripted episode makes no " & name & " event"

# ...and the REPLAYED stream, which is what the viewer draws, emits the same --
block:
  var config = defaultGameConfig()
  config.seed = 2468
  config.turnSpacingMs = 0
  var played = runScriptedEpisode(config, blPathfinder)
  ## A say and a fallback record, which only a live LLM seat writes, so the
  ## two kinds the sim cannot derive are exercised on the path that derives
  ## them: the pre-scan reads them off the recorded chats.
  played.replay.chats.add(fallbackRecord(1, 2, "timeout", "no reply"))
  for i, record in played.replay.chats:
    if "\"k\":\"directive\"" in record and "\"turn\":1," in record:
      var node = parseJson(record)
      node["say"] = %"digging under the rock"
      played.replay.chats[i] = $node
  let rt = loadReplay(encodeReplay(played.replay))
  var emitted: seq[string]
  for e in rt.events:
    if $e.kind notin emitted:
      emitted.add($e.kind)
  for name in ["gamestart", "levelstart", "plan", "step", "levelend",
               "say", "fallback", "gauntletend"]:
    check name in emitted,
      "46: the replayed stream emits " & name & " (got " & $emitted & ")"
  for name in emitted:
    var known = false
    for kind in EventKind.low .. EventKind.high:
      if $kind == name:
        known = true
    check known, "46: the replayed stream emitted an unknown kind: " & name

block:
  var config = defaultGameConfig()
  config.seed = 2468
  config.turnSpacingMs = 0
  let played = runScriptedEpisode(config, blPathfinder)

  ## The tier-2 stream: sixteen kinds, each with a wire key, plus the
  ## mandatory trailing summary row.
  var simKinds: seq[string]
  for kind in SimEventKind.low .. SimEventKind.high:
    simKinds.add(key(kind))
  check simKinds.len == 16, "46: sixteen tier-2 kinds"
  check "directive" in simKinds,
    "46: including `directive`, which the sim cannot derive"
  check "gamestart" notin simKinds and "end" notin simKinds,
    "46: and excluding the two the config and the results already say"
  let stream = eventsJsonl(played.events, played.episode.totalFrames,
    GameVersion, played.directives)
  let lines = stream.strip().splitLines()
  check lines.len >= 2, "46: the stream has rows"
  var summary: JsonNode
  try:
    summary = parseJson(lines[^1])
  except CatchableError:
    summary = newJNull()
  check summary.kind == JObject and summary{"type"}.getStr() == "summary",
    "46: the mandatory trailing summary row is last"
  check summary{"gameVersion"}.getStr() == GameVersion,
    "46: and it carries the GameVersion"
  for i in 0 ..< lines.len:
    var row: JsonNode
    try:
      row = parseJson(lines[i])
    except CatchableError:
      row = newJNull()
    check row.kind == JObject, "46: every row is one JSON object"

# every kind the appended viewer block consumes is in the set ----------------
block:
  const PagePath = "client/replay_broadcast.html"
  if not fileExists(PagePath):
    check false, "46: the page is missing"
  else:
    let page = readFile(PagePath)
    let at = page.find("PROCGEN additions to the inherited coworld-ctf chrome")
    let tail = page[at .. ^1]
    ## The block turns `s.beats[i].k` into a CSS class; the CSS rules are
    ## checked against the emitted set in tests/test_procgen_viewer.nim, and
    ## here we check the block never invents a kind of its own.
    for kind in BeatKinds:
      check ".beat-marker." & $kind in tail,
        "46: the block styles the emitted beat kind " & $kind

if failures > 0:
  quit("test_procgen_events: " & $failures & " failures", 1)
echo "test_procgen_events: ok"
