## Scoring: the per-level return formula, the unseen mean, the gap and the
## sign (design note §Scoring formula and sign, numbered test 10).

import std/random
import procgen/[baselines, engine, scoring, seeds, sim]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

# 10. the per-level return ---------------------------------------------------
block:
  var rng = initRand(31337)
  for _ in 0 ..< 2000:
    let
      total = (if rng.rand(1) == 0: 4 else: 8)
      collected = rng.rand(total)
      startDist = 1 + rng.rand(30)
      bestDist = rng.rand(startDist)
      finished = rng.rand(1) == 0
      value = returnMilli(collected, total, startDist, bestDist, finished)
    check value >= 0 and value <= MaxReturnMilli,
      "10: returnMilli stays in [0, 1000]"
    check (value == MaxReturnMilli) ==
      (collected == total and finished and bestDist == 0),
      "10: 1000 iff everything collected, the exit reached and the approach full"
  check returnMilli(4, 4, 9, 0, true) == 1000,
    "10: a perfect level is exactly 1000"
  check returnMilli(0, 4, 9, 9, false) == 0,
    "10: a death on frame one is exactly 0"
  check returnMilli(3, 4, 8, 8, false) == 525,
    "10: three of four gems and no approach is 525"

# the mean, the gap and the sign ---------------------------------------------
block:
  check meanMilli(@[1000, 0, 500, 500], 4) == 500,
    "10: the mean includes the zeros"
  check meanMilli(@[1000, 0], 4) == 250,
    "10: an unplayed level divides by the FULL count, not the played one"
  check gapMilli(797, 570) == 227, "10: gapMilli is seen minus unseen"
  check gapMilli(300, 800) == -500, "10: gapMilli may be negative"

# scores[0] and win[0] over a real episode -----------------------------------
block:
  var config = defaultGameConfig()
  config.seed = 909
  config.turnSpacingMs = 0
  let played = runScriptedEpisode(config, blPathfinder)
  let episode = played.episode
  check episode.score() >= 0.0 and episode.score() <= 1.0,
    "10: scores[0] lies in [0.0, 1.0]"
  check episode.unseenMilli() >= 0 and episode.unseenMilli() <= 1000,
    "10: unseenMilli lies in [0, 1000]"
  var unseen: seq[int] = @[]
  var seen: seq[int] = @[]
  for i in 0 ..< episode.plan.len:
    if episode.plan[i].split == spUnseen: unseen.add(episode.returns[i])
    else: seen.add(episode.returns[i])
  check unseen.len == episode.plan.len div 2,
    "10: half the gauntlet is unseen"
  check episode.unseenMilli() == meanMilli(unseen, unseen.len),
    "10: unseenMilli is the arithmetic mean of ALL unseen levels"
  check episode.seenMilli() == meanMilli(seen, seen.len),
    "10: seenMilli is the arithmetic mean of ALL seen levels"
  check episode.gap() == episode.seenMilli() - episode.unseenMilli(),
    "10: gapMilli == seenMilli - unseenMilli exactly"
  var everyUnseenCleared = true
  for i in 0 ..< episode.plan.len:
    if episode.plan[i].split == spUnseen and
        episode.outcomes[i] != loCleared:
      everyUnseenCleared = false
  check episode.winFlag() == everyUnseenCleared,
    "10: win[0] is true iff every unseen level ended cleared"
  ## The seen half is measured and NEVER scored.
  check abs(episode.score() * 1000.0 - float(episode.unseenMilli())) < 0.001,
    "10: scores[0] is the unseen mean and nothing else"

if failures > 0:
  quit("test_procgen_scoring: " & $failures & " failures", 1)
echo "test_procgen_scoring: ok"
