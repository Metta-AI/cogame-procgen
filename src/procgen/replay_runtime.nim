## Replaying an episode from the recorded bytes alone.
##
## The wasm viewer and the game's own local `/client/replay` route both drive
## this: decode the replay, rebuild the `GameConfig` and the gauntlet plan
## from the recorded config document, RE-GENERATE every level from its seed,
## and re-run `stepFrame` over the recorded action bytes. The per-frame
## `gameHash` is checked against the recorded chain, and the first divergent
## frame is what the viewer's `#mmwarn` reports.
##
## The load-time PRE-SCAN runs the whole episode once, headlessly (at most 480
## frames of integer work over 135 tiles), and records the per-level return
## series, the per-level frame spans, every beat frame and the lull spans —
## which is what lets the SPLIT BAR, the clock and the scrubber beats draw at
## FULL WIDTH on the first frame instead of growing in.

import std/[json, strutils, tables]
import events, levels, replays, sim, tiles

type
  Snapshot* = object
    level*: int                 ## 1-based
    kind*: LevelKind
    grid*: Grid
    cog*: Cell
    lastDir*: Dir
    hunters*: seq[Cell]
    falling*: seq[Cell]
    collected*, collectTotal*: int
    exitAt*: Cell
    exitOpen*: bool
    alive*, finished*: bool
    frameInLevel*: int
    turn*: int
    plan*: string
    planRun*: int
    jumpFuel*, fallDepth*, dashCooldown*: int
    deathCause*: string
    interrupted*: bool

  Beat* = object
    frame*: int
    kind*: string
    label*: string

  TurnSpan* = object
    turn*, level*, executed*: int
    moves*, source*, say*: string

  Playback* = object
    playing*: bool
    speed*: int
    loop*: bool
    skipLulls*: bool
    fastForward*: bool
    frame*: int                 ## absolute render frame
    framesPerStep*: int

  ReplayRuntime* = object
    replay*: Replay
    config*: GameConfig
    episode*: Episode
    snapshots*: seq[Snapshot]
    events*: seq[FrameEvent]
    beats*: seq[Beat]
    lulls*: seq[array[2, int]]
    turns*: seq[TurnSpan]
    fallbacks*: Table[int, string]  ## turn -> cause
    says*: Table[int, string]       ## absolute frame -> text
    levelReturns*: seq[int]
    levelOutcomes*: seq[string]
    levelStartFrames*: seq[int]
    mismatchFrame*: int
    resultsJson*: string
    playback*: Playback
    name*: string
    policyKind*: string
    stopFrame*: int
    stopEndRule*: string

const LullSpanFrames* = 30

proc snapshotOf(episode: Episode, plan: string, planRun: int): Snapshot =
  let st = episode.level
  result.level = episode.levelIndex
  result.kind = st.kind
  result.grid = st.grid
  result.cog = st.cog
  result.lastDir = st.lastDir
  result.hunters = st.hunters
  if st.falling.len == BoardCells:
    for index in 0 ..< BoardCells:
      if st.falling[index]:
        result.falling.add(cellAt(index))
  result.collected = st.collected
  result.collectTotal = st.collectTotal
  result.exitAt = st.exitAt
  result.exitOpen = st.grid.at(st.exitAt) == tExitOpen
  result.alive = st.alive
  result.finished = st.finished
  result.frameInLevel = st.frame
  result.turn = st.levelTurn
  result.plan = plan
  result.planRun = planRun
  result.jumpFuel = st.jumpFuel
  result.fallDepth = st.fallDepth
  result.dashCooldown = st.dashCooldown
  result.deathCause = $st.deathCause
  result.interrupted = st.interrupted

proc beatLabel(kind: string, level, value: int): string =
  case kind
  of "levelstart": "Level " & $level & " starts — click to jump here"
  of "collect": "A collectible is taken — click to jump here"
  of "exitopen": "The exit unlocks — click to jump here"
  of "death": "The cog is killed — click to jump here"
  of "levelend": "Level " & $level & " ends — " & $value &
    " — click to jump here"
  of "fallback": "The seat missed the call — click to jump here"
  of "gauntletend": "The gauntlet is over — click to jump here"
  else: kind

proc ingestChats(rt: var ReplayRuntime) =
  for record in rt.replay.chats:
    if record.len == 0 or record[0] != '{':
      continue
    var node: JsonNode
    try:
      node = parseJson(record)
    except CatchableError:
      continue
    case node{"k"}.getStr()
    of "directive":
      rt.turns.add(TurnSpan(
        turn: node{"turn"}.getInt(0),
        level: node{"level"}.getInt(0),
        executed: node{"executed"}.getInt(0),
        moves: node{"moves"}.getStr(""),
        source: node{"source"}.getStr("scripted"),
        say: node{"say"}.getStr("")))
    of "fallback":
      ## Attempt 1 and attempt 2 both write a record; one turn's missed call
      ## is ONE event, and the last cause is the one that stuck.
      rt.fallbacks[node{"turn"}.getInt(0)] = node{"cause"}.getStr("")
    of "register":
      rt.policyKind = node{"kind"}.getStr("scripted")
    of "stop":
      rt.stopFrame = node{"frame"}.getInt(0)
      rt.stopEndRule = node{"endRule"}.getStr("wall_clock")
    of "result":
      rt.resultsJson = $node{"results"}
    else:
      discard

