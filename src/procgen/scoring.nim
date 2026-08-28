## The scoring formulas of the design note §Scoring formula and sign, and
## nothing else.
##
## Integer arithmetic throughout: `collectTotal` is 4 or 8 and never zero,
## `startDist >= 1` by generator validation, and every term uses non-negative
## integer `div`, so the arithmetic is exact and identical native and in wasm.
## The ONLY float in the game is `scores[0] = unseenMilli / 1000.0`, produced
## once, at the results document.

const
  CollectMilli* = 700
  ApproachMilli* = 200
  FinishMilli* = 100
  MaxReturnMilli* = CollectMilli + ApproachMilli + FinishMilli

proc returnMilli*(collected, collectTotal, startDist, bestDist: int,
                  finished: bool): int =
  ## One level's return, 0 .. 1000. A level where the cog collected
  ## everything and walked out scores exactly 1000; a level where it died on
  ## frame 1 scores 0. There is no death penalty.
  let
    total = max(1, collectTotal)
    start = max(1, startDist)
    taken = max(0, min(collected, total))
    closed = max(0, start - max(0, bestDist))
  result = (CollectMilli * taken) div total
  result = result + (ApproachMilli * min(closed, start)) div start
  if finished:
    result = result + FinishMilli

proc meanMilli*(values: seq[int], count: int): int =
  ## The arithmetic mean over ALL of `count` levels, including the ones the
  ## agent died on and the ones a deadline left unplayed. Never a best-of,
  ## never a drop-worst.
  if count <= 0:
    return 0
  var total = 0
  for v in values:
    total = total + v
  total div count

proc gapMilli*(seenMilli, unseenMilli: int): int =
  ## Reported, NEVER scored. May be negative.
  seenMilli - unseenMilli
