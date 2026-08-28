## The closed event vocabulary, the beat kinds, and the tier-2 JSON-lines
## analysis stream.
##
## Two vocabularies, deliberately:
##
## * `EventKind` (levels.nim) is the BROADCAST set — a closed enum of sixteen
##   derived kinds plus `end`, which `stepEvents` derives from state deltas at
##   playback, so the feed and the scrubber cost no replay bytes.
##   `tests/test_procgen_events.nim` asserts the emitted set is exactly those
##   seventeen.
## * `SimEventKind` here is the TIER-2 ANALYSIS set the design note's §Record
##   and event vocabulary C specifies for `COGAME_EVENTS_URI`: sixteen kinds
##   with a wire key each, following the starter's `key()` shape. It is the
##   broadcast set minus `gamestart` and `end` — which say nothing the replay
##   config and the results document do not already say — plus `directive`,
##   which the sim cannot derive because it is a fact about the DECISION.

import std/[json, strutils]
import levels

const
  AllEventKinds*: array[17, EventKind] = [
    ekGameStart, ekLevelStart, ekPlan, ekStep, ekCollect, ekDig, ekPush,
    ekFall, ekHunter, ekInterrupt, ekDeath, ekExitOpen, ekLevelEnd, ekSay,
    ekFallback, ekGauntletEnd, ekEnd]

  BeatKinds*: array[7, EventKind] = [
    ekLevelStart, ekCollect, ekExitOpen, ekDeath, ekLevelEnd, ekFallback,
    ekGauntletEnd]
    ## The scrubber markers — the only kinds the appended game block turns
    ## into buttons. `gamestart`, `plan`, `step`, `dig`, `push`, `fall`,
    ## `hunter`, `interrupt`, `say` and `end` never make beats.

type
  SimEventKind* = enum
    ## Design note §Record and event vocabulary C, in its order.
    seLevelStart, sePlan, seStep, seCollect, seDig, sePush, seFall, seHunter,
    seInterrupt, seDeath, seExitOpen, seLevelEnd, seSay, seDirective,
    seFallback, seGauntletEnd

  DirectiveEvent* = object
    ## One turn's installed plan. Not a level fact, so no `FrameEvent` carries
    ## it; the decision layer hands these to the stream.
    turn*, level*: int
    alias*, source*, moves*: string
    executed*, latencyMs*: int
    repaired*: bool

proc key*(kind: SimEventKind): string =
  case kind
  of seLevelStart: "levelstart"
  of sePlan: "plan"
  of seStep: "step"
  of seCollect: "collect"
  of seDig: "dig"
  of sePush: "push"
  of seFall: "fall"
  of seHunter: "hunter"
  of seInterrupt: "interrupt"
  of seDeath: "death"
  of seExitOpen: "exitopen"
  of seLevelEnd: "levelend"
  of seSay: "say"
  of seDirective: "directive"
  of seFallback: "fallback"
  of seGauntletEnd: "gauntletend"

proc simKindOf*(kind: EventKind): tuple[carried: bool, sim: SimEventKind] =
  case kind
  of ekLevelStart: (true, seLevelStart)
  of ekPlan: (true, sePlan)
  of ekStep: (true, seStep)
  of ekCollect: (true, seCollect)
  of ekDig: (true, seDig)
  of ekPush: (true, sePush)
  of ekFall: (true, seFall)
  of ekHunter: (true, seHunter)
  of ekInterrupt: (true, seInterrupt)
  of ekDeath: (true, seDeath)
  of ekExitOpen: (true, seExitOpen)
  of ekLevelEnd: (true, seLevelEnd)
  of ekSay: (true, seSay)
  of ekFallback: (true, seFallback)
  of ekGauntletEnd: (true, seGauntletEnd)
  of ekGameStart, ekEnd: (false, seLevelStart)

proc isBeatKind*(kind: EventKind): bool =
  for k in BeatKinds:
    if k == kind:
      return true
  false

proc eventJson*(e: FrameEvent): JsonNode =
  result = %*{"k": $e.kind, "t": e.frame, "level": e.level}
  if e.turn > 0: result["turn"] = %e.turn
  if e.value != 0: result["v"] = %e.value
  if e.extra != 0: result["x"] = %e.extra
  if e.text.len > 0: result["text"] = %e.text
  result["at"] = %[e.at.x, e.at.y]
  result["to"] = %[e.to.x, e.to.y]

proc directiveJson*(d: DirectiveEvent): JsonNode =
  %*{"k": key(seDirective), "t": d.turn, "level": d.level, "alias": d.alias,
     "source": d.source, "moves": d.moves, "executed": d.executed,
     "latency_ms": d.latencyMs, "repaired": d.repaired}

proc eventsJsonl*(events: seq[FrameEvent], frames: int, gameVersion: string,
                  directives: seq[DirectiveEvent] = @[]): string =
  ## `COGAME_EVENTS_URI` gets one JSON object per line, with the mandatory
  ## trailing summary row.
  var lines: seq[string]
  var carried = 0
  for d in directives:
    lines.add($directiveJson(d))
  for e in events:
    let mapped = simKindOf(e.kind)
    if not mapped.carried:
      continue
    inc carried
    var row = eventJson(e)
    row["k"] = %key(mapped.sim)
    lines.add($row)
  lines.add($(%*{
    "type": "summary", "frames": frames,
    "events": carried + directives.len,
    "gameVersion": gameVersion}))
  lines.join("\n") & "\n"
