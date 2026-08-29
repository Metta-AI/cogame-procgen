## The replay: record then re-derive for EVERY end reason, self-sufficiency,
## the strict-UTF-8 summary and the GameVersion sweep (design note §Tests,
## numbered blocks 32-35).

import std/[json, os, osproc, strutils, unicode]
import procgen/[baselines, broadcast, directives, engine, levels,
                replay_runtime, replays, sim, tiles]

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

# ---------------------------------------------------------------------------
#  The committed fixtures (design note §Tests, numbered block 49)
#
#  Four recordings live in tests/fixtures/. They are the only replays in this
#  repo that were written by an EARLIER build, which is the whole point: the
#  in-process re-derivation below proves this build agrees with itself, and a
#  committed fixture proves it still agrees with the build that recorded it.
#  A rules change, a generator change or a wire change that is not accompanied
#  by a GameVersion bump turns the hash chain red here.
#
#  RECIPE DISCIPLINE (the starter's, AGENTS.md §Replay fixtures): a recipe
#  pins EVERY field its ending depends on, so re-recording is mechanical:
#
#    nim r --path:src tests/test_procgen_replay.nim --write
#
#  Re-record on a GameVersion bump, and in the same commit as any deliberate
#  change to the rules or to the recorded stream.
# ---------------------------------------------------------------------------

type FixtureRecipe = object
  name: string
  seed, levelCount, turnsPerLevel, framesPerTurn, fallLethal: int
  difficulty: string
  interruptOnDanger: bool
  baseline: Baseline
  stopAfterTurn: int
  reason: EndReason
  rule: EndRule

const Fixtures = [
  # The certification fixture's own configuration, seed and all.
  FixtureRecipe(name: "gauntlet-seed42", seed: 42, levelCount: 8,
    turnsPerLevel: 10, framesPerTurn: 6, fallLethal: 4,
    difficulty: "standard", interruptOnDanger: true, baseline: blPathfinder,
    stopAfterTurn: 0, reason: rsComplete, rule: erGauntletComplete),
  # The `sprint` variant: four levels, fourteen turns each.
  FixtureRecipe(name: "sprint-seed7", seed: 7, levelCount: 4,
    turnsPerLevel: 14, framesPerTurn: 6, fallLethal: 4,
    difficulty: "standard", interruptOnDanger: true, baseline: blScavenger,
    stopAfterTurn: 0, reason: rsComplete, rule: erGauntletComplete),
  # The `hardpool` variant: three hunters, more spikes, more boulders.
  FixtureRecipe(name: "hard-seed13", seed: 13, levelCount: 8,
    turnsPerLevel: 10, framesPerTurn: 6, fallLethal: 4,
    difficulty: "hard", interruptOnDanger: true, baseline: blPathfinder,
    stopAfterTurn: 0, reason: rsComplete, rule: erGauntletComplete),
  # A wall-clock stop mid-gauntlet: the ending the sim cannot re-derive, so
  # the `stop` record has to come back off the bytes.
  FixtureRecipe(name: "deadline-seed21", seed: 21, levelCount: 8,
    turnsPerLevel: 10, framesPerTurn: 6, fallLethal: 4,
    difficulty: "standard", interruptOnDanger: true, baseline: blPathfinder,
    stopAfterTurn: 9, reason: rsDeadline, rule: erWallClock)]

proc recipeConfig(recipe: FixtureRecipe): GameConfig =
  result = defaultGameConfig()
  result.seed = recipe.seed
  result.levelCount = recipe.levelCount
  result.turnsPerLevel = recipe.turnsPerLevel
  result.framesPerTurn = recipe.framesPerTurn
  result.fallLethal = recipe.fallLethal
  result.difficulty = recipe.difficulty
  result.interruptOnDanger = recipe.interruptOnDanger
  result.turnSpacingMs = 0
  result.playerNames = @["daveey"]

proc recordFixture(recipe: FixtureRecipe): string =
  let played = runScriptedEpisodeWith(recipeConfig(recipe), recipe.baseline,
    tunablesFor(recipe.baseline), stopAfterTurn = recipe.stopAfterTurn,
    stopReason = recipe.reason, stopEndRule = recipe.rule)
  encodeReplay(played.replay)

proc fixturePath(recipe: FixtureRecipe): string =
  "tests/fixtures/" & recipe.name & ".replay"

if paramCount() >= 1 and paramStr(1) == "--write":
  createDir("tests/fixtures")
  for recipe in Fixtures:
    writeFile(recipe.fixturePath(), recordFixture(recipe))
    echo "wrote ", recipe.fixturePath(), " (",
      getFileSize(recipe.fixturePath()), " bytes)"
  quit(0)

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

