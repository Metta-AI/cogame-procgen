## The four archetypes, the level state, and the frame resolver.
##
## `applyAction`, `passable`, `hunterStep` and `willFall` have EXACTLY ONE
## implementation each and are called by the resolver, the observation
## builder, both baselines, the generator validators and the viewer pre-scan,
## so no consumer can disagree with the rules (the escrow 2026-08-23 lesson).
##
## `stepFrame` implements the design note's frame-resolution steps 1 to 10
## verbatim, and it is the ONLY thing that mutates a level.
##
## Integer arithmetic only: no float literal, no division operator and no
## square root appears in this file (design note §Sim module -> Determinism).

import path, sim_state, tiles

type
  LevelKind* = enum
    lkMaze = "maze"
    lkChaser = "chaser"
    lkClimber = "climber"
    lkMiner = "miner"

  Difficulty* = enum
    dfEasy = "easy"
    dfStandard = "standard"
    dfHard = "hard"

  DeathCause* = enum
    dcNone = ""
    dcCaught = "caught"
    dcFell = "fell"
    dcSpiked = "spiked"
    dcCrushed = "crushed"

  LevelOutcome* = enum
    loCleared = "cleared"
    loDied = "died"
    loTimeup = "timeup"
    loUnplayed = "unplayed"

  DiffTable* = object
    ## One integer table per archetype and nothing more (design note
    ## §The game -> Archetypes).
    braidCount*, pillarCount*, hunterCount*: int
    spikeCount*, boulderCount*, bedrockPct*: int

  EventKind* = enum
    ## The CLOSED broadcast vocabulary: sixteen derived kinds plus `end`.
    ## `tests/test_procgen_events.nim` asserts the emitted set is exactly
    ## these seventeen.
    ekGameStart = "gamestart"
    ekLevelStart = "levelstart"
    ekPlan = "plan"
    ekStep = "step"
    ekCollect = "collect"
    ekDig = "dig"
    ekPush = "push"
    ekFall = "fall"
    ekHunter = "hunter"
    ekInterrupt = "interrupt"
    ekDeath = "death"
    ekExitOpen = "exitopen"
    ekLevelEnd = "levelend"
    ekSay = "say"
    ekFallback = "fallback"
    ekGauntletEnd = "gauntletend"
    ekEnd = "end"

  FrameEvent* = object
    kind*: EventKind
    level*, turn*, frame*: int
    abs*: int                   ## absolute sim-frame index over the episode,
                                ## stamped by the replay pre-scan
    at*, to*: Cell
    value*, extra*: int
    text*: string

  LevelState* = object
    ## One level, and everything a frame may touch.
    kind*: LevelKind
    difficulty*: Difficulty
    seed*: int
    grid*: Grid
    start*: Cell
    cog*: Cell
    lastDir*: Dir
    jumpFuel*, fallDepth*, dashCooldown*: int
    hunters*: seq[Cell]
    falling*: seq[bool]           ## per-cell, `miner`'s falling entities
    collected*, collectTotal*: int
    alive*, finished*: bool
    frame*, levelTurn*: int
    startDist*, bestDist*: int
    exitAt*: Cell
    deathCause*: DeathCause
    interrupted*: bool
    spikeAdjacentAtPlan*: bool
      ## The plan-time half of the fourth danger-interrupt condition: "the cog
      ## stands adjacent to a Spike IT DID NOT SEE at plan time".
    genFallback*: bool

const
  DirNames* = ["L", "R", "U", "D"]
  DashCooldownFrames* = 4
  JumpFuelFrames* = 2
  FallLethalDefault* = 4
  MaxRedrawAttempts* = 40
  HunterRestModulo* = 3
    ## Hunters do NOT move on frames where `frame mod 3 == 0`, so the cog is
    ## strictly faster: three cog steps per two hunter steps.

proc difficultyTable*(kind: LevelKind, d: Difficulty): DiffTable =
  ## One integer table per archetype per difficulty, and nothing else.
  case kind
  of lkMaze:
    case d
    of dfEasy: DiffTable(braidCount: 8)
    of dfStandard: DiffTable(braidCount: 4)
    of dfHard: DiffTable(braidCount: 1)
  of lkChaser:
    case d
    of dfEasy: DiffTable(pillarCount: 6, hunterCount: 1)
    of dfStandard: DiffTable(pillarCount: 10, hunterCount: 2)
    of dfHard: DiffTable(pillarCount: 14, hunterCount: 3)
  of lkClimber:
    case d
    of dfEasy: DiffTable(spikeCount: 1)
    of dfStandard: DiffTable(spikeCount: 3)
    of dfHard: DiffTable(spikeCount: 5)
  of lkMiner:
    case d
    of dfEasy: DiffTable(boulderCount: 3, bedrockPct: 6)
    of dfStandard: DiffTable(boulderCount: 6, bedrockPct: 10)
    of dfHard: DiffTable(boulderCount: 9, bedrockPct: 14)

