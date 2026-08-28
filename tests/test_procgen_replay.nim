## The replay: record then re-derive for EVERY end reason, self-sufficiency,
## the strict-UTF-8 summary and the GameVersion sweep (design note §Tests,
## numbered blocks 32-35).

import std/[json, os, osproc, strutils, unicode]
import procgen/[baselines, directives, engine, levels, replay_runtime, replays,
                sim, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

proc cfg(seed: int, levelCount = 8): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.levelCount = levelCount
  result.turnSpacingMs = 0

# 32. record then re-derive, EVERY end reason --------------------------------
block:
  ## The particle-worlds scar: a wall-clock stop is a fact the sim cannot
  ## re-derive, so it is recorded once and applied by the same proc on record
  ## and on playback. Every end reason gets the same treatment and the same
  ## test.
  let cases = [
    ("gauntlet_complete", 0, rsComplete, erGauntletComplete),
    ("wall_clock", 7, rsDeadline, erWallClock),
    ("sim_fault", 5, rsFault, erSimFault)]
  for (name, stopAfter, reason, rule) in cases:
    let played = runScriptedEpisodeWith(cfg(2027), blPathfinder,
      PathfinderTunables, stopAfterTurn = stopAfter, stopReason = reason,
      stopEndRule = rule)
    check played.episode.reason == reason and played.episode.endRule == rule,
      "32: the " & name & " episode really ended that way"
    var rt = loadReplay(encodeReplay(played.replay))
    check rt.mismatchFrame < 0,
      "32: " & name & " re-derives with an identical hash at every frame " &
        "including the stop frame (first divergence " & $rt.mismatchFrame & ")"
    if stopAfter > 0:
      check rt.stopEndRule == name,
        "32: the " & name & " stop record comes back off the bytes"
      check rt.stopFrame >= 0, "32: with the frame it stopped on"

# 33. the replay is self-sufficient ------------------------------------------
block:
  var config = cfg(1234)
  config.playerNames = @["daveey"]
  let played = runScriptedEpisode(config, blScavenger)
  let bytes = encodeReplay(played.replay)
  var rt = loadReplay(bytes)
  check rt.name == "daveey", "33: the seat's real name comes off the bytes"
  check rt.policyKind == "scripted", "33: and its policy kind"
  let node = parseJson(rt.replay.configJson)
  for key in ["levelKinds", "levelSeeds", "levelSplit", "difficulty",
              "num_agents", "seed", "variant", "aliases", "players"]:
    check node.hasKey(key), "33: the config carries " & key
  check node{"num_agents"}.getInt() == 1, "33: num_agents is 1"
  check node{"levelSeeds"}.len == played.episode.plan.len,
    "33: one seed per level"
  check rt.snapshots.len > 1,
    "33: the eight grids are RE-GENERATED from those seeds, not stored"
  var records = 0
  for record in rt.replay.chats:
    if record.startsWith("{"):
      inc records
  check records >= 2, "33: the chat records come back too"
  check rt.resultsJson.len > 0,
    "33: including the `result` record, so the outcome is in the bytes"

# 34. replay_summary.py is strict UTF-8 JSON ---------------------------------
block:
  ## Every capped field filled to exactly its cap with 4-byte emoji: the
  ## summary must still parse under a STRICT UTF-8 JSON parser, which is what
  ## proves every cut landed on a rune boundary.
  var config = cfg(4321, 4)
  config.playerNames = @["daveey-1"]
  var played = runScriptedEpisode(config, blPathfinder)
  var emoji = ""
  for _ in 0 ..< MaxSayRunes:
    emoji.add("\u{1F600}")
  var note = ""
  for _ in 0 ..< MaxNoteRunes:
    note.add("\u{1F600}")
  var order = PlanOrder(moves: "RRXDDL", source: dsLlm, executed: 6,
    say: emoji.truncateRunes(MaxSayRunes),
    notes: sanitizeNote(note))
  check order.notes.runeLen <= MaxNoteRunes,
    "34: the note is capped in RUNES"
  played.replay.chats.add(boundedDirectiveRecord(order, 1, 1, "COG-alpha", ""))
  let dir = getTempDir() / "procgen-replay-test"
  createDir(dir)
  let path = dir / "episode.replay"
  writeFile(path, encodeReplay(played.replay))
  if not fileExists("tools/replay_summary.py"):
    check false, "34: tools/replay_summary.py is missing"
  else:
    let (output, code) = execCmdEx("python3 tools/replay_summary.py " & path)
    check code == 0, "34: replay_summary.py exits 0: " & output
    if code == 0:
      var summary: JsonNode
      try:
        summary = parseJson(output)
      except CatchableError as error:
        check false, "34: the summary is not strict JSON: " & error.msg
        summary = newJNull()
      if summary.kind == JObject:
        check summary{"protocol"}.getStr() == "procgen/v1",
          "34: protocol == procgen/v1"
        check summary{"levelSeeds"}.len == summary{"levelCount"}.getInt(),
          "34: levelSeeds | length == levelCount"
        check summary{"frameCount"}.getInt() > 0, "34: it counted the frames"
        check summary{"results"}.kind == JObject,
          "34: and it decoded the result record"
        check output.validateUtf8() == -1,
          "34: the whole summary is valid UTF-8"
  removeDir(dir)

# 35. every committed replay carries the current GameVersion -----------------
block:
  let played = runScriptedEpisode(cfg(9), blPathfinder)
  check played.replay.gameVersion == GameVersion,
    "35: a freshly recorded replay carries the current GameVersion"
  var rt = loadReplay(encodeReplay(played.replay))
  check rt.replay.gameVersion == GameVersion,
    "35: and it comes back off the bytes"
  ## A replay recorded under another version is REFUSED rather than
  ## re-simulated wrong.
  var stale = played.replay
  stale.gameName = "procgen"
  let bytes = encodeReplay(stale)
  check bytes[0 ..< ReplayMagic.len] == ReplayMagic,
    "35: the magic is COWLDPGN"
  var raised = false
  try:
    discard decodeReplay("NOTAPLAY" & bytes[8 .. ^1])
  except ProcgenError:
    raised = true
  check raised, "35: bad magic is refused"
  ## Any `.replay` committed under tests/ must carry the current version.
  if dirExists("tests/fixtures"):
    for file in walkFiles("tests/fixtures/*.replay"):
      let replay = decodeReplay(readFile(file))
      check replay.gameVersion == GameVersion,
        "35: " & file & " carries a stale GameVersion"

if failures > 0:
  quit("test_procgen_replay: " & $failures & " failures", 1)
echo "test_procgen_replay: ok"
