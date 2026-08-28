## End-to-end episodes: the artifacts, the certification seed, every shipped
## variant, the no-stall guarantee, the budget guard and the certifier probes
## (design note §Tests, numbered blocks 11 and 26-31).

import std/[json, os, sets, strutils]
import procgen/[baselines, decide, directives, engine, events, levels,
                records, replays, runtime, server, sim, sim_types]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

proc manifest(): JsonNode = parseJson(readFile("coworld_manifest_template.json"))

proc configFrom(node: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.update($node)

# 26. an episode writes its artifacts ----------------------------------------
block:
  let m = manifest()
  var config = configFrom(m{"certification"}{"game_config"})
  let played = runScriptedEpisode(config, blPathfinder)
  let dir = getTempDir() / "procgen-engine-test"
  createDir(dir)
  writeFile(dir / "results.json", played.episode.procgenResultsJson())
  writeFile(dir / "replay.bin", encodeReplay(played.replay))
  writeFile(dir / "events.jsonl",
    eventsJsonl(played.events, played.episode.totalFrames, GameVersion,
                played.directives))
  check fileExists(dir / "results.json"), "26: results.json is written"
  check fileExists(dir / "replay.bin"), "26: the replay is written"
  check getFileSize(dir / "replay.bin") > 0, "26: and it is not empty"

  let results = parseJson(readFile(dir / "results.json"))
  check results{"reason"}.getStr() == "complete", "26: reason is complete"
  check results{"endRule"}.getStr() == "gauntlet_complete",
    "26: endRule is the natural ending"
  check results{"scores"}[0].getFloat() >= 0.0 and
    results{"scores"}[0].getFloat() <= 1.0, "26: scores[0] is in [0, 1]"

  ## Every SEAT-indexed array is exactly one long; every LEVEL-indexed array is
  ## exactly levelCount long; and the results key set is EXACTLY the manifest's
  ## results_schema key set.
  let levelCount = results{"levelCount"}.getInt()
  const SeatKeys = ["names", "aliases", "scores", "win", "policyKinds",
                    "deadSeats"]
  for key in SeatKeys:
    check results{key}.len == 1, "26: results." & key & " is one long"
  const LevelKeys = ["levelKinds", "levelSplit", "levelSeeds", "levelReturns",
                     "levelOutcome", "levelDeathCause", "levelFrames",
                     "levelCollected", "levelCollectTotal"]
  for key in LevelKeys:
    check results{key}.len == levelCount,
      "26: results." & key & " is levelCount long"
  let schemaKeys = m{"game"}{"results_schema"}{"properties"}
  var wanted = initHashSet[string]()
  for key, _ in schemaKeys:
    wanted.incl(key)
  var got = initHashSet[string]()
  for key, _ in results:
    got.incl(key)
  check got == wanted,
    "26: the results key set equals the manifest results_schema key set; " &
    "missing=" & $(wanted - got) & " extra=" & $(got - wanted)
  removeDir(dir)

# 27. the certification seed is interesting ----------------------------------
block:
  let m = manifest()
  var config = configFrom(m{"certification"}{"game_config"})
  check config.seed == 42, "27: the fixture pins seed 42"
  check config.levelCount == 8,
    "27: the fixture plays the full eight-level gauntlet, so the smoke " &
    "replay is ~30 s of playback"
  let played = runScriptedEpisode(config, blPathfinder)
  var collects, exitOpens, deaths, cleared, lost = 0
  for e in played.events:
    case e.kind
    of ekCollect: inc collects
    of ekExitOpen: inc exitOpens
    of ekDeath: inc deaths
    else: discard
  for outcome in played.episode.outcomes:
    if outcome == loCleared: inc cleared
    elif outcome == loDied or outcome == loTimeup: inc lost
  echo "cert seed 42: frames=", played.episode.totalFrames,
    " collects=", collects, " exitopens=", exitOpens, " deaths=", deaths,
    " cleared=", cleared, " died-or-timeup=", lost,
    " outcomes=", played.episode.outcomes,
    " returns=", played.episode.returns
  ## The CI smoke replay must OUTLAST the 10 s viewer soak (the ecos
  ## 2026-08-23 scar: a replay shorter than the soak window legitimately ends
  ## and the last interval cannot advance). At renderFramesPerStep 4 and 24
  ## fps that is 6 sim frames a second, so 180 frames is 30 s of playback.
  ## The shipped `pathfinder` plays a level in ~25 frames, which is why the
  ## fixture runs the full EIGHT-level gauntlet rather than four.
  check played.episode.totalFrames >= 180,
    "27: seed 42 runs at least 180 sim frames (got " &
      $played.episode.totalFrames & ")"
  check collects >= 1, "27: at least one collect"
  check exitOpens >= 1, "27: at least one exitopen"
  check deaths >= 1, "27: at least one death, so the death beat is exercised"
  check cleared >= 1, "27: at least one level ends cleared"
  check lost >= 1, "27: and at least one ends died or timeup"

# 28. every shipped variant runs ---------------------------------------------
block:
  let m = manifest()
  for variant in m{"variants"}:
    let id = variant{"id"}.getStr()
    var config = configFrom(variant{"game_config"})
    check config.levelCount in [4, 8], id & ": the level count is legal"
    let played = runScriptedEpisode(config, blPathfinder)
    check played.episode.plan.len == config.levelCount,
      id & ": it plays the claimed number of levels"
    check played.episode.reason == rsComplete, id & ": it completes"
    check played.episode.endRule == erGauntletComplete,
      id & ": with the natural end rule"
    var seen, unseen = 0
    for planned in played.episode.plan:
      if planned.split == spSeen: inc seen else: inc unseen
    check seen == unseen and seen == config.levelCount div 2,
      id & ": the split is half and half"
    check played.episode.score() >= 0.0 and played.episode.score() <= 1.0,
      id & ": the score is in range"
    if id == "hardpool":
      check config.difficulty == "hard", "hardpool: the difficulty is hard"
    if id == "sprint":
      check config.turnsPerLevel == 14, "sprint: fourteen turns a level"

# 11. end conditions ---------------------------------------------------------
block:
  var config = defaultGameConfig()
  config.seed = 77
  config.turnSpacingMs = 0
  ## gauntlet_complete
  let healthy = runScriptedEpisode(config, blPathfinder)
  check healthy.episode.reason == rsComplete and
    healthy.episode.endRule == erGauntletComplete,
    "11: a healthy episode is complete / gauntlet_complete"
  for outcome in healthy.episode.outcomes:
    check outcome != loUnplayed, "11: a healthy episode plays every level"
    check outcome in [loCleared, loDied, loTimeup],
      "11: the outcome set is closed"
  ## wall_clock: a forced stop mid-gauntlet marks the unreached levels
  ## `unplayed` with return 0 and STILL divides by the full unseen count.
  let stopped = runScriptedEpisodeWith(config, blPathfinder,
    PathfinderTunables, stopAfterTurn = 6, stopReason = rsDeadline,
    stopEndRule = erWallClock)
  check stopped.episode.reason == rsDeadline and
    stopped.episode.endRule == erWallClock,
    "11: a forced wall-clock stop is deadline / wall_clock"
  var unplayed = 0
  for i in 0 ..< stopped.episode.plan.len:
    if stopped.episode.outcomes[i] == loUnplayed:
      inc unplayed
      check stopped.episode.returns[i] == 0, "11: an unplayed level scores 0"
  check unplayed > 0, "11: the stop really did leave levels unplayed"
  var unseenLevels = 0
  for planned in stopped.episode.plan:
    if planned.split == spUnseen: inc unseenLevels
  check unseenLevels == stopped.episode.plan.len div 2,
    "11: unseenMilli still divides by the FULL unseen count"
  check stopped.episode.score() >= 0.0,
    "11: a deadline episode is still rankable"
  var sawStop = false
  for record in stopped.replay.chats:
    if "\"k\":\"stop\"" in record and "wall_clock" in record:
      sawStop = true
  check sawStop, "11: the load-bearing stop is RECORDED, not re-derived"
  ## sim_fault
  let faulted = runScriptedEpisodeWith(config, blPathfinder,
    PathfinderTunables, stopAfterTurn = 4, stopReason = rsFault,
    stopEndRule = erSimFault)
  check faulted.episode.reason == rsFault and
    faulted.episode.endRule == erSimFault,
    "11: a forced fault is fault / sim_fault"
  ## The legal enum sets, exactly.
  var reasons = initHashSet[string]()
  for r in EndReason.low .. EndReason.high:
    reasons.incl($r)
  check reasons == ["complete", "deadline", "fault"].toHashSet(),
    "11: results.reason is exactly {complete, deadline, fault}"
  var rules = initHashSet[string]()
  for r in EndRule.low .. EndRule.high:
    rules.incl($r)
  check rules == ["gauntlet_complete", "wall_clock", "sim_fault",
                  "host_error"].toHashSet(),
    "11: results.endRule is exactly the four"
  var outcomes = initHashSet[string]()
  for o in LevelOutcome.low .. LevelOutcome.high:
    outcomes.incl($o)
  check outcomes == ["cleared", "died", "timeup", "unplayed"].toHashSet(),
    "11: results.levelOutcome is exactly the four"

# 29. no seat can stall ------------------------------------------------------
block:
  ## (a) A seat that NEVER CONNECTS plays pathfinder for the whole gauntlet,
  ## the episode finishes, `deadSeats[0]` is set, and exactly one
  ## closed-schema failure payload is produced -- by the server's OWN proc.
  var config = defaultGameConfig()
  config.seed = 5
  config.turnSpacingMs = 0
  var played = runScriptedEpisode(config, blPathfinder)
  played.episode.seat.dead = true
  check played.episode.reason == rsComplete,
    "29: an unregistered seat does not stop the episode"
  let node = parseJson(playerFailureJson(0))
  var keys: seq[string]
  for key, _ in node:
    keys.add(key)
  check keys.len == 2 and "message" in keys and "failed_policy_index" in keys,
    "29: exactly one closed-schema failure payload"
  check node{"failed_policy_index"}.getInt() == 0,
    "29: naming the seat that never registered"
  let serverSource = readFile("src/procgen/server.nim")
  check "playerFailureJson(0)" in serverSource,
    "29: and the server POSTs that very document"
  check ("echo \"ERROR: seat 0\", UnregisteredSeatLog" in serverSource) and
    UnregisteredSeatLog == " never registered — playing pathfinder",
    "29: with the loud unregistered-seat line on the same path"
  let results = parseJson(played.episode.procgenResultsJson())
  check results{"deadSeats"}[0].getBool(), "29: deadSeats is set"

  ## (b) A seat that CONNECTS AND THEN NEVER ANSWERS. There is no reply and no
  ## credential, so every turn takes the fallback: the decision layer still
  ## installs a legal plan, counts the fallback, and the gauntlet runs to its
  ## natural end.
  var live = defaultGameConfig()
  live.seed = 5
  live.levelCount = 4
  live.turnSpacingMs = 0
  var episode = newEpisode(live)
  var decider = initDecisionEngine(live)
  decider.seat.isLlm = true
  decider.seat.prompt = "take the nearest gem first"
  var turns = 0
  discard episode.beginLevel()
  while not episode.gauntletDone() and turns < 40:
    discard decider.turn(episode, 0)
    check decider.haveOrder, "29: the silent seat still gets a plan"
    check legalAlphabet(decider.order.moves), "29: and it is a legal plan"
    discard episode.applyPlan(decider.order.moves)
    inc turns
    if episode.levelDone():
      discard episode.endLevel()
      if episode.gauntletDone():
        break
      discard episode.beginLevel()
  check turns >= 1, "29: the silent-seat episode played"
  check episode.seat.fallbackTurns == turns,
    "29: every one of its turns is counted as a fallback (" &
      $episode.seat.fallbackTurns & " of " & $turns & ")"
  check episode.seat.llmTurns == 0, "29: with no LLM turn to its name"

# 30. the budget guard settles early -----------------------------------------
block:
  var config = defaultGameConfig()
  config.wallClockBudgetSeconds = 30
  config.turnSpacingMs = 0
  check config.turnBudgetSeconds() == 8,
    "30: the per-turn budget rounds up to whole seconds"
  var episode = newEpisode(config)
  discard episode.beginLevel()
  var decider = initDecisionEngine(config)
  decider.seat.isLlm = true
  decider.seat.prompt = "route through the level"
  let quiet = decider.turn(episode, 0)
  check not decider.llmOff, "30: at elapsed 0 the guard does not fire"
  var firedEarly = false
  for record in quiet:
    if "\"k\":\"budget_guard\"" in record: firedEarly = true
  check not firedEarly, "30: and writes no budget_guard record"
  let records = decider.turn(episode, 20)
  check decider.llmOff,
    "30: at elapsed 20 with an 8 s turn budget and a 30 s wall clock it fires"
  var guard = newJNull()
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "budget_guard":
      guard = node
  check guard.kind == JObject, "30: and writes a budget_guard record"
  if guard.kind == JObject:
    check guard{"remaining_s"}.getInt() ==
      config.wallClockBudgetSeconds - 20,
      "30: naming how much wall clock was left"
  check decider.haveOrder, "30: the seat still has a plan after the guard"

# 31. the certifier's browser probes -----------------------------------------
block:
  ## The probes are HTTP surface, so they are asserted where they are
  ## declared: registered BEFORE the catch-all asset route, token-checked, and
  ## never opening the player socket.
  let m = manifest()
  let source = readFile("src/procgen/server.nim")
  let healthAt = source.find("result.get(\"/healthz\"")
  let playerAt = source.find("result.get(\"/client/player\"")
  let globalAt = source.find("result.get(\"/client/global\"")
  let catchAt = source.find("result.get(\"/**\"")
  check healthAt > 0 and playerAt > 0 and globalAt > 0 and catchAt > 0,
    "31: every certifier probe route is registered"
  check healthAt < catchAt and playerAt < catchAt and globalAt < catchAt,
    "31: and all of them BEFORE the catch-all asset route"
  check "handleClientPlayer" in source and
    "\"bad player token\"" in source,
    "31: /client/player is token-checked"
  check "It opens no socket" in source or "opens no socket" in source,
    "31: and it does not open the player socket"
  check "socket.send(message.data, Pong)" in source,
    "31: the websocket handler answers a Ping with a Pong"
  check "ShutdownGraceSeconds" in source and
    "var graceUntil = getMonoTime()" in source,
    "31: and /healthz + /global keep answering for the shutdown grace"

  ## ...for a grace that cannot push the pod past its budget. The whole
  ## worst-case tail, in seconds, against the 60 % budget the checklist and
  ## the note both name (720 of 1200):
  ##   the budget guard turns the seat scripted at
  ##   `elapsed + 2 x turnBudget > wallClock`, so the last LLM turn ENDS by
  ##   `wallClock - turnBudget`; then the gameOverFrames display hold; then
  ##   the artifact writes, each bounded by FetchTimeoutSeconds, of which the
  ##   SCORED one is written first.
  check PodBudgetSeconds == 720,
    "31: the pod budget is 60 % of episode_timeout_minutes: 20"
  check m{"episode_timeout_minutes"}.getInt() * 60 * 3 div 5 ==
    PodBudgetSeconds,
    "31: and it is derived from the manifest's own timeout"
  for variant in m{"variants"}:
    let id = variant{"id"}.getStr()
    var config = defaultGameConfig()
    config.update($variant{"game_config"})
    let
      lastLlmTurnEnd = config.wallClockBudgetSeconds -
        config.turnBudgetSeconds()
      holdSeconds = (config.gameOverFrames * 20 + 999) div 1000
      scoredBy = lastLlmTurnEnd + holdSeconds + FetchTimeoutSeconds
    check scoredBy <= PodBudgetSeconds,
      id & ": the SCORED artifact is written by " & $scoredBy &
        " s, inside the " & $PodBudgetSeconds & " s budget"
    ## And the grace is clamped, so process exit cannot run away even when
    ## every remaining artifact URI hangs for its full timeout.
    check ShutdownGraceSeconds > 0, id & ": there is a shutdown grace"
    check "if graceUntil > podDeadline" in source,
      id & ": and it is clamped to the pod budget"

if failures > 0:
  quit("test_procgen_engine: " & $failures & " failures", 1)
echo "test_procgen_engine: ok"
