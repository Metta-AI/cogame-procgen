## The four generators, the validator, the bounded redraw and the four
## committed fallback levels.
##
## `generateLevel(kind, seed, difficulty)` is a PURE FUNCTION of its three
## arguments: it uses one `levelRng` seeded from `seed` alone, and it ends
## with the archetype's validator. A draw that fails the validator is redrawn
## with `levelRng` advanced, up to `MaxRedrawAttempts` (40) times; attempt 41
## falls back to the archetype's hand-authored `FallbackLevel` const and the
## caller emits a `gen_fallback` record. Bounded, never a loop, never an
## unplayable level.
##
## Geometry note, `climber`. The design note describes "four platform rows
## (y in {7,5,3,1}) over a pit". Four tiers in nine rows leaves no HEADROOM,
## and without a tile of headroom the two-tile jump can never lift the cog
## off its own floor — the archetype's whole special would be a no-op. The
## shipped geometry is therefore THREE walkable tiers at y in {7, 4, 1}, each
## carried by a band beneath it (the bottom wall row, y=5 and y=2) and each
## with a tile of empty headroom above it, so `X` is a real move: jump, then
## carry the horizontal moves across the gap. `docs/RULES.md` §Divergences
## records it.

import levels, path, sim_state, tiles

type
  GeneratedLevel* = object
    grid*: Grid
    start*, exitAt*: Cell
    hunters*: seq[Cell]
    fallback*: bool

const
  MazeLatticeW* = 7
  MazeLatticeH* = 4
  ClimberWalkRows* = [7, 4, 1]
  ClimberBandRows* = [5, 2]
  ClimberMaxGap* = 2

# ---------------------------------------------------------------------------
#  The committed fallback levels: one per archetype, hand-authored, used only
#  when 40 draws in a row failed the validator. `tests/test_procgen_gen.nim`
#  asserts that never happens across 5000 seeds per archetype per difficulty;
#  these exist so the episode cannot loop even if it ever did.
# ---------------------------------------------------------------------------

const
  FallbackMaze* = [
    "###############",
    "#@..#....*....#",
    "#.#.#.#####.#.#",
    "#.#...#...#.#.#",
    "#.#####.#.#.#.#",
    "#*....#.#.#..*#",
    "#.###.#.#.#####",
    "#...#...#...*+#",
    "###############"]
  FallbackChaser* = [
    "###############",
    "#@..o.....o..X#",
    "#.#...#...#...#",
    "#..o....o....o#",
    "#...#..#..#...#",
    "#o....o.....o.#",
    "#..#.....#....#",
    "#X..........+.#",
    "###############"]
  FallbackClimber* = [
    "###############",
    "#*.........+..#",
    "#====H========#",
    "#....H........#",
    "#...*.....*...#",
    "#=========H===#",
    "#.........H...#",
    "#@..........*.#",
    "###############"]
  FallbackMiner* = [
    "###############",
    "#@::::::::::::#",
    "#:::##:::O::::#",
    "#::::::*::::::#",
    "#:O::::###::::#",
    "#:::*::::::::*#",
    "#::::::::O::::#",
    "#*::::::::::+:#",
    "###############"]

proc parseLevelRows*(rows: array[9, string]): GeneratedLevel =
  ## Reads a hand-authored level. `@` is the start and `X` a hunter spawn;
  ## both leave `Empty` behind.
  result.grid = emptyGrid()
  result.start = cell(1, 1)
  result.exitAt = cell(BoardW - 2, BoardH - 2)
  for y in 0 ..< BoardH:
    for x in 0 ..< BoardW:
      let
        c = cell(x, y)
        ch = if x < rows[y].len: rows[y][x] else: '#'
      var t = tEmpty
      case ch
      of '#': t = tWall
      of ':': t = tDirt
      of 'O': t = tBoulder
      of '*': t = tGem
      of 'o': t = tPellet
      of '+': t = tExitLocked
      of 'E': t = tExitOpen
      of '=': t = tPlatform
      of 'H': t = tLadder
      of '^': t = tSpike
      of '@':
        t = tEmpty
        result.start = c
      of 'X':
        t = tEmpty
        result.hunters.add(c)
      else: t = tEmpty
      result.grid.setTile(c, t)
      if t == tExitLocked:
        result.exitAt = c