proc collectTotalFor*(kind: LevelKind): int =
  if kind == lkChaser: 8 else: 4

# ---------------------------------------------------------------------------
#  The predicates. ONE implementation each.
# ---------------------------------------------------------------------------

proc passable*(kind: LevelKind, t: Tile): bool =
  ## Can the cog ENTER a cell holding this tile? `Dirt` is entered by digging
  ## in `miner`; a `Boulder` is entered only by pushing it, which is a
  ## separate rule in `applyAction`.
  case t
  of tEmpty, tGem, tPellet, tExitOpen, tLadder, tSpike: true
  of tDirt: kind == lkMiner
  of tWall, tPlatform, tExitLocked, tBoulder: false

proc supported*(st: LevelState, c: Cell): bool =
  ## `climber` gravity: a cog on a `Ladder`, or with something solid — or a
  ## ladder — directly below it, does not fall.
  if st.grid.at(c) == tLadder:
    return true
  let below = st.grid.at(cell(c.x, c.y + 1))
  below.solid() or below == tLadder

proc willFall*(st: LevelState, c: Cell): bool =
  ## The inverse of `supported`, named as the design note names it so the
  ## baselines read the rule rather than re-deriving it.
  st.kind == lkClimber and not st.supported(c)

proc routeCost*(kind: LevelKind, digCost: int): TileCost =
  ## The BASELINE's routing table: what a scripted plan is willing to walk
  ## through, and what each tile costs it.
  for t in Tile.low .. Tile.high:
    result[t] = -1
  result[tEmpty] = 1
  result[tGem] = 1
  result[tPellet] = 1
  result[tExitOpen] = 1
  result[tLadder] = 1
  if kind == lkMiner:
    result[tDirt] = max(1, digCost)
    result[tBoulder] = 4
  ## Spikes are passable and LETHAL, so a route never goes through one.

proc progressCost*(kind: LevelKind): TileCost =
  ## The PROGRESS table: the archetype's dig-and-push-inclusive passability,
  ## which is what `startDist` and `bestDist` are measured over. The exit is
  ## reachable whether or not it is unlocked, because the distance to it is
  ## the measurement.
  result = routeCost(kind, 1)
  result[tSpike] = 1
  result[tExitLocked] = 1
  if kind == lkMiner:
    result[tBoulder] = 1

proc hunterCost*(): TileCost =
  ## Hunters walk the open floor. They never dig, never push and never climb.
  for t in Tile.low .. Tile.high:
    result[t] = -1
  result[tEmpty] = 1
  result[tGem] = 1
  result[tPellet] = 1
  result[tExitOpen] = 1
  result[tExitLocked] = 1
  result[tSpike] = 1

proc ladderOnly*(kind: LevelKind): bool = kind == lkClimber

proc distanceToExit*(st: LevelState): int =
  let field = distField(st.grid, progressCost(st.kind), st.cog, @[],
    ladderOnly(st.kind))
  field.distTo(st.exitAt)

proc hunterStepWith*(st: LevelState, field: seq[int], hunter: Cell): Cell =
  ## One hunter's step against an already-computed distance field. THE
  ## movement rule; `hunterStep` below is the one-shot convenience wrapper the
  ## baselines call, and both go through this.
  var
    best = hunter
    bestCost = field.distTo(hunter)
  let cost = hunterCost()
  for d in DirOrder:
    let target = hunter.step(d)
    if not target.inBounds():
      continue
    if cost[st.grid.at(target)] < 0:
      continue
    let candidate = field.distTo(target)
    if candidate < bestCost:
      bestCost = candidate
      best = target
  best

proc hunterField*(st: LevelState): seq[int] =
  distField(st.grid, hunterCost(), st.cog)

proc hunterStep*(st: LevelState, hunter: Cell): Cell =
  ## One hunter's step: one cell along a shortest path to the cog, ties broken
  ## in the fixed order L, R, U, D. ONE implementation, called by the resolver
  ## and by `chaser`'s baseline veto.
  st.hunterStepWith(st.hunterField(), hunter)

proc hunterNear*(st: LevelState, c: Cell, distance: int): bool =
  ## Chebyshev proximity to any hunter — the `chaser` interrupt condition and
  ## the `chaser` baseline veto, one predicate.
  for h in st.hunters:
    if abs(h.x - c.x) <= distance and abs(h.y - c.y) <= distance:
      return true
  false

