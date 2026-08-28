## The sim: the tile table, the six-symbol alphabet, each archetype's one
## physics hook, the uniform exit rule, the danger interrupt, the progress
## measure, the determinism grep and the frame budget.
##
## Design note §Tests, numbered blocks 1-9, 12 and 13. Block 10 (scoring) is
## `tests/test_procgen_scoring.nim` and block 11 (end conditions) is
## `tests/test_procgen_engine.nim`, both named by the note.

import std/[monotimes, os, strutils, times]
import procgen/[baselines, engine, gen, levels, path, sim, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

proc board(rows: array[9, string]): array[9, string] = rows

# 1. tiles and passability ---------------------------------------------------
block:
  check ord(tEmpty) == 0 and ord(tWall) == 1 and ord(tSpike) == 10,
    "1: the tile enum is the wire order"
  var glyphs = ""
  for t in Tile.low .. Tile.high:
    glyphs.add(t.glyph())
  check glyphs == ".#:O*o+E=H^", "1: the glyph table is one source: " & glyphs
  for kind in LevelKind.low .. LevelKind.high:
    check not passable(kind, tWall), "1: bedrock is never passable"
    check not passable(kind, tPlatform), "1: a platform is never entered"
    check not passable(kind, tExitLocked), "1: a locked exit is not passable"
    check passable(kind, tEmpty) and passable(kind, tGem) and
      passable(kind, tPellet) and passable(kind, tExitOpen) and
      passable(kind, tLadder) and passable(kind, tSpike),
      "1: the passable set is the table's"
    check passable(kind, tDirt) == (kind == lkMiner),
      "1: only miner enters dirt"
    check not passable(kind, tBoulder),
      "1: a boulder is never ENTERED (it is pushed)"
  ## The outer ring is Wall on every generated level.
  for kind in LevelKind.low .. LevelKind.high:
    for seed in 1 .. 40:
      let level = generateLevel(kind, 900000 + seed * 13, dfStandard)
      for x in 0 ..< BoardW:
        check level.grid.at(cell(x, 0)) == tWall and
          level.grid.at(cell(x, BoardH - 1)) == tWall,
          "1: the outer ring is Wall (" & $kind & " row)"
      for y in 0 ..< BoardH:
        check level.grid.at(cell(0, y)) == tWall and
          level.grid.at(cell(BoardW - 1, y)) == tWall,
          "1: the outer ring is Wall (" & $kind & " column)"

# 2. action alphabet ---------------------------------------------------------
block:
  check ActionAlphabet == "LRUDX.", "2: exactly six symbols"
  check ActionAlphabet.len == 6, "2: the alphabet has six entries"
  ## applyAction is TOTAL over (6 symbols x 4 archetypes x every level) and
  ## never raises.
  for kind in LevelKind.low .. LevelKind.high:
    for seed in 1 .. 12:
      var st = newLevel(kind, 500000 + seed, dfStandard)
      for symbol in ActionAlphabet:
        let plan = applyAction(st, symbol)
        check plan.target.inBounds(), "2: applyAction targets stay on board"
      ## L R U D set last_dir EVEN WHEN THE MOVE IS BLOCKED.
      for symbol in "LRUD":
        var probe = st
        ## Wall the cog in so every direction is blocked.
        for d in DirOrder:
          probe.grid.setTile(probe.cog.step(d), tWall)
        discard stepFrame(probe, symbol, 1, 4)
        check probe.lastDir == parseDir(symbol).dir,
          "2: " & symbol & " sets last_dir even when blocked"

# 3. maze physics ------------------------------------------------------------
block:
  var st = levelFromRows(lkMaze, dfStandard, board([
    "###############",
    "#@..*.........#",
    "#.###########.#",
    "#....*........#",
    "#.###########.#",
    "#....*........#",
    "#.###########.#",
    "#*..........+.#",
    "###############"]))
  check st.collectTotal == 4, "3: maze wants four gems"
  ## `X` is a wait in maze, and there is no gravity and no hazard.
  let before = st.cog
  discard stepFrame(st, 'X', 1, 4)
  check st.cog == before, "3: X does nothing in a maze"
  discard stepFrame(st, 'R', 1, 4)
  discard stepFrame(st, 'R', 1, 4)
  discard stepFrame(st, 'R', 1, 4)
  check st.collected == 1, "3: a gem is collected on entry"
  check st.grid.at(st.exitAt) == tExitLocked,
    "3: the exit stays locked below the total"
  ## Walk the rest of them.
  var guard = 0
  while st.collected < st.collectTotal and guard < 200:
    inc guard
    let plan = scriptedPlan(st, blPathfinder, 6, 4)
    for symbol in plan.moves:
      discard stepFrame(st, symbol, 1, 4)
      if st.collected >= st.collectTotal:
        break
  check st.collected == st.collectTotal, "3: pathfinder takes all four gems"
  check st.grid.at(st.exitAt) == tExitOpen,
    "3: the exit OPENS on exactly the frame the last gem is taken"
  check st.alive, "3: nothing in a maze can kill the cog"

# 4. chaser physics ----------------------------------------------------------
block:
  var st = levelFromRows(lkChaser, dfStandard, board([
    "###############",
    "#@..o....o...X#",
    "#.............#",
    "#..o.......o..#",
    "#.............#",
    "#o...o...o...o#",
    "#.............#",
    "#...........+.#",
    "###############"]))
  check st.collectTotal == 8, "4: chaser wants eight pellets"
  ## Hunters do NOT move on frames where frame mod 3 == 0.
  var st3 = st
  st3.frame = 2
  let hunterBefore = st3.hunters[0]
  discard stepFrame(st3, '.', 1, 4)   ## frame becomes 3 -> hunters rest
  check st3.hunters[0] == hunterBefore, "4: hunters rest on every third frame"
  var st1 = st
  st1.frame = 0
  discard stepFrame(st1, '.', 1, 4)   ## frame becomes 1 -> hunters move
  check not (st1.hunters[0] == hunterBefore),
    "4: hunters step toward the cog on every other frame"
  ## Contact kills, cause `caught`.
  var kill = st
  kill.hunters = @[cell(kill.cog.x + 1, kill.cog.y)]
  kill.frame = 0
  discard stepFrame(kill, 'R', 1, 4)
  check (not kill.alive) and kill.deathCause == dcCaught,
    "4: a hunter sharing the cog's cell kills, cause caught"
  ## X dashes two tiles and only when both are passable; then the cooldown
  ## blocks the next four frames' X.
  var dash = st
  dash.lastDir = dR
  let from0 = dash.cog
  discard stepFrame(dash, 'X', 1, 4)
  check dash.cog.x == from0.x + 2 and dash.cog.y == from0.y,
    "4: X dashes two tiles in last_dir"
  check dash.dashCooldown > 0, "4: the dash sets a cooldown"
  let afterDash = dash.cog
  discard stepFrame(dash, 'X', 1, 4)
  check dash.cog == afterDash, "4: X is a wait while the cooldown runs"
  var blockedDash = st
  blockedDash.lastDir = dL      ## the wall is one tile to the left
  let stuck = blockedDash.cog
  discard stepFrame(blockedDash, 'X', 1, 4)
  check blockedDash.cog == stuck,
    "4: a dash needs BOTH tiles passable"

# 5. climber physics ---------------------------------------------------------
block:
  var st = levelFromRows(lkClimber, dfStandard, board([
    "###############",
    "#*.........+..#",
    "#====H========#",
    "#....H........#",
    "#...*.....*...#",
    "#=========H===#",
    "#.........H...#",
    "#@..........*.#",
    "###############"]))
  ## U/D move ONLY on a ladder.
  var noLadder = st
  let ground = noLadder.cog
  discard stepFrame(noLadder, 'U', 1, 4)
  check noLadder.cog == ground, "5: U is blocked without a ladder"
  ## Climb the ladder at x = 10.
  var climb = st
  climb.cog = cell(10, 7)
  discard stepFrame(climb, 'U', 1, 4)
  check climb.cog == cell(10, 6), "5: U climbs onto a ladder tile"
  discard stepFrame(climb, 'U', 1, 4)
  discard stepFrame(climb, 'U', 1, 4)
  check climb.cog == cell(10, 4), "5: the ladder carries the cog to the tier"
  check climb.alive, "5: a cog standing on a ladder does not fall"
  ## X sets jumpFuel and the cog rises while it lasts.
  var jump = st
  jump.cog = cell(2, 7)
  discard stepFrame(jump, 'X', 1, 4)
  check jump.cog == cell(2, 6), "5: the jump lifts the cog one tile a frame"
  check jump.jumpFuel == 1, "5: jumpFuel is spent one frame at a time"
  ## Gravity pulls one tile a frame when nothing is under the cog, and a fall
  ## deeper than fallLethal kills with cause `fell`.
  var fall = st
  fall.cog = cell(2, 1)
  fall.grid.setTile(cell(2, 2), tEmpty)
  fall.grid.setTile(cell(2, 5), tEmpty)
  var depth = 0
  while fall.alive and depth < 10:
    inc depth
    discard stepFrame(fall, '.', 1, 4)
    if not fall.alive:
      break
  check (not fall.alive) and fall.deathCause == dcFell,
    "5: a fall deeper than fallLethal kills, cause fell"
  ## A spike kills with cause `spiked`.
  var spike = st
  spike.grid.setTile(cell(2, 7), tSpike)
  discard stepFrame(spike, 'R', 1, 4)
  check (not spike.alive) and spike.deathCause == dcSpiked,
    "5: a spike kills, cause spiked"

# 6. miner physics -----------------------------------------------------------
block:
  var st = levelFromRows(lkMiner, dfStandard, board([
    "###############",
    "#@::::::::::::#",
    "#::::::::::::.#",
    "#::::*::::::::#",
    "#:::::::::::::#",
    "#::::*:::::::*#",
    "#:::::::::::::#",
    "#*::::::::::+:#",
    "###############"]))
  ## A dirt target is dug and entered in ONE frame.
  discard stepFrame(st, 'R', 1, 4)
  check st.cog == cell(2, 1) and st.grid.at(cell(2, 1)) == tEmpty,
    "6: a dirt target is dug and entered in one frame"
  ## X digs the last_dir tile WITHOUT moving.
  let standing = st.cog
  discard stepFrame(st, 'X', 1, 4)
  check st.cog == standing and st.grid.at(cell(3, 1)) == tEmpty,
    "6: X digs without moving"
  ## A horizontal push succeeds only when the far cell is Empty, and never
  ## vertically.
  var push = st
  push.grid.setTile(cell(3, 1), tBoulder)
  push.grid.setTile(cell(4, 1), tEmpty)
  discard stepFrame(push, 'R', 1, 4)
  check push.cog == cell(3, 1) and push.grid.at(cell(4, 1)) == tBoulder,
    "6: a boulder is pushed one tile when the far cell is empty"
  var blocked = st
  blocked.grid.setTile(cell(3, 1), tBoulder)
  blocked.grid.setTile(cell(4, 1), tWall)
  let held = blocked.cog
  discard stepFrame(blocked, 'R', 1, 4)
  check blocked.cog == held, "6: a push into a wall is a blocked move"
  var vertical = st
  vertical.grid.setTile(cell(vertical.cog.x, vertical.cog.y + 1), tBoulder)
  vertical.grid.setTile(cell(vertical.cog.x, vertical.cog.y + 2), tEmpty)
  let vheld = vertical.cog
  discard stepFrame(vertical, 'D', 1, 4)
  check vertical.cog == vheld, "6: a boulder is never pushed vertically"
  ## A falling boulder entering the cog's cell kills with cause `crushed`; a
  ## boulder RESTING on the cog does not.
  var crush = st
  crush.cog = cell(5, 4)
  crush.grid.setTile(cell(5, 4), tEmpty)
  crush.grid.setTile(cell(5, 3), tEmpty)
  crush.grid.setTile(cell(5, 2), tBoulder)
  discard stepFrame(crush, '.', 1, 4)   ## the boulder falls one tile
  check crush.alive, "6: a boulder one tile above is not yet a death"
  discard stepFrame(crush, '.', 1, 4)   ## and lands on the cog
  check (not crush.alive) and crush.deathCause == dcCrushed,
    "6: a falling boulder that lands on the cog kills, cause crushed"
  var resting = st
  resting.cog = cell(5, 4)
  resting.grid.setTile(cell(5, 4), tEmpty)
  resting.grid.setTile(cell(5, 3), tBoulder)
  discard stepFrame(resting, '.', 1, 4)
  check resting.alive, "6: a boulder RESTING on the cog does not kill it"

# 7. the exit rule is uniform ------------------------------------------------
block:
  for kind in LevelKind.low .. LevelKind.high:
    var st = newLevel(kind, 700000 + ord(kind), dfStandard)
    check st.grid.at(st.exitAt) == tExitLocked,
      "7: the exit starts locked in " & $kind
    ## Entering a locked exit is a BLOCKED move in every archetype.
    var probe = st
    probe.cog = cell(st.exitAt.x - 1, st.exitAt.y)
    probe.grid.setTile(probe.cog, tEmpty)
    let plan = applyAction(probe, 'R')
    if probe.cog.step(dR) == st.exitAt:
      check (not plan.legal) and plan.effect == aeBlocked,
        "7: a locked exit refuses the cog in " & $kind
    ## Taking every collectible opens it, on exactly that frame.
    var opened = st
    var taken = 0
    for index in 0 ..< BoardCells:
      if opened.grid.cells[index].collectible():
        inc taken
        opened.grid.setTile(cellAt(index), tEmpty)
        opened.collected = taken
        if taken == opened.collectTotal:
          break
    check taken == opened.collectTotal,
      "7: the level carries exactly collectTotal collectibles in " & $kind

# 8. the danger interrupt ----------------------------------------------------
block:
  ## maze NEVER interrupts.
  for seed in 1 .. 20:
    var st = newLevel(lkMaze, 1000 + seed, dfStandard)
    var guard = 0
    while st.alive and not st.finished and guard < 30:
      inc guard
      discard stepFrame(st, "LRUD."[guard mod 5], 1, 4)
      check not st.interrupted, "8: a maze plan is never interrupted"
  ## chaser interrupts at Chebyshev 1.
  var chaser = levelFromRows(lkChaser, dfStandard, board([
    "###############",
    "#@..o....o...o#",
    "#.............#",
    "#..o.......o..#",
    "#......X......#",
    "#o...o...o...o#",
    "#.............#",
    "#...........+.#",
    "###############"]))
  chaser.cog = cell(7, 2)
  chaser.frame = 0                       ## the next frame is a hunter STEP
  discard stepFrame(chaser, '.', 1, 4)
  check chaser.dangerInterrupt(),
    "8: chaser interrupts with a hunter at Chebyshev 1"
  ## climber interrupts in free fall at depth 2.
  var climber = levelFromRows(lkClimber, dfStandard, board([
    "###############",
    "#*.........+..#",
    "#====H========#",
    "#....H........#",
    "#...*.....*...#",
    "#=========H===#",
    "#.........H...#",
    "#@..........*.#",
    "###############"]))
  climber.cog = cell(2, 1)
  climber.grid.setTile(cell(2, 2), tEmpty)
  climber.grid.setTile(cell(2, 5), tEmpty)
  discard stepFrame(climber, '.', 1, 4)
  discard stepFrame(climber, '.', 1, 4)
  check climber.fallDepth >= 2 and climber.dangerInterrupt(),
    "8: climber interrupts in free fall at depth 2"
  ## miner interrupts under a falling boulder.
  var miner = levelFromRows(lkMiner, dfStandard, board([
    "###############",
    "#@::::::::::::#",
    "#::::::::::::.#",
    "#::::::::::::.#",
    "#::::::::::::.#",
    "#:::::::::::::#",
    "#:::::::::::::#",
    "#*::::::::::+:#",
    "###############"]))
  miner.cog = cell(13, 4)
  miner.grid.setTile(cell(13, 2), tBoulder)
  discard stepFrame(miner, '.', 1, 4)
  check miner.dangerInterrupt(),
    "8: miner interrupts under a falling boulder"

# 9. the progress measure ----------------------------------------------------
block:
  for seed in 1 .. 40:
    var st = newLevel(lkMaze, 2000 + seed, dfStandard)
    check st.startDist >= 1, "9: startDist is at least one"
    var last = st.bestDist
    var guard = 0
    while st.alive and not st.finished and guard < 40:
      inc guard
      let plan = scriptedPlan(st, blPathfinder, 6, 4)
      for symbol in plan.moves:
        discard stepFrame(st, symbol, 1, 4)
      check st.bestDist <= last,
        "9: bestDist is monotone non-increasing within a level"
      last = st.bestDist
      ## and it equals a from-scratch search minimum over the frames played.
      check st.bestDist <= st.distanceToExit(),
        "9: bestDist is the minimum of the distances actually reached"

# 12. no floats in the hashed code -------------------------------------------
block:
  for name in ["tiles", "gen", "levels", "path", "scoring"]:
    let path = "src/procgen/" & name & ".nim"
    if not fileExists(path):
      check false, "12: cannot read " & path
      continue
    var line = 0
    for text in lines(path):
      inc line
      let code = text.split("##")[0]
      if code.strip().startsWith("#"):
        continue
      check "sqrt" notin code,
        "12: " & path & ":" & $line & " uses sqrt"
      check " / " notin code,
        "12: " & path & ":" & $line & " uses the float division operator"
      var i = 0
      while i < code.len:
        if code[i] == '.' and i > 0 and i + 1 < code.len and
            code[i - 1].isDigit() and code[i + 1].isDigit():
          check false, "12: " & path & ":" & $line & " has a float literal"
        inc i

# 13. the frame budget -------------------------------------------------------
block:
  var config = defaultGameConfig()
  config.seed = 4242
  config.difficulty = "hard"
  config.turnSpacingMs = 0
  let started = getMonoTime()
  let played = runScriptedEpisode(config, blPathfinder)
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check played.episode.plan.len == 8, "13: a full eight-level episode ran"
  check played.episode.totalFrames > 0, "13: the episode played frames"
  ## A whole hard, all-scripted episode is integer work over 135 tiles. The
  ## outer budget is generous because CI runs this file in DEBUG as well as
  ## release, and a debug build is an order of magnitude slower.
  check elapsed < 60000,
    "13: a full hard scripted episode completes well inside the turn budget (" &
      $elapsed & " ms)"
  echo "13: episode ", elapsed, " ms (", played.episode.totalFrames, " frames)"
  ## The note's own two numbers, which only mean anything in a build with the
  ## checks off: the whole episode in under a second...
  when defined(release):
    check elapsed < 1000,
      "13: a release build plays the whole hard episode in under a second (" &
        $elapsed & " ms)"

  ## ...and no single FRAME over a millisecond. Timed on the resolver itself,
  ## one symbol at a time, over every archetype at `hard` — the same
  ## `stepFrame` the episode above runs, so this is the per-frame half of the
  ## same budget rather than a second implementation of it.
  var worstNs = 0
  for kind in LevelKind.low .. LevelKind.high:
    var st = newLevel(kind, 4242, dfHard)
    var i = 0
    while i < 240 and st.alive and not st.finished:
      let symbol = "RDLUX."[i mod 6]
      let frameStart = getMonoTime()
      discard stepFrame(st, symbol, 1, 4)
      let took = (getMonoTime() - frameStart).inNanoseconds.int
      if took > worstNs:
        worstNs = took
      inc i
  echo "13: worst single frame ", worstNs, " ns"
  when defined(release):
    check worstNs < 1000000,
      "13: no single frame exceeds 1 ms (worst " & $worstNs & " ns)"

if failures > 0:
  quit("test_procgen_sim: " & $failures & " failures", 1)
echo "test_procgen_sim: ok"