proc levelFromRows*(kind: LevelKind, difficulty: Difficulty,
                    rows: array[9, string]): LevelState =
  ## A hand-authored level, as a playable `LevelState`. The unit tests build
  ## their boards this way so a physics assertion reads as the board it is
  ## about.
  let drawn = parseLevelRows(rows)
  newLevelState(kind, difficulty, 0, drawn.grid, drawn.start, drawn.exitAt,
    drawn.hunters)

proc fallbackLevel*(kind: LevelKind): GeneratedLevel =
  result =
    case kind
    of lkMaze: parseLevelRows(FallbackMaze)
    of lkChaser: parseLevelRows(FallbackChaser)
    of lkClimber: parseLevelRows(FallbackClimber)
    of lkMiner: parseLevelRows(FallbackMiner)
  result.fallback = true

# ---------------------------------------------------------------------------
#  Shared helpers
# ---------------------------------------------------------------------------

proc countTiles*(g: Grid, t: Tile): int =
  for index in 0 ..< BoardCells:
    if g.cells[index] == t:
      inc result

proc collectibleCount*(g: Grid): int =
  countTiles(g, tGem) + countTiles(g, tPellet)

proc reachableField(level: GeneratedLevel, kind: LevelKind): seq[int] =
  distField(level.grid, progressCost(kind), level.start, @[], ladderOnly(kind))

proc validate*(level: GeneratedLevel, kind: LevelKind): bool =
  ## The archetype validator, run on every draw. Every collectible and the
  ## exit reachable; the start not adjacent to a hunter spawn; `climber`'s
  ## every tier reachable from the tier below within jump range;
  ## `startDist >= 1`.
  if not level.start.inBounds() or not level.exitAt.inBounds():
    return false
  if level.grid.at(level.start).solid():
    return false
  if collectibleCount(level.grid) != collectTotalFor(kind):
    return false
  if level.grid.at(level.exitAt) != tExitLocked:
    return false
  let field = reachableField(level, kind)
  if field.distTo(level.exitAt) < 1 or field.distTo(level.exitAt) >= Unreachable:
    return false
  for index in 0 ..< BoardCells:
    if level.grid.cells[index].collectible() and field[index] >= Unreachable:
      return false
  for h in level.hunters:
    if abs(h.x - level.start.x) <= 1 and abs(h.y - level.start.y) <= 1:
      return false
    if field.distTo(h) >= Unreachable:
      return false
  if kind == lkClimber:
    ## Every tier reachable from the tier below: each band carries at least
    ## one ladder column, and no gap in a band is wider than a jump.
    for band in ClimberBandRows:
      var ladders = 0
      var run = 0
      for x in 1 .. BoardW - 2:
        let t = level.grid.at(cell(x, band))
        if t == tLadder:
          inc ladders
        if t == tEmpty:
          inc run
          if run > ClimberMaxGap:
            return false
        else:
          run = 0
      if ladders == 0:
        return false
  true

# ---------------------------------------------------------------------------
#  maze — a perfect backtracker maze on the 7 x 4 odd lattice
# ---------------------------------------------------------------------------

proc latticeCell(i, j: int): Cell = cell(1 + 2 * i, 1 + 2 * j)