# 49. the committed fixtures still replay -----------------------------------
block:
  for recipe in Fixtures:
    let path = recipe.fixturePath()
    if not fileExists(path):
      check false, "49: " & path & " is missing -- record it with " &
        "`nim r --path:src tests/test_procgen_replay.nim --write`"
      continue
    let committed = readFile(path)
    check committed.len > 0, "49: " & recipe.name & " is not empty"
    var rt = loadReplay(committed)
    check rt.replay.gameVersion == GameVersion,
      "49: " & recipe.name & " carries the current GameVersion"
    ## The load-bearing one: this build re-generates every level from the
    ## recorded seeds and re-runs the recorded action bytes, and the hash
    ## chain still matches at EVERY frame.
    check rt.mismatchFrame < 0,
      "49: " & recipe.name & " re-derives frame by frame (first divergence " &
        $rt.mismatchFrame & ")"
    check rt.episode.plan.len == recipe.levelCount,
      "49: " & recipe.name & " plays its recipe's level count"
    if recipe.stopAfterTurn > 0:
      check rt.stopEndRule == $recipe.rule,
        "49: " & recipe.name & "'s recorded stop comes back off the bytes"
    ## ...and recording it again from the recipe produces the same episode:
    ## the same action stream and the same per-frame hashes. This is what
    ## catches a SILENT rules or generator change -- one that would otherwise
    ## only show up as a hosted replay that no longer matches its recording.
    let fresh = decodeReplay(recordFixture(recipe))
    check fresh.frames.len == rt.replay.frames.len,
      "49: " & recipe.name & " replays the same number of frames (" &
        $fresh.frames.len & " vs " & $rt.replay.frames.len & ")"
    var drift = -1
    for i in 0 ..< min(fresh.frames.len, rt.replay.frames.len):
      if fresh.frames[i].action != rt.replay.frames[i].action or
          fresh.frames[i].hash != rt.replay.frames[i].hash:
        drift = i
        break
    check drift < 0,
      "49: " & recipe.name & " diverges from its recipe at frame " & $drift &
        " -- if the change was deliberate, re-record with --write in the " &
        "same commit"

# 50. the 0.5x playback rung -------------------------------------------------
#
#  The viewer's speed chips are step multipliers the runtime applies per
#  render frame, so every rung above 1 is just a bigger step. HALF speed
#  cannot be: the smallest step is one frame. It is instead the same 1-frame
#  step taken on every OTHER render frame, gated on `halfPhase`. The chips
#  send '5'; the page relays the raw digit keys, so the '5' key does it too.
block:
  let played = runScriptedEpisode(cfg(31, levelCount = 2), blPathfinder)
  let bytes = encodeReplay(played.replay)

  proc framesAfter(commands: openArray[string], renderFrames: int): int =
    ## Absolute render-frame position after driving `renderFrames` frames.
    var rt = loadReplay(bytes)
    for c in commands:
      rt.command(c)
    for _ in 0 ..< renderFrames:
      rt.advance()
    rt.playback.frame

  ## 1x advances one frame per render frame; 0.5x advances half as far over
  ## the same number of render frames, and 2x twice as far.
  check framesAfter(["1"], 40) == 40, "50: 1x advances one frame per frame"
  check framesAfter(["5"], 40) == 20,
    "50: 0.5x advances half as far over the same render frames (got " &
      $framesAfter(["5"], 40) & ")"
  check framesAfter(["2"], 40) == 80, "50: 2x still doubles"

  ## The rung is a real state, reported on the wire as 0.5 rather than as the
  ## sentinel, and every other rung still reports its own multiplier.
  var rt = loadReplay(bytes)
  check rt.displaySpeed() == 1.0, "50: playback opens at 1x"
  rt.command("5")
  check rt.playback.speed == ReplayHalfSpeed,
    "50: '5' selects the half rung"
  check rt.displaySpeed() == 0.5, "50: and the wire reports it as 0.5"
  rt.command("8")
  check rt.displaySpeed() == 8.0, "50: '8' goes back up to 8x"
  rt.command("5")
  check "\"sp\":0.5" in framePacket(rt),
    "50: the frame packet carries the 0.5 the chips compare against"

  ## Pausing does not park the phase: Space in, Space out, and the half rung
  ## still covers half the ground.
  check framesAfter(["5", " ", " "], 40) == 20,
    "50: a pause/unpause leaves the half rung advancing at half speed"

  ## Half speed is the UNBOOSTED path only -- `f` (skip lulls) still fast
  ## forwards through a lull at its full 4x. This episode has no lull of its
  ## own, so the span is stated outright: what is under test is the ORDER of
  ## the two branches, not the lull detector (block 33 owns that).
  var lulled = loadReplay(bytes)
  lulled.lulls = @[[0, 40]]
  lulled.command("5")
  lulled.command("f")
  var boosted = 0
  for _ in 0 ..< 2:
    let before = lulled.playback.frame
    lulled.advance()
    boosted += lulled.playback.frame - before
  check boosted == 8,
    "50: skip-lulls still boosts to 4x on EVERY frame under the half rung " &
      "(got " & $boosted & " over two frames)"
  check lulled.playback.fastForward,
    "50: and says so on the wire"

if failures > 0:
  quit("test_procgen_replay: " & $failures & " failures", 1)
echo "test_procgen_replay: ok"
