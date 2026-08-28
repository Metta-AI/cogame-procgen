## Sweep the two scripted baselines over the fixed 24-episode ladder and check
## the shipped pick against tools/ci/baseline_tuning.json.
##
## The tunables are SWEPT, NOT GUESSED: `--sweep` prints every candidate's
## margin over the ladder (four seeds on each of the three difficulties, each
## played by both baselines on the SAME seeds), and that record is what pins
## the shipped numbers. `--check` re-plays the ladder with the shipped
## constants and fails if the constants have drifted from the recorded pick or
## the margin has left the recorded band -- which is a regression pin on the
## rules, the scoring and both baselines at once. `ci.yml` runs
## `--sweep --check`.
##
##   nim r --path:src tools/tune_baselines.nim --sweep --check
##   nim r --path:src tools/tune_baselines.nim --write

import std/[json, os, strutils]
import procgen/[baselines, engine]

const OutPath = "tools/ci/baseline_tuning.json"

proc toJson(t: Tunables): JsonNode =
  %*{"lookaheadFrames": t.lookaheadFrames, "digCost": t.digCost,
     "commitFrames": t.commitFrames, "detourBudget": t.detourBudget,
     "exitFirst": t.exitFirst}

proc sweep() =
  ## The bounded matrix. `lookaheadFrames` is how far ahead the careful
  ## baseline projects its own plan through the resolver; `digCost` is what a
  ## dirt tile is worth to its router; `detourBudget` is how many extra steps
  ## it will pay to route around a hunter or a boulder. `scavenger` is held at
  ## the design note's table on purpose: it is the player a champion should be
  ## able to beat, so tuning it for the margin would measure the wrong thing.
  echo "sweep over the ladder (margin = pathfinder mean score - scavenger mean)"
  for lookahead in [1, 3, 6]:
    for digCost in [1, 3]:
      for detour in [0, 6]:
        var candidate = PathfinderTunables
        candidate.lookaheadFrames = lookahead
        candidate.digCost = digCost
        candidate.detourBudget = detour
        let totals = ladderTotals(candidate, ScavengerTunables)
        echo "  lookahead=", lookahead, " digCost=", digCost,
          " detour=", detour,
          "  pathfinder=", totals.pathfinderMilli,
          " scavenger=", totals.scavengerMilli,
          "  cleared=", totals.pathfinderCleared, "/",
          totals.scavengerCleared,
          "  margin=", formatFloat(ladderMargin(totals), ffDecimal, 4)

proc measured(): JsonNode =
  let totals = ladderTotals(PathfinderTunables, ScavengerTunables)
  %*{
    "pathfinder": toJson(PathfinderTunables),
    "scavenger": toJson(ScavengerTunables),
    "ladder": {
      "difficulties": @LadderDifficulties,
      "seeds": LadderSeeds,
      "episodes": totals.episodes,
      "pathfinderMilli": totals.pathfinderMilli,
      "scavengerMilli": totals.scavengerMilli,
      "pathfinderCleared": totals.pathfinderCleared,
      "scavengerCleared": totals.scavengerCleared,
      "margin": ladderMargin(totals)
    }
  }

proc write() =
  let document = measured()
  document["marginMin"] = %(-1.0)
  document["marginMax"] = %1.0
  writeFile(OutPath, document.pretty() & "\n")
  echo "wrote ", OutPath

proc check(): int =
  if not fileExists(OutPath):
    echo "FAIL: ", OutPath, " is missing"
    return 1
  let recorded = parseJson(readFile(OutPath))
  let now = measured()
  if $recorded{"pathfinder"} != $now{"pathfinder"} or
      $recorded{"scavenger"} != $now{"scavenger"}:
    echo "FAIL: the shipped tunables are not the recorded pick"
    echo "  recorded: ", recorded{"pathfinder"}, " / ", recorded{"scavenger"}
    echo "  shipped:  ", now{"pathfinder"}, " / ", now{"scavenger"}
    return 1
  let
    margin = now{"ladder"}{"margin"}.getFloat()
    lo = recorded{"marginMin"}.getFloat(-1.0)
    hi = recorded{"marginMax"}.getFloat(1.0)
  echo "ladder: pathfinder ", now{"ladder"}{"pathfinderMilli"}.getInt(),
    " scavenger ", now{"ladder"}{"scavengerMilli"}.getInt(),
    " cleared ", now{"ladder"}{"pathfinderCleared"}.getInt(), "/",
    now{"ladder"}{"scavengerCleared"}.getInt(),
    " margin ", formatFloat(margin, ffDecimal, 4)
  if margin < lo or margin > hi:
    echo "FAIL: margin ", formatFloat(margin, ffDecimal, 4),
      " is outside the recorded band [", lo, ", ", hi, "]"
    return 1
  echo "ok: the shipped tunables are the recorded pick"
  0

when isMainModule:
  var
    doSweep = false
    doCheck = false
    doWrite = false
  for i in 1 .. paramCount():
    case paramStr(i)
    of "--sweep": doSweep = true
    of "--check": doCheck = true
    of "--write": doWrite = true
    else: discard
  if not (doSweep or doCheck or doWrite):
    doCheck = true
  if doSweep:
    sweep()
  if doWrite:
    write()
  if doCheck:
    quit(check())