proc drawMaze(rng: var Rng, table: DiffTable): GeneratedLevel =
  var g = emptyGrid()
  for y in 1 .. BoardH - 2:
    for x in 1 .. BoardW - 2:
      g.setTile(cell(x, y), tWall)
  let cells = MazeLatticeW * MazeLatticeH
  var
    visited = newSeq[bool](cells)
    stack: seq[int] = @[]
  let first = rng.rand(cells)
  visited[first] = true
  g.setTile(latticeCell(first mod MazeLatticeW, first div MazeLatticeW), tEmpty)
  stack.add(first)
  while stack.len > 0:
    let
      current = stack[^1]
      ci = current mod MazeLatticeW
      cj = current div MazeLatticeW
    var options: seq[int] = @[]
    for d in DirOrder:
      let
        s = d.delta()
        ni = ci + s.x
        nj = cj + s.y
      if ni < 0 or nj < 0 or ni >= MazeLatticeW or nj >= MazeLatticeH:
        continue
      let index = nj * MazeLatticeW + ni
      if not visited[index]:
        options.add(index)
    if options.len == 0:
      discard stack.pop()
      continue
    let
      pick = options[rng.rand(options.len)]
      ni = pick mod MazeLatticeW
      nj = pick div MazeLatticeW
      here = latticeCell(ci, cj)
      there = latticeCell(ni, nj)
    g.setTile(cell((here.x + there.x) div 2, (here.y + there.y) div 2), tEmpty)
    g.setTile(there, tEmpty)
    visited[pick] = true
    stack.add(pick)
  ## Braid: knock `braidCount` dead ends out, which is what turns a perfect
  ## maze into one with loops. Easy has the most, hard the fewest.
  var braided = 0
  var guard = 0
  while braided < table.braidCount and guard < 200:
    inc guard
    let
      index = rng.rand(cells)
      i = index mod MazeLatticeW
      j = index div MazeLatticeW
      here = latticeCell(i, j)
    var open = 0
    for d in DirOrder:
      let s = d.delta()
      if g.at(cell(here.x + s.x, here.y + s.y)) == tEmpty:
        inc open
    if open > 1:
      continue
    var walls: seq[Cell] = @[]
    for d in DirOrder:
      let
        s = d.delta()
        wall = cell(here.x + s.x, here.y + s.y)
        beyond = cell(here.x + 2 * s.x, here.y + 2 * s.y)
      if beyond.inBounds() and g.at(wall) == tWall and g.at(beyond) == tEmpty:
        walls.add(wall)
    if walls.len == 0:
      continue
    g.setTile(walls[rng.rand(walls.len)], tEmpty)
    inc braided

  result.grid = g
  result.start = latticeCell(rng.rand(MazeLatticeW), rng.rand(MazeLatticeH))
  let field = distField(g, progressCost(lkMaze), result.start)
  ## The exit is the lattice cell FARTHEST from the start, and the four gems
  ## are the next four farthest — so every level is a real traverse and
  ## `startDist` is never trivial.
  var ranked: seq[tuple[dist, index: int]] = @[]
  for j in 0 ..< MazeLatticeH:
    for i in 0 ..< MazeLatticeW:
      let c = latticeCell(i, j)
      if c == result.start:
        continue
      let d = field.distTo(c)
      if d >= Unreachable:
        continue
      ranked.add((d, c.cellIndex()))
  if ranked.len < 5:
    return result
  for a in 0 ..< ranked.len:
    for b in a + 1 ..< ranked.len:
      if ranked[b].dist > ranked[a].dist or
          (ranked[b].dist == ranked[a].dist and
           ranked[b].index < ranked[a].index):
        swap(ranked[a], ranked[b])
  result.exitAt = cellAt(ranked[0].index)
  result.grid.setTile(result.exitAt, tExitLocked)
  for k in 1 .. 4:
    result.grid.setTile(cellAt(ranked[k].index), tGem)

# ---------------------------------------------------------------------------
#  chaser — an open room with pillars, pellets and hunters
# ---------------------------------------------------------------------------

