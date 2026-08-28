## The control layer: the single proc every unactuated seat resolves to.
##
## The per-turn FALLBACK path and the published `pathfinder` baseline resolve
## to the SAME proc, so they cannot drift; `tests/test_procgen_control.nim`
## asserts it. Forked from `coworld-ctf`'s `src/ctf/control.nim`, which held
## the same invariant for `holdline`.

import baselines, directives, levels

const FallbackBaseline* = blPathfinder
  ## `pathfinder` is the careful one: the certification player, the per-turn
  ## fallback, the default for an unregistered seat, and filler #1.

proc fallbackPlan*(st: LevelState, framesPerTurn, fallLethal: int): PlanOrder =
  ## The plan a seat plays when its LLM call could not be used this turn.
  result = scriptedPlan(st, FallbackBaseline, framesPerTurn, fallLethal)
  result.source = dsFallback
