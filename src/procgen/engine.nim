## A whole episode, played headlessly on the scripted layer.
##
## The server's own loop (`src/procgen/server.nim`) is this loop plus the
## decision engine and the artifact writes; this module is the part that has
## no sockets and no clock, so the tests, `tools/tune_baselines.nim` and the
## fixture recorder all drive the SAME code the server drives rather than a
## second copy of the rules.

import baselines, directives, events, levels, records, replays, sim, tiles

type
  ScriptedEpisode* = object
    episode*: Episode
    replay*: Replay
    events*: seq[FrameEvent]
    directives*: seq[DirectiveEvent]

proc runScriptedEpisodeWith*(config: GameConfig, kind: Baseline,
                             tuning: Tunables,
                             stopAfterTurn = 0,
                             stopReason = rsComplete,
                             stopEndRule = erGauntletComplete):
    ScriptedEpisode =
  ## One episode, the seat scripted. Returns the settled episode, the replay
  ## the server would have written, and every event the frame loop emitted.
  ##
  ## `stopAfterTurn > 0` cuts the loop at that turn and settles with the given
  ## reason — the ABNORMAL endings the server's own loop takes when the wall
  ## clock runs out or the sim faults. It writes the same `stop` record
  ## through the same proc, so a test can RECORD a `wall_clock` or `sim_fault`
  ## episode rather than appending a synthetic record to a healthy one.
  var episode = newEpisode(config)
  var replay = Replay(gameName: GameName, gameVersion: GameVersion)
  episode.seat.policyKind = "scripted"
  episode.seat.baseline = $kind
  episode.seat.policyLabel = $kind
  replay.joins.add((0, episode.seat.name, episode.seat.token))
  replay.chats.add(registerRecord(0, cogAlias(0), $kind, "scripted", $kind))
  replay.configJson = replayConfigJson(episode)

  var
    events: seq[FrameEvent] = @[]
    directives: seq[DirectiveEvent] = @[]
    endRule = erGauntletComplete
    reason = rsComplete
    stopped = false
  while not episode.gauntletDone() and not stopped:
    events.add(episode.beginLevel())
    if episode.level.genFallback:
      replay.chats.add(genFallbackRecord(episode.levelIndex,
        $episode.level.kind, episode.level.seed))
    while not episode.levelDone():
      if stopAfterTurn > 0 and episode.turnsUsed >= stopAfterTurn:
        endRule = stopEndRule
        reason = stopReason
        stopped = true
        replay.chats.add(stopRecord(episode.totalFrames, $endRule))
        break
      var order = scriptedPlanWith(episode.level, tuning,
        config.framesPerTurn, config.fallLethal)
      let turnIndex = episode.turnsUsed + 1
      let played = episode.applyPlan(order.moves)
      order.executed = played.executed
      events.add(played.events)
      for i in 0 ..< played.bytes.len:
        replay.frames.add(ReplayFrame(action: played.bytes[i],
          hash: played.hashes[i]))
      replay.chats.add(boundedDirectiveRecord(order, turnIndex,
        episode.levelIndex, cogAlias(0), ""))
      directives.add(DirectiveEvent(turn: turnIndex,
        level: episode.levelIndex, alias: cogAlias(0), source: $order.source,
        moves: order.moves, executed: order.executed,
        latencyMs: order.latencyMs, repaired: order.repaired))
    if episode.levelOpen:
      replay.frames.add(ReplayFrame(action: ActionLevelBoundary,
        hash: episode.level.foldState(episode.levelIndex)))
      events.add(episode.endLevel())
  episode.settle(reason, endRule)
  events.add(FrameEvent(kind: ekGauntletEnd, level: episode.plan.len,
    frame: episode.totalFrames, value: episode.unseenMilli(),
    extra: episode.seenMilli(), text: $endRule))
  events.add(FrameEvent(kind: ekEnd, level: episode.plan.len,
    frame: episode.totalFrames, text: $reason))
  replay.chats.add(resultRecord(episode))
  ScriptedEpisode(episode: episode, replay: replay, events: events,
    directives: directives)

proc runScriptedEpisode*(config: GameConfig,
                         kind = blPathfinder): ScriptedEpisode =
  runScriptedEpisodeWith(config, kind, tunablesFor(kind))

# ---------------------------------------------------------------------------
#  The tuning ladder — one implementation, so `tools/tune_baselines.nim` and
#  `tests/test_procgen_control.nim` can never measure two different things.
# ---------------------------------------------------------------------------

type
  LadderTotals* = object
    pathfinderMilli*, scavengerMilli*: int
    pathfinderCleared*, scavengerCleared*: int
    episodes*: int

const
  LadderDifficulties* = ["easy", "standard", "hard"]
  LadderSeeds* = 4
  LadderSeedStride* = 977

proc ladderConfig*(difficulty: string, seed: int): GameConfig =
  result = defaultGameConfig()
  result.difficulty = difficulty
  result.seed = seed
  result.levelCount = 8
  result.turnSpacingMs = 0

proc ladderTotals*(pathfinder, scavenger: Tunables): LadderTotals =
  ## The recorded ladder: four seeds on each of the three difficulties — 12
  ## pairs — each pair played twice, once by each baseline, on the SAME seed,
  ## so the margin is a measurement of the policies and not of the draws.
  ## That is 24 episode runs and 12 measurements: `episodes` counts the PAIRS,
  ## which is what `ladderMargin` divides by.
  for difficulty in LadderDifficulties:
    for seed in 1 .. LadderSeeds:
      let config = ladderConfig(difficulty, seed * LadderSeedStride)
      let a = runScriptedEpisodeWith(config, blPathfinder, pathfinder)
      let b = runScriptedEpisodeWith(config, blScavenger, scavenger)
      result.pathfinderMilli = result.pathfinderMilli + a.episode.unseenMilli()
      result.scavengerMilli = result.scavengerMilli + b.episode.unseenMilli()
      result.pathfinderCleared = result.pathfinderCleared +
        a.episode.splitCleared(spUnseen)
      result.scavengerCleared = result.scavengerCleared +
        b.episode.splitCleared(spUnseen)
      inc result.episodes

proc ladderMargin*(totals: LadderTotals): float =
  ## The mean `scores[0]` difference over the whole ladder.
  if totals.episodes == 0:
    return 0.0
  float(totals.pathfinderMilli - totals.scavengerMilli) /
    float(totals.episodes * 1000)