proc drawChaser(rng: var Rng, table: DiffTable): GeneratedLevel =
  var g = emptyGrid()
  for _ in 0 ..< table.pillarCount:
    let c = cell(rng.between(2, BoardW - 3), rng.between(2, BoardH - 3))
    g.setTile(c, tWall)
  result.grid = g
  var free: seq[Cell] = @[]
  for y in 1 .. BoardH - 2:
    for x in 1 .. BoardW - 2:
      let c = cell(x, y)
      if g.at(c) == tEmpty:
        free.add(c)
  if free.len < 20:
    return result
  result.start = free[rng.rand(free.len)]
  let field = distField(g, progressCost(lkChaser), result.start)
  var far: seq[Cell] = @[]
  var near: seq[Cell] = @[]
  for c in free:
    if c == result.start:
      continue
    let d = field.distTo(c)
    if d >= Unreachable:
      continue
    if d >= 6:
      far.add(c)
    elif d >= 2:
      near.add(c)
  if far.len < 3 + table.hunterCount:
    return result
  result.exitAt = far[rng.rand(far.len)]
  result.grid.setTile(result.exitAt, tExitLocked)
  var taken: seq[Cell] = @[result.start, result.exitAt]
  proc isTaken(list: seq[Cell], c: Cell): bool =
    for t in list:
      if t == c:
        return true
    false
  var placed = 0
  var guard = 0
  while placed < collectTotalFor(lkChaser) and guard < 400:
    inc guard
    let pool = if rng.rand(2) == 0 and near.len > 0: near else: far
    let c = pool[rng.rand(pool.len)]
    if taken.isTaken(c):
      continue
    taken.add(c)
    result.grid.setTile(c, tPellet)
    inc placed
  if placed < collectTotalFor(lkChaser):
    return result
  var hunters = 0
  guard = 0
  while hunters < table.hunterCount and guard < 400:
    inc guard
    let c = far[rng.rand(far.len)]
    if taken.isTaken(c) or result.grid.at(c) != tEmpty:
      continue
    if abs(c.x - result.start.x) <= 2 and abs(c.y - result.start.y) <= 2:
      continue
    taken.add(c)
    result.hunters.add(c)
    inc hunters

# ---------------------------------------------------------------------------
#  climber — three walkable tiers over a pit, ladders and jumpable gaps
# ---------------------------------------------------------------------------

proc drawClimber(rng: var Rng, table: DiffTable): GeneratedLevel =
  var g = emptyGrid()
  var ladderColumns: array[2, int]
  for k, band in ClimberBandRows:
    for x in 1 .. BoardW - 2:
      g.setTile(cell(x, band), tPlatform)
    let ladder = rng.between(2, BoardW - 3)
    ladderColumns[k] = ladder
    g.setTile(cell(ladder, band), tLadder)
    g.setTile(cell(ladder, band + 1), tLadder)
  ## Gaps go ONLY in the lower band: the top tier has no headroom (the wall
  ## row is directly above it), so a gap there could not be jumped.
  let lowerBand = ClimberBandRows[0]
  let gapCount = 1 + rng.rand(2)
  for _ in 0 ..< gapCount:
    let
      width = 1 + rng.rand(ClimberMaxGap)
      startX = rng.between(3, BoardW - 4 - width)
    var clear = true
    for x in startX ..< startX + width:
      if abs(x - ladderColumns[0]) <= 1:
        clear = false
    if not clear:
      continue
    for x in startX ..< startX + width:
      g.setTile(cell(x, lowerBand), tEmpty)

  result.grid = g
  proc standable(g: Grid, c: Cell): bool =
    if not c.inBounds() or g.at(c) != tEmpty:
      return false
    let below = g.at(cell(c.x, c.y + 1))
    below.solid() or below == tLadder
  var perRow: array[3, seq[Cell]]
  for k, row in ClimberWalkRows:
    for x in 1 .. BoardW - 2:
      let c = cell(x, row)
      if standable(g, c):
        perRow[k].add(c)
  if perRow[0].len < 3 or perRow[1].len < 3 or perRow[2].len < 3:
    return result
  result.start = perRow[0][rng.rand(perRow[0].len)]
  result.exitAt = perRow[2][rng.rand(perRow[2].len)]
  if result.exitAt == result.start:
    return result
  result.grid.setTile(result.exitAt, tExitLocked)
  ## Four gems over the three tiers: one on the ground, one on the top, two on
  ## the middle tier, which is the one the jump exists for.
  var gems = 0
  var guard = 0
  while gems < collectTotalFor(lkClimber) and guard < 300:
    inc guard
    let row = (if gems < 3: gems else: 1)
    let c = perRow[row][rng.rand(perRow[row].len)]
    if c == result.start or c == result.exitAt:
      continue
    if result.grid.at(c) != tEmpty:
      continue
    result.grid.setTile(c, tGem)
    inc gems
  var spikes = 0
  guard = 0
  while spikes < table.spikeCount and guard < 300:
    inc guard
    let row = rng.rand(3)
    let c = perRow[row][rng.rand(perRow[row].len)]
    if c == result.start or c == result.exitAt:
      continue
    if result.grid.at(c) != tEmpty:
      continue
    if abs(c.x - result.start.x) <= 1 and c.y == result.start.y:
      continue
    result.grid.setTile(c, tSpike)
    inc spikes

