## `import procgen/sim` sees everything the sim is made of — the starter's
## rule. The COMMANDER layer (`directives`, `llm`, `baselines`, `control`,
## `decide`) is deliberately NOT re-exported here: the wasm replay module
## compiles this file and must not drag in curl.
##
## This module owns the EPISODE: the gauntlet plan, the level lifecycle
## (design note §Turn structure, L1..L8), the plan execution, and the closed
## results document.

import std/[json, unicode]
import gen, levels, path, roster, scoring, seeds, sim_config, sim_state,
       sim_types, tiles, upstream
export gen, levels, path, roster, scoring, seeds, sim_config, sim_state,
       sim_types, tiles, upstream

type
  SeatInfo* = object
    name*: string               ## the REAL policy name — spectator side only
    token*: string
    joined*, registered*, dead*: bool
    policyKind*: string         ## llm | scripted
    policyLabel*: string
    baseline*: string
    llmTurns*, fallbackTurns*, ordersRejected*, saidTurns*: int
    say*: string
    sayFramesLeft*: int
    notes*: string

  EndRule* = enum
    erGauntletComplete = "gauntlet_complete"
    erWallClock = "wall_clock"
    erSimFault = "sim_fault"
    erHostError = "host_error"

  EndReason* = enum
    rsComplete = "complete"
    rsDeadline = "deadline"
    rsFault = "fault"

  PlanResult* = object
    ## What one decision turn's plan did. `bytes` and `hashes` are one entry
    ## per SIM FRAME — this game's entire input log.
    executed*: int
    events*: seq[FrameEvent]
    bytes*: seq[uint8]
    hashes*: seq[uint64]
    interrupted*: bool

  Episode* = object
    config*: GameConfig
    plan*: seq[PlannedLevel]
    levelIndex*: int            ## 1-based; 0 before the first level starts
    level*: LevelState
    levelOpen*: bool
    outcomes*: seq[LevelOutcome]
    returns*: seq[int]
    levelFrames*: seq[int]
    collectedPer*: seq[int]
    collectTotals*: seq[int]
    deathCauses*: seq[string]
    seat*: SeatInfo
    over*: bool
    reason*: EndReason
    endRule*: EndRule
    stopDetail*: string
    planInterrupts*: int
    genFallbacks*: int
    totalFrames*: int
    turnsUsed*: int

proc cutRunes*(text: string, limit: int): string =
  ## Rune-boundary truncation for the one string this module records itself
  ## (`stopDetail`). Every other capped field goes through
  ## `src/procgen/directives.nim`'s `truncateRunes`; both cut on a RUNE
  ## boundary, never a byte index.
  if limit <= 0: return ""
  if text.runeLen <= limit: return text
  text.runeSubStr(0, limit)

proc difficultyOf*(config: GameConfig): Difficulty =
  case normalizedDifficulty(config.difficulty)
  of "easy": dfEasy
  of "hard": dfHard
  else: dfStandard

proc newEpisode*(config: GameConfig): Episode =
  result.config = config
  result.plan = drawGauntletPlan(config.seed, config.levelCount)
  result.levelIndex = 0
  result.levelOpen = false
  result.reason = rsComplete
  result.endRule = erGauntletComplete
  for i in 0 ..< result.plan.len:
    result.outcomes.add(loUnplayed)
    result.returns.add(0)
    result.levelFrames.add(0)
    result.collectedPer.add(0)
    result.collectTotals.add(collectTotalFor(result.plan[i].kind))
    result.deathCauses.add("")
  result.seat.name =
    if config.playerNames.len > 0 and config.playerNames[0].len > 0:
      config.playerNames[0]
    else:
      defaultPlayerName(0)
  result.seat.token = if config.tokens.len > 0: config.tokens[0] else: ""
  result.seat.policyKind = "scripted"
  result.seat.baseline = "pathfinder"
  result.seat.policyLabel = "pathfinder"

proc setPlan*(episode: var Episode, planned: seq[PlannedLevel]) =
  ## Replaces the drawn plan with the one a REPLAY recorded, and resizes the
  ## level-indexed arrays with it. The recorded plan is authoritative on
  ## playback: it is what the viewer re-generates the levels from.
  episode.plan = planned
  episode.outcomes = @[]
  episode.returns = @[]
  episode.levelFrames = @[]
  episode.collectedPer = @[]
  episode.collectTotals = @[]
  episode.deathCauses = @[]
  for i in 0 ..< planned.len:
    episode.outcomes.add(loUnplayed)
    episode.returns.add(0)
    episode.levelFrames.add(0)
    episode.collectedPer.add(0)
    episode.collectTotals.add(collectTotalFor(planned[i].kind))
    episode.deathCauses.add("")