proc spikeAdjacent*(st: LevelState, c: Cell): bool =
  for d in DirOrder:
    if st.grid.at(c.step(d)) == tSpike:
      return true
  false

proc boulderOverhead*(st: LevelState, c: Cell): bool =
  ## `miner`'s interrupt condition: a boulder marked `falling` in the cog's
  ## column, at most three tiles above it, with only `Empty` between.
  for up in 1 .. 3:
    let above = cell(c.x, c.y - up)
    if not above.inBounds():
      return false
    let t = st.grid.at(above)
    if t == tBoulder:
      return st.falling.len == BoardCells and st.falling[above.cellIndex()]
    if t != tEmpty:
      return false
  false

# ---------------------------------------------------------------------------
#  Actions
# ---------------------------------------------------------------------------

type
  ActionEffect* = enum
    aeMove = "move"
    aeDig = "dig"
    aeDigInPlace = "dig_in_place"
    aePush = "push"
    aeJump = "jump"
    aeDash = "dash"
    aeClimb = "climb"
    aeCollect = "collect"
    aeExit = "exit"
    aeWait = "wait"
    aeBlocked = "blocked"

  ActionPlan* = object
    ## What one symbol WOULD do, computed by the resolver's own rules. The
    ## observation's `actions[]` is exactly this for all six symbols, so the
    ## precomputed legal choice set can never claim something the resolver
    ## disagrees with (the escrow fix for formal-output fallback rates).
    symbol*: char
    legal*: bool
    target*: Cell
    effect*: ActionEffect
    kills*: bool

proc applyAction*(st: LevelState, symbol: char): ActionPlan =
  ## THE action resolver. Pure: it reads the level and reports what the symbol
  ## means; `stepFrame` is the only thing that applies it.
  result.symbol = symbol
  result.target = st.cog
  result.effect = aeWait
  result.legal = true
  let parsed = parseDir(symbol)
  if parsed.ok:
    let
      d = parsed.dir
      target = st.cog.step(d)
      t = st.grid.at(target)
    result.target = target
    if st.kind == lkClimber and (d == dU or d == dD) and
        st.grid.at(st.cog) != tLadder and t != tLadder:
      result.legal = false
      result.effect = aeBlocked
      result.target = st.cog
      return
    if st.kind == lkMiner and t == tDirt:
      result.effect = aeDig
      return
    if st.kind == lkMiner and t == tBoulder:
      let beyond = target.step(d)
      if (d == dL or d == dR) and st.grid.at(beyond) == tEmpty:
        result.effect = aePush
        return
      result.legal = false
      result.effect = aeBlocked
      result.target = st.cog
      return
    if not passable(st.kind, t):
      result.legal = false
      result.effect = aeBlocked
      result.target = st.cog
      return
    result.effect =
      if t == tExitOpen: aeExit
      elif t.collectible(): aeCollect
      elif t == tLadder and (d == dU or d == dD): aeClimb
      else: aeMove
    result.kills = t == tSpike or st.hunterNear(target, 0)
    return
  if symbol == 'X':
    case st.kind
    of lkMaze:
      result.effect = aeWait
    of lkChaser:
      if st.dashCooldown > 0:
        result.effect = aeWait
      else:
        let
          one = st.cog.step(st.lastDir)
          two = one.step(st.lastDir)
        if passable(st.kind, st.grid.at(one)) and
            passable(st.kind, st.grid.at(two)):
          result.effect = aeDash
          result.target = two
          result.kills = st.grid.at(two) == tSpike
        else:
          result.legal = false
          result.effect = aeBlocked
    of lkClimber:
      result.effect = aeJump
    of lkMiner:
      let target = st.cog.step(st.lastDir)
      if st.grid.at(target) == tDirt:
        result.effect = aeDigInPlace
        result.target = target
      else:
        result.legal = false
        result.effect = aeBlocked
    return
  result.effect = aeWait

# ---------------------------------------------------------------------------
#  The frame resolver: design note §Turn structure, steps 1 to 10.
# ---------------------------------------------------------------------------

proc collect(st: var LevelState, events: var seq[FrameEvent], levelIndex: int) =
  let t = st.grid.at(st.cog)
  if not t.collectible():
    return
  st.grid.setTile(st.cog, tEmpty)
  inc st.collected
  events.add(FrameEvent(kind: ekCollect, level: levelIndex, frame: st.frame,
    at: st.cog, value: st.collected, extra: st.collectTotal,
    text: (if t == tGem: "gem" else: "pellet")))
  if st.collected >= st.collectTotal and st.grid.at(st.exitAt) == tExitLocked:
    st.grid.setTile(st.exitAt, tExitOpen)
    events.add(FrameEvent(kind: ekExitOpen, level: levelIndex,
      frame: st.frame, at: st.exitAt))