proc preScan*(rt: var ReplayRuntime) =
  ## Re-simulate the whole episode once, headlessly, from the seed, the
  ## recorded level kinds and seeds, and the recorded action bytes.
  rt.episode = newEpisode(rt.config)
  let planned = plannedFrom(rt.replay)
  if planned.len > 0:
    rt.episode.setPlan(planned)
  rt.mismatchFrame = -1
  var
    absIndex = 0
    turnIndex = -1
    remaining = 0
    planRun = 0
  var startEvents = rt.episode.beginLevel()
  for e in startEvents.mitems:
    e.abs = absIndex
    e.turn = 0
  rt.events.add(startEvents)
  rt.levelStartFrames.add(absIndex)
  rt.snapshots.add(snapshotOf(rt.episode, "", 0))

  for recorded in rt.replay.frames:
    if recorded.action == ActionLevelBoundary:
      ## The boundary byte closes a level. Its hash is the closing level's
      ## own state, so the chain is checked at EVERY recorded frame including
      ## this one (the particle-worlds scar: a load-bearing non-frame fact
      ## must be applied by the same proc on record and on playback).
      if rt.mismatchFrame < 0 and
          rt.episode.level.foldState(rt.episode.levelIndex) != recorded.hash:
        rt.mismatchFrame = absIndex
      var closing = rt.episode.endLevel()
      for e in closing.mitems:
        e.abs = absIndex
      rt.events.add(closing)
      if rt.episode.levelIndex < rt.episode.plan.len:
        var opening = rt.episode.beginLevel()
        inc absIndex
        for e in opening.mitems:
          e.abs = absIndex
        rt.events.add(opening)
        rt.levelStartFrames.add(absIndex)
        rt.snapshots.add(snapshotOf(rt.episode, "", 0))
      continue
    ## Which decision turn does this frame belong to? The `directive` records
    ## carry the turn and how many symbols actually RAN, which is what makes
    ## the plan trail (and the greyed-out unspent tail) re-derivable.
    if remaining <= 0 and turnIndex + 1 < rt.turns.len:
      inc turnIndex
      remaining = max(1, rt.turns[turnIndex].executed)
      planRun = 0
    let
      moves = if turnIndex >= 0 and turnIndex < rt.turns.len:
                rt.turns[turnIndex].moves else: ""
      turnNumber = if turnIndex >= 0 and turnIndex < rt.turns.len:
                     rt.turns[turnIndex].turn else: 0
    var frameEvents = stepFrame(rt.episode.level,
      actionSymbol(recorded.action), rt.episode.levelIndex,
      rt.config.fallLethal)
    inc absIndex
    inc planRun
    dec remaining
    inc rt.episode.totalFrames
    for e in frameEvents.mitems:
      e.abs = absIndex
      e.turn = turnNumber
    rt.events.add(frameEvents)
    if rt.mismatchFrame < 0 and
        rt.episode.level.foldState(rt.episode.levelIndex) != recorded.hash:
      rt.mismatchFrame = absIndex
    if planRun == 1 and turnIndex >= 0:
      if rt.turns[turnIndex].say.len > 0:
        rt.says[absIndex] = rt.turns[turnIndex].say
        rt.events.add(FrameEvent(kind: ekSay, level: rt.episode.levelIndex,
          turn: turnNumber, frame: rt.episode.level.frame, abs: absIndex,
          at: rt.episode.level.cog, text: rt.turns[turnIndex].say))
      if rt.fallbacks.hasKey(turnNumber):
        rt.events.add(FrameEvent(kind: ekFallback,
          level: rt.episode.levelIndex, turn: turnNumber,
          frame: rt.episode.level.frame, abs: absIndex,
          at: rt.episode.level.cog, text: rt.fallbacks[turnNumber]))
    rt.snapshots.add(snapshotOf(rt.episode, moves, planRun))

  if rt.episode.levelOpen:
    var closing = rt.episode.endLevel()
    for e in closing.mitems:
      e.abs = absIndex
    rt.events.add(closing)
  rt.levelReturns = rt.episode.returns
  for outcome in rt.episode.outcomes:
    rt.levelOutcomes.add($outcome)
  rt.events.add(FrameEvent(kind: ekGauntletEnd, level: rt.episode.plan.len,
    frame: absIndex, abs: absIndex, value: rt.episode.unseenMilli(),
    extra: rt.episode.seenMilli(), text: $rt.episode.endRule))

  # Beats: a `collect` beat only for a level's FIRST collectible and for the
  # one that opens the exit, so a 480-frame scrubber stays readable.
  var firstCollect: seq[bool] = newSeq[bool](rt.episode.plan.len + 2)
  for e in rt.events:
    if not isBeatKind(e.kind):
      continue
    if e.kind == ekCollect:
      let opensExit = e.value >= e.extra
      if e.level < firstCollect.len and firstCollect[e.level] and not opensExit:
        continue
      if e.level < firstCollect.len:
        firstCollect[e.level] = true
    rt.beats.add(Beat(frame: e.abs, kind: $e.kind,
      label: beatLabel($e.kind, e.level, e.value)))

  # Lulls: thirty consecutive frames with no collect, death, exitopen,
  # interrupt or levelend event.
  var loud = newSeq[bool](rt.snapshots.len + 1)
  for e in rt.events:
    if e.kind in {ekCollect, ekDeath, ekExitOpen, ekInterrupt, ekLevelEnd} and
        e.abs < loud.len:
      loud[e.abs] = true
  var run = 0
  for frame in 0 ..< loud.len:
    if loud[frame]:
      if run >= LullSpanFrames:
        rt.lulls.add([frame - run, frame - 1])
      run = 0
    else:
      inc run
  if run >= LullSpanFrames:
    rt.lulls.add([loud.len - run, loud.len - 1])