proc alias*(episode: Episode): string = cogAlias(0)

proc levelCount*(episode: Episode): int = episode.plan.len

proc currentPlanned*(episode: Episode): PlannedLevel =
  if episode.levelIndex >= 1 and episode.levelIndex <= episode.plan.len:
    return episode.plan[episode.levelIndex - 1]
  PlannedLevel(kind: lkMaze, split: spSeen, seed: 0)

# ---------------------------------------------------------------------------
#  The level lifecycle — design note §Turn structure, L1 .. L8
# ---------------------------------------------------------------------------

proc beginLevel*(episode: var Episode): seq[FrameEvent] =
  ## L1..L5. Nothing is DRAWN here: the plan was drawn before the first turn
  ## and before any seat connected.
  if episode.levelIndex >= episode.plan.len:
    return @[]
  inc episode.levelIndex
  let planned = episode.plan[episode.levelIndex - 1]
  episode.level = newLevel(planned.kind, planned.seed,
    episode.config.difficultyOf())
  episode.levelOpen = true
  if episode.level.genFallback:
    inc episode.genFallbacks
  result.add(FrameEvent(kind: ekLevelStart, level: episode.levelIndex,
    frame: 0, at: episode.level.start, to: episode.level.exitAt,
    value: episode.plan.len, extra: episode.level.startDist,
    text: $planned.kind))

proc outcomeOf*(episode: Episode): LevelOutcome =
  if episode.level.finished: loCleared
  elif not episode.level.alive: loDied
  else: loTimeup

proc endLevel*(episode: var Episode): seq[FrameEvent] =
  ## L7. Computes the level's return and records it. A level that ended early
  ## forfeits its remaining turns; they are never reallocated.
  if not episode.levelOpen or episode.levelIndex < 1:
    return @[]
  let index = episode.levelIndex - 1
  let value = returnMilli(episode.level.collected, episode.level.collectTotal,
    episode.level.startDist, episode.level.bestDist, episode.level.finished)
  episode.outcomes[index] = episode.outcomeOf()
  episode.returns[index] = value
  episode.levelFrames[index] = episode.level.frame
  episode.collectedPer[index] = episode.level.collected
  episode.collectTotals[index] = episode.level.collectTotal
  episode.deathCauses[index] = $episode.level.deathCause
  episode.levelOpen = false
  result.add(FrameEvent(kind: ekLevelEnd, level: episode.levelIndex,
    frame: episode.level.frame, at: episode.level.cog,
    value: value, extra: episode.level.collected,
    text: $episode.outcomes[index]))

proc levelDone*(episode: Episode): bool =
  ## L6's exit condition: cleared, dead, or out of turns.
  if not episode.levelOpen:
    return true
  episode.level.finished or (not episode.level.alive) or
    episode.level.levelTurn >= episode.config.turnsPerLevel

proc gauntletDone*(episode: Episode): bool =
  (not episode.levelOpen) and episode.levelIndex >= episode.plan.len

proc applyPlan*(episode: var Episode, moves: string): PlanResult =
  ## One decision turn's plan, executed ONE SYMBOL PER SIM FRAME, in order,
  ## and cut short the moment the danger interrupt fires. This is the only
  ## caller of `stepFrame`.
  if not episode.levelOpen:
    return
  inc episode.level.levelTurn
  inc episode.turnsUsed
  episode.level.spikeAdjacentAtPlan = episode.level.spikeAdjacent(
    episode.level.cog)
  let limit = min(moves.len, episode.config.framesPerTurn)
  for i in 0 ..< limit:
    let symbol = moves[i]
    result.events.add(stepFrame(episode.level, symbol, episode.levelIndex,
      episode.config.fallLethal))
    result.bytes.add(actionByte(symbol))
    result.hashes.add(episode.level.foldState(episode.levelIndex))
    inc result.executed
    inc episode.totalFrames
    if episode.level.finished or not episode.level.alive:
      break
    if episode.config.interruptOnDanger and episode.level.interrupted:
      inc episode.planInterrupts
      result.interrupted = true
      break

# ---------------------------------------------------------------------------
#  Scoring — design note §Scoring formula and sign
# ---------------------------------------------------------------------------