proc die(st: var LevelState, cause: DeathCause, events: var seq[FrameEvent],
         levelIndex: int) =
  if not st.alive:
    return
  st.alive = false
  st.deathCause = cause
  events.add(FrameEvent(kind: ekDeath, level: levelIndex, frame: st.frame,
    at: st.cog, text: $cause))

proc minerFallScan(st: var LevelState, events: var seq[FrameEvent],
                   levelIndex: int) =
  ## The falling scan, in the FIXED order bottom row to top row, left to
  ## right: any `Boulder` or `Gem` with `Empty` directly below moves down one
  ## tile and is marked `falling`; a marked entity that can no longer fall is
  ## unmarked. One tile per entity per frame.
  var moved = newSeq[bool](BoardCells)
  for y in countdown(BoardH - 2, 1):
    for x in 1 .. BoardW - 2:
      let
        here = cell(x, y)
        index = here.cellIndex()
      if moved[index]:
        continue
      let t = st.grid.at(here)
      if t != tBoulder and t != tGem:
        continue
      let below = cell(x, y + 1)
      if st.grid.at(below) != tEmpty:
        st.falling[index] = false
        continue
      st.grid.setTile(here, tEmpty)
      st.grid.setTile(below, t)
      st.falling[index] = false
      st.falling[below.cellIndex()] = true
      moved[below.cellIndex()] = true
      events.add(FrameEvent(kind: ekFall, level: levelIndex, frame: st.frame,
        at: here, to: below, text: (if t == tBoulder: "boulder" else: "gem")))
      if t == tBoulder and below == st.cog:
        st.die(dcCrushed, events, levelIndex)

proc dangerInterrupt*(st: LevelState): bool =
  ## Design note §Sim module -> Danger interrupt. Evaluated at the end of
  ## frame-resolution step 9 and nowhere else. `maze` never interrupts.
  if not st.alive or st.finished:
    return false
  case st.kind
  of lkMaze: discard
  of lkChaser:
    if st.hunterNear(st.cog, 1):
      return true
  of lkClimber:
    if not st.supported(st.cog) and st.fallDepth >= 2:
      return true
  of lkMiner:
    if st.boulderOverhead(st.cog):
      return true
  if st.spikeAdjacent(st.cog) and not st.spikeAdjacentAtPlan:
    return true
  false

proc foldState*(st: LevelState, levelIndex: int): uint64 =
  ## The per-frame integrity hash: the whole level state, folded. The viewer
  ## checks the chain and shows `#mmwarn` on the first divergent frame.
  result = newHash()
  result.fold(levelIndex)
  result.fold(st.frame)
  ## `levelTurn` is deliberately NOT folded: a turn boundary is a fact about
  ## the DECISION cadence, not about the level, and the replay re-derives the
  ## frames without re-deriving the turns.
  result.fold(ord(st.kind))
  result.fold(st.cog.x)
  result.fold(st.cog.y)
  result.fold(ord(st.lastDir))
  result.fold(st.jumpFuel)
  result.fold(st.fallDepth)
  result.fold(st.dashCooldown)
  result.fold(st.collected)
  result.fold(if st.alive: 1 else: 0)
  result.fold(if st.finished: 1 else: 0)
  result.fold(st.hunters.len)
  for h in st.hunters:
    result.fold(h.x)
    result.fold(h.y)
  for index in 0 ..< BoardCells:
    result.fold(ord(st.grid.cells[index]))
    if st.falling.len == BoardCells and st.falling[index]:
      result.fold(7)