proc loadReplay*(bytes: string): ReplayRuntime =
  result.replay = decodeReplay(bytes)
  result.config = configOf(result.replay)
  result.name = defaultPlayerName(0)
  result.policyKind = "scripted"
  for join in result.replay.joins:
    if join.slot == 0:
      result.name = join.name
  result.stopFrame = -1
  result.fallbacks = initTable[int, string]()
  result.says = initTable[int, string]()
  result.ingestChats()
  result.playback = Playback(playing: true, speed: 1, loop: false,
    skipLulls: false, frame: 0,
    framesPerStep: max(1, result.config.renderFramesPerStep))
  result.preScan()

proc totalFrames*(rt: ReplayRuntime): int =
  max(1, (rt.snapshots.len - 1) * rt.playback.framesPerStep + 1)

proc stepAt*(rt: ReplayRuntime, frame: int): int =
  min(rt.snapshots.len - 1, frame div rt.playback.framesPerStep)

proc inLull*(rt: ReplayRuntime, step: int): bool =
  for span in rt.lulls:
    if step >= span[0] and step <= span[1]:
      return true
  false

proc advance*(rt: var ReplayRuntime) =
  ## One render frame of playback.
  if not rt.playback.playing:
    return
  let last = rt.totalFrames() - 1
  var stepSize = max(1, rt.playback.speed)
  rt.playback.fastForward = false
  if rt.playback.skipLulls and rt.inLull(rt.stepAt(rt.playback.frame)):
    stepSize = stepSize * 4
    rt.playback.fastForward = true
  rt.playback.frame = rt.playback.frame + stepSize
  if rt.playback.frame >= last:
    if rt.playback.loop:
      rt.playback.frame = 0
    else:
      rt.playback.frame = last
      rt.playback.playing = false

proc seekStep*(rt: var ReplayRuntime, step: int) =
  ## The scrubber and every beat button send an ABSOLUTE sim-frame index on
  ## the axis the chrome draws (`st` .. `mx`), exactly as the starter's
  ## global.nim reads `s:<tick>`.
  let last = rt.totalFrames() - 1
  var t = step
  if t < 0: t = 0
  if t > rt.snapshots.len - 1: t = rt.snapshots.len - 1
  rt.playback.frame = min(last, t * rt.playback.framesPerStep)

proc command*(rt: var ReplayRuntime, text: string) =
  ## The transport commands the chrome sends down the same channel the native
  ## client uses.
  if text.len == 0:
    return
  case text[0]
  of ' ': rt.playback.playing = not rt.playback.playing
  of ',': rt.playback.frame = 0
  of 'b': rt.playback.frame = max(0,
            rt.playback.frame - rt.playback.framesPerStep)
  of '.': rt.playback.frame = min(rt.totalFrames() - 1,
            rt.playback.frame + ReplayFps * 5)
  of 'e': rt.playback.frame = rt.totalFrames() - 1
  of 'r': rt.playback.loop = not rt.playback.loop
  of 'f': rt.playback.skipLulls = not rt.playback.skipLulls
  of '1': rt.playback.speed = 1
  of '2': rt.playback.speed = 2
  of '3': rt.playback.speed = 3
  of '4': rt.playback.speed = 4
  of '8': rt.playback.speed = 8
  of '6': rt.playback.speed = 16
  of 's':
    if text.len > 2 and text[1] == ':':
      try:
        rt.seekStep(parseInt(text[2 .. ^1].strip()))
      except ValueError:
        discard
  else: discard