# ---------------------------------------------------------------------------
#  miner — a wall of dirt with bedrock veins, diamonds and boulders
# ---------------------------------------------------------------------------

proc drawMiner(rng: var Rng, table: DiffTable): GeneratedLevel =
  var g = emptyGrid()
  for y in 1 .. BoardH - 2:
    for x in 1 .. BoardW - 2:
      g.setTile(cell(x, y), tDirt)
  let interior = (BoardW - 2) * (BoardH - 2)
  let veins = (interior * table.bedrockPct) div 100
  for _ in 0 ..< veins:
    let c = cell(rng.between(2, BoardW - 3), rng.between(2, BoardH - 3))
    g.setTile(c, tWall)
  result.grid = g
  result.start = cell(1, 1)
  result.grid.setTile(result.start, tEmpty)
  result.exitAt = cell(BoardW - 2, BoardH - 2)
  result.grid.setTile(result.exitAt, tExitLocked)
  var gems = 0
  var guard = 0
  while gems < collectTotalFor(lkMiner) and guard < 400:
    inc guard
    let c = cell(rng.between(2, BoardW - 3), rng.between(2, BoardH - 3))
    if result.grid.at(c) != tDirt:
      continue
    result.grid.setTile(c, tGem)
    inc gems
  var boulders = 0
  guard = 0
  while boulders < table.boulderCount and guard < 400:
    inc guard
    let c = cell(rng.between(2, BoardW - 3), rng.between(2, BoardH - 4))
    if result.grid.at(c) != tDirt:
      continue
    ## A boulder needs something under it at frame 0, or the falling scan
    ## would drop it before the cog has moved.
    if not result.grid.at(cell(c.x, c.y + 1)).solid():
      continue
    result.grid.setTile(c, tBoulder)
    inc boulders

# ---------------------------------------------------------------------------
#  generateLevel
# ---------------------------------------------------------------------------

proc drawFor(kind: LevelKind, rng: var Rng, table: DiffTable): GeneratedLevel =
  case kind
  of lkMaze: drawMaze(rng, table)
  of lkChaser: drawChaser(rng, table)
  of lkClimber: drawClimber(rng, table)
  of lkMiner: drawMiner(rng, table)

proc generateLevel*(kind: LevelKind, seed: int,
                    difficulty: Difficulty): GeneratedLevel =
  ## A pure function of `(kind, seed, difficulty)`: one `levelRng` seeded from
  ## the level seed alone, a bounded redraw, and a committed fallback.
  var rng = initRng(seed)
  let table = difficultyTable(kind, difficulty)
  for _ in 0 ..< MaxRedrawAttempts:
    let candidate = drawFor(kind, rng, table)
    if candidate.validate(kind):
      return candidate
  fallbackLevel(kind)

proc newLevel*(kind: LevelKind, seed: int,
               difficulty: Difficulty): LevelState =
  ## `generateLevel` plus the level lifecycle's L2..L4: the state a level
  ## starts a turn loop in.
  let drawn = generateLevel(kind, seed, difficulty)
  result = newLevelState(kind, difficulty, seed, drawn.grid, drawn.start,
    drawn.exitAt, drawn.hunters)
  result.genFallback = drawn.fallback