proc stepFrame*(st: var LevelState, symbol: char, levelIndex: int,
                fallLethal: int): seq[FrameEvent] =
  ## ONE sim frame: one primitive symbol resolved. This is the whole physics
  ## of the game; nothing else mutates a level.
  var events: seq[FrameEvent] = @[]
  if not st.alive or st.finished:
    return events

  # 1. frame += 1; 2. intent.
  inc st.frame
  let parsed = parseDir(symbol)
  if parsed.ok:
    ## `L R U D` set `last_dir` WHETHER OR NOT the move succeeds — naming a
    ## direction is how you aim a dig or a dash.
    st.lastDir = parsed.dir
  let plan = applyAction(st, symbol)

  # 3. Cog move (and the archetype's one-frame terrain edits).
  let from0 = st.cog
  case plan.effect
  of aeBlocked:
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: from0, text: "blocked", value: ord(symbol)))
  of aeDig:
    st.grid.setTile(plan.target, tEmpty)
    st.cog = plan.target
    events.add(FrameEvent(kind: ekDig, level: levelIndex, frame: st.frame,
      at: plan.target))
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: st.cog, value: ord(symbol)))
  of aeDigInPlace:
    st.grid.setTile(plan.target, tEmpty)
    events.add(FrameEvent(kind: ekDig, level: levelIndex, frame: st.frame,
      at: plan.target))
  of aePush:
    let beyond = plan.target.step(st.lastDir)
    st.grid.setTile(beyond, tBoulder)
    st.grid.setTile(plan.target, tEmpty)
    st.falling[beyond.cellIndex()] = false
    st.cog = plan.target
    events.add(FrameEvent(kind: ekPush, level: levelIndex, frame: st.frame,
      at: plan.target, to: beyond))
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: st.cog, value: ord(symbol)))
  of aeDash:
    st.cog = plan.target
    st.dashCooldown = DashCooldownFrames
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: st.cog, text: "dash", value: ord(symbol)))
  of aeJump:
    st.jumpFuel = JumpFuelFrames
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: from0, text: "jump", value: ord(symbol)))
  of aeWait:
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: from0, text: "wait", value: ord(symbol)))
  else:
    st.cog = plan.target
    events.add(FrameEvent(kind: ekStep, level: levelIndex, frame: st.frame,
      at: from0, to: st.cog, value: ord(symbol)))

  # 4. Collect.
  st.collect(events, levelIndex)

  # 5. Archetype physics — exactly one hook per archetype.
  case st.kind
  of lkMaze:
    discard
  of lkChaser:
    if st.dashCooldown > 0:
      dec st.dashCooldown
    if st.frame mod HunterRestModulo != 0:
      let field = st.hunterField()
      for i in 0 ..< st.hunters.len:
        let moved = st.hunterStepWith(field, st.hunters[i])
        if not (moved == st.hunters[i]):
          events.add(FrameEvent(kind: ekHunter, level: levelIndex,
            frame: st.frame, at: st.hunters[i], to: moved, value: i))
          st.hunters[i] = moved
  of lkClimber:
    if st.jumpFuel > 0:
      let above = cell(st.cog.x, st.cog.y - 1)
      if not st.grid.at(above).solid():
        st.cog = above
      dec st.jumpFuel
      st.fallDepth = 0
    elif not st.supported(st.cog):
      st.cog = cell(st.cog.x, st.cog.y + 1)
      inc st.fallDepth
      events.add(FrameEvent(kind: ekFall, level: levelIndex, frame: st.frame,
        at: from0, to: st.cog, text: "cog", value: st.fallDepth))
    else:
      st.fallDepth = 0
    st.collect(events, levelIndex)
  of lkMiner:
    st.minerFallScan(events, levelIndex)

  # 6. Hazards, evaluated after physics.
  if st.alive:
    if st.hunterNear(st.cog, 0):
      st.die(dcCaught, events, levelIndex)
    elif st.grid.at(st.cog) == tSpike:
      st.die(dcSpiked, events, levelIndex)
    elif st.fallDepth > fallLethal or st.cog.y >= BoardH - 1:
      st.die(dcFell, events, levelIndex)

  # 7. Exit.
  if st.alive and st.grid.at(st.cog) == tExitOpen:
    st.finished = true

  # 8. Progress — the only measurement the score reads besides `collected`
  #    and `finished`, over the same search every other consumer uses.
  if st.alive:
    let d = st.distanceToExit()
    if d < st.bestDist:
      st.bestDist = d

  # 9. The danger interrupt (recorded by the caller as the turn's `executed`).
  st.interrupted = st.dangerInterrupt()
  if st.interrupted:
    events.add(FrameEvent(kind: ekInterrupt, level: levelIndex,
      frame: st.frame, at: st.cog, text: $st.kind))
  events

proc newLevelState*(kind: LevelKind, difficulty: Difficulty, seed: int,
                    grid: Grid, start, exitAt: Cell,
                    hunters: seq[Cell]): LevelState =
  result.kind = kind
  result.difficulty = difficulty
  result.seed = seed
  result.grid = grid
  result.start = start
  result.cog = start
  result.exitAt = exitAt
  result.hunters = hunters
  result.lastDir = dR
  result.alive = true
  result.finished = false
  result.collected = 0
  result.collectTotal = collectTotalFor(kind)
  result.falling = newSeq[bool](BoardCells)
  result.startDist = max(1, result.distanceToExit())
  result.bestDist = result.startDist
