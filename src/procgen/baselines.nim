## The two scripted baselines, `pathfinder` and `scavenger`.
##
## Both emit the SAME object an LLM emits (`{"moves","say","notes"}`), on the
## same cadence, so the two policy kinds are strictly comparable and one
## validator covers both — which is what makes the bounded-orders test in
## `tests/test_procgen_control.nim` meaningful. Both are PURE FUNCTIONS of the
## level state with no RNG.
##
## Every veto here is computed by running the RESOLVER'S OWN `stepFrame` over
## a scratch copy of the level, so a symbol the baseline rejects as fatal is
## exactly a symbol the resolver would have killed the cog for. That is what
## stops a second copy of the rules appearing (design note §The two scripted
## baselines).

import std/strutils
import directives, levels, path, sim_types, tiles

type
  Baseline* = enum
    blPathfinder = "pathfinder"
    blScavenger = "scavenger"

  Tunables* = object
    lookaheadFrames*: int       ## hunter / boulder projection depth
    digCost*: int               ## BFS weight of a Dirt tile in `miner`
    commitFrames*: int          ## symbols emitted per turn
    detourBudget*: int          ## extra steps accepted to avoid a hazard
    exitFirst*: bool            ## route to the exit while collectibles remain

const
  ## THE SWEPT PICK, not a guess. `tools/tune_baselines.nim --sweep` plays a
  ## fixed 24-episode ladder over a bounded matrix and prints each candidate's
  ## margin; these are the numbers that won it, recorded in
  ## `tools/ci/baseline_tuning.json` and asserted by
  ## `tests/test_procgen_control.nim`.
  PathfinderTunables* = Tunables(lookaheadFrames: 6, digCost: 3,
    commitFrames: 6, detourBudget: 6, exitFirst: false)
  ## `scavenger`'s knobs are the design note's table and are deliberately NOT
  ## optimised: it is the player a champion should be able to beat, so tuning
  ## it for the margin would measure the wrong thing.
  ScavengerTunables* = Tunables(lookaheadFrames: 1, digCost: 1,
    commitFrames: 6, detourBudget: 0, exitFirst: false)

proc parseBaseline*(text: string): Baseline =
  ## Anything unrecognised is the published default — the starter's rule.
  case text.strip().toLowerAscii()
  of "scavenger": blScavenger
  else: blPathfinder

proc tunablesFor*(kind: Baseline): Tunables =
  case kind
  of blPathfinder: PathfinderTunables
  of blScavenger: ScavengerTunables

proc fatalSymbol*(st: LevelState, symbol: char, fallLethal: int): bool =
  ## Would this ONE symbol kill the cog, by the resolver's own arithmetic?
  var scratch = st
  discard stepFrame(scratch, symbol, 0, fallLethal)
  not scratch.alive

proc safestSymbol*(st: LevelState, fallLethal: int): string =
  ## The sealed case: no plan, so take the single safest symbol. If none is
  ## safe the cog waits — never an unactuated seat.
  for symbol in ActionAlphabet:
    let plan = applyAction(st, symbol)
    if not plan.legal:
      continue
    if not fatalSymbol(st, symbol, fallLethal):
      return $symbol
  "."

proc hunterDistance(st: LevelState, c: Cell): int =
  result = 99
  for h in st.hunters:
    let d = max(abs(h.x - c.x), abs(h.y - c.y))
    if d < result:
      result = d

proc chooseTarget(st: LevelState, field: seq[int], tuning: Tunables): Cell =
  ## The nearest uncollected collectible by search distance, with a hazard
  ## detour budget added to anything a hunter is standing near; the exit once
  ## everything is taken. `exitFirst` is never true for either baseline.
  var
    best = st.cog
    bestCost = Unreachable
    found = false
  if st.collected >= st.collectTotal or tuning.exitFirst:
    return st.exitAt
  for index in 0 ..< BoardCells:
    if not st.grid.cells[index].collectible():
      continue
    let
      c = cellAt(index)
      d = field.distTo(c)
    if d >= Unreachable:
      continue
    var cost = d
    if st.kind == lkChaser and hunterDistance(st, c) <= 2:
      cost = cost + tuning.detourBudget
    if st.kind == lkMiner and st.boulderOverhead(c):
      cost = cost + tuning.detourBudget
    if not found or cost < bestCost:
      bestCost = cost
      best = c
      found = true
  if found: best else: st.exitAt