proc splitMilli*(episode: Episode, split: Split): int =
  var
    values: seq[int] = @[]
    count = 0
  for i in 0 ..< episode.plan.len:
    if episode.plan[i].split == split:
      inc count
      values.add(episode.returns[i])
  meanMilli(values, count)

proc unseenMilli*(episode: Episode): int = episode.splitMilli(spUnseen)
proc seenMilli*(episode: Episode): int = episode.splitMilli(spSeen)
proc gap*(episode: Episode): int =
  gapMilli(episode.seenMilli(), episode.unseenMilli())

proc splitCleared*(episode: Episode, split: Split): int =
  for i in 0 ..< episode.plan.len:
    if episode.plan[i].split == split and episode.outcomes[i] == loCleared:
      inc result

proc score*(episode: Episode): float =
  ## THE league number: the mean return over the UNSEEN levels, and nothing
  ## else. `0.000 .. 1.000`, higher better.
  float(episode.unseenMilli()) / 1000.0

proc winFlag*(episode: Episode): bool =
  ## True only when EVERY unseen level ended `cleared`.
  var any = false
  for i in 0 ..< episode.plan.len:
    if episode.plan[i].split != spUnseen:
      continue
    any = true
    if episode.outcomes[i] != loCleared:
      return false
  any

proc gauntletLine*(episode: Episode): string =
  ## The one-line summary the clock caption and the endcard show.
  $episode.plan.len & " levels · " & normalizedDifficulty(
    episode.config.difficulty) & " · " &
    $episode.splitCleared(spSeen) & " seen / " &
    $episode.splitCleared(spUnseen) & " unseen cleared"

proc procgenResultsJson*(episode: Episode): string =
  ## The CLOSED results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and `tools/ci/docker_smoke.sh`'s expected-key
  ## set IN THE SAME COMMIT — Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    kinds = newJArray()
    splits = newJArray()
    seedsJson = newJArray()
    returnsJson = newJArray()
    outcomes = newJArray()
    causes = newJArray()
    framesJson = newJArray()
    collected = newJArray()
    totals = newJArray()
    policyKinds = newJArray()
    deadSeats = newJArray()
  names.add(%episode.seat.name)
  aliases.add(%cogAlias(0))
  scores.add(%episode.score())
  win.add(%episode.winFlag())
  policyKinds.add(%episode.seat.policyKind)
  deadSeats.add(%episode.seat.dead)
  for i in 0 ..< episode.plan.len:
    kinds.add(%($episode.plan[i].kind))
    splits.add(%($episode.plan[i].split))
    seedsJson.add(%episode.plan[i].seed)
    returnsJson.add(%episode.returns[i])
    outcomes.add(%($episode.outcomes[i]))
    causes.add(%episode.deathCauses[i])
    framesJson.add(%episode.levelFrames[i])
    collected.add(%episode.collectedPer[i])
    totals.add(%episode.collectTotals[i])
  $(%*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "reason": $episode.reason,
    "endRule": $episode.endRule,
    "variant": (if episode.plan.len == 4: "sprint"
                elif normalizedDifficulty(episode.config.difficulty) == "hard":
                  "hardpool"
                else: "gauntlet"),
    "difficulty": normalizedDifficulty(episode.config.difficulty),
    "seed": episode.config.seed,
    "levelCount": episode.plan.len,
    "levelKinds": kinds,
    "levelSplit": splits,
    "levelSeeds": seedsJson,
    "levelReturns": returnsJson,
    "levelOutcome": outcomes,
    "levelDeathCause": causes,
    "levelFrames": framesJson,
    "levelCollected": collected,
    "levelCollectTotal": totals,
    "seenMilli": episode.seenMilli(),
    "unseenMilli": episode.unseenMilli(),
    "gapMilli": episode.gap(),
    "seenCleared": episode.splitCleared(spSeen),
    "unseenCleared": episode.splitCleared(spUnseen),
    "policyKinds": policyKinds,
    "llmTurns": episode.seat.llmTurns,
    "fallbackTurns": episode.seat.fallbackTurns,
    "ordersRejected": episode.seat.ordersRejected,
    "planInterrupts": episode.planInterrupts,
    "genFallbacks": episode.genFallbacks,
    "deadSeats": deadSeats,
    "stopDetail": episode.stopDetail.cutRunes(MaxStopDetailRunes)
  })

proc settle*(episode: var Episode, reason: EndReason, endRule: EndRule,
             detail = "") =
  episode.reason = reason
  episode.endRule = endRule
  if detail.len > 0:
    episode.stopDetail = detail
  episode.over = true
