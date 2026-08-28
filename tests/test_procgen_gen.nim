## The generators: `generateLevel` is a PURE FUNCTION of
## `(kind, seed, difficulty)`, and every draw it returns passes the
## archetype's validator (design note §Tests, numbered blocks 14 and 15).
##
## SEED COUNTS. The note asks for 500 seeds on block 14 and 5000 per archetype
## per difficulty on block 15. `ci.yml` runs every test file TWICE — once in
## debug, where the bounds-checked build is an order of magnitude slower — so
## the sweeps here are 150 and 400 seeds respectively, which is 6600 whole
## level generations per run and still finds a generator that is wrong on one
## seed in a hundred. The full sweep is the same loop with a bigger bound:
##   nim r -d:release --path:src tests/test_procgen_gen.nim
## takes the wide numbers when SWEEP_WIDE is set.

import std/os
import procgen/[gen, levels, path, sim, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

let wide = getEnv("SWEEP_WIDE").len > 0
let pureSeeds = if wide: 500 else: 150
let validSeeds = if wide: 5000 else: 400

# 14. generateLevel is a pure function ---------------------------------------
block:
  for kind in LevelKind.low .. LevelKind.high:
    for difficulty in Difficulty.low .. Difficulty.high:
      for i in 1 .. pureSeeds:
        let seed = 100000 + i * 7919
        let a = generateLevel(kind, seed, difficulty)
        let b = generateLevel(kind, seed, difficulty)
        var identical = true
        for index in 0 ..< BoardCells:
          if a.grid.cells[index] != b.grid.cells[index]:
            identical = false
        check identical,
          "14: two calls with the same (kind, seed, difficulty) differ (" &
            $kind & " " & $difficulty & " " & $seed & ")"
        check a.start == b.start and a.exitAt == b.exitAt and
          a.hunters.len == b.hunters.len,
          "14: the start, the exit and the hunters are seed-derived too"
  ## A different seed is a different level (not a proof, a tripwire: two
  ## adjacent seeds producing the same grid would mean the seed is unused).
  for kind in LevelKind.low .. LevelKind.high:
    let
      a = generateLevel(kind, 424242, dfStandard)
      b = generateLevel(kind, 424243, dfStandard)
    var same = true
    for index in 0 ..< BoardCells:
      if a.grid.cells[index] != b.grid.cells[index]:
        same = false
    check not same, "14: adjacent seeds produce different levels in " & $kind

# 15. every draw validates, and the fallback is never reached ----------------
block:
  var fallbacks = 0
  for kind in LevelKind.low .. LevelKind.high:
    for difficulty in Difficulty.low .. Difficulty.high:
      for i in 1 .. validSeeds:
        let level = generateLevel(kind, 300000 + i * 104729, difficulty)
        if level.fallback:
          inc fallbacks
          continue
        check level.validate(kind),
          "15: a returned level failed its own validator (" & $kind & ")"
        ## Every collectible and the exit is reachable, and the start is never
        ## adjacent to a hunter spawn -- the validator's own conditions,
        ## re-checked here against the search the game plays with.
        let field = distField(level.grid, progressCost(kind), level.start,
          @[], ladderOnly(kind))
        check field.distTo(level.exitAt) >= 1 and
          field.distTo(level.exitAt) < Unreachable,
          "15: the exit is reachable and startDist >= 1 (" & $kind & ")"
        var collectibles = 0
        for index in 0 ..< BoardCells:
          if level.grid.cells[index].collectible():
            inc collectibles
            check field[index] < Unreachable,
              "15: every collectible is reachable (" & $kind & ")"
        check collectibles == collectTotalFor(kind),
          "15: the level carries exactly collectTotal collectibles (" &
            $kind & ")"
        for h in level.hunters:
          check abs(h.x - level.start.x) > 1 or abs(h.y - level.start.y) > 1,
            "15: the start is never adjacent to a hunter spawn"
  check fallbacks == 0,
    "15: the 41st-attempt FallbackLevel is never reached (" & $fallbacks &
      " times)"

# the committed fallback levels are themselves playable ----------------------
block:
  for kind in LevelKind.low .. LevelKind.high:
    let level = fallbackLevel(kind)
    check level.fallback, "15: fallbackLevel says it is the fallback"
    check level.validate(kind),
      "15: the committed FallbackLevel for " & $kind & " is playable"

if failures > 0:
  quit("test_procgen_gen: " & $failures & " failures", 1)
echo "test_procgen_gen: ok"