proc archetypeOpener(st: LevelState, syms: string, tuning: Tunables): string =
  ## The one archetype-specific proposal each baseline may make, ahead of the
  ## routed plan. Each is computed with the resolver's own procs.
  if syms.len == 0:
    return syms
  case st.kind
  of lkMaze:
    syms
  of lkChaser:
    ## `X` (dash) is proposed only when it strictly increases the distance to
    ## the nearest hunter and the cooldown is clear.
    if st.dashCooldown > 0 or st.hunters.len == 0:
      return syms
    let plan = applyAction(st, 'X')
    if not plan.legal or plan.effect != aeDash:
      return syms
    if hunterDistance(st, plan.target) > hunterDistance(st, st.cog):
      return "X" & syms
    syms
  of lkClimber:
    ## A step that needs a gap crossed emits `X` and then the horizontal
    ## symbol: jump first, carry the horizontal moves across.
    let first = syms[0]
    if first != 'L' and first != 'R':
      return syms
    let parsed = parseDir(first)
    if not parsed.ok:
      return syms
    let ahead = st.cog.step(parsed.dir)
    if st.grid.at(cell(ahead.x, ahead.y - 1)).solid():
      return syms                       ## no headroom: a jump does nothing
    var scratch = st
    scratch.cog = ahead
    if scratch.supported(ahead):
      return syms
    "X" & syms
  of lkMiner:
    ## Dig sideways out from under a boulder rather than standing there.
    if not st.boulderOverhead(st.cog):
      return syms
    for symbol in ['L', 'R']:
      let plan = applyAction(st, symbol)
      if plan.legal and (plan.effect == aeDig or plan.effect == aeMove or
          plan.effect == aeCollect):
        return $symbol & syms
    syms

proc scriptedPlanWith*(st: LevelState, tuning: Tunables, framesPerTurn,
                       fallLethal: int): PlanOrder =
  ## The scripted policy's whole reply. Neither baseline ever emits `say` or
  ## `notes` — which is why the viewer's text chrome needs the renderer
  ## fixture (`tools/ci/renderer_fixture.html`): a CI replay contains no LLM
  ## text at all (the cogchemists 2026-08-24 scar).
  result.source = dsScripted
  result.fromReply = true
  result.say = ""
  result.notes = ""
  let
    limit = max(1, min(framesPerTurn, tuning.commitFrames))
    cost = routeCost(st.kind, tuning.digCost)
    field = distField(st.grid, cost, st.cog, @[], ladderOnly(st.kind))
    target = chooseTarget(st, field, tuning)
    route = pathFrom(st.grid, cost, field, st.cog, target, @[],
      ladderOnly(st.kind))
  var syms = symbolsFor(st.cog, route, limit)
  syms = archetypeOpener(st, syms, tuning)
  if syms.len > limit:
    syms = syms[0 ..< limit]
  if syms.len == 0:
    result.moves = safestSymbol(st, fallLethal)
    return
  ## The veto, by simulation: run the plan over a scratch copy with the
  ## resolver's own `stepFrame` and drop it from the first symbol that kills
  ## the cog. `lookaheadFrames` is how far ahead a baseline bothers to look —
  ## `pathfinder` projects the whole plan, `scavenger` only the next frame.
  var
    scratch = st
    kept = ""
  for i in 0 ..< syms.len:
    if i < tuning.lookaheadFrames:
      var probe = scratch
      discard stepFrame(probe, syms[i], 0, fallLethal)
      if not probe.alive:
        break
    discard stepFrame(scratch, syms[i], 0, fallLethal)
    kept.add(syms[i])
    if not scratch.alive or scratch.finished:
      break
  if kept.len == 0:
    kept = safestSymbol(st, fallLethal)
  result.moves = kept

proc scriptedPlan*(st: LevelState, kind: Baseline, framesPerTurn,
                   fallLethal: int): PlanOrder =
  scriptedPlanWith(st, tunablesFor(kind), framesPerTurn, fallLethal)
