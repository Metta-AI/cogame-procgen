## The grid: one closed tile enum, its glyph and passability tables, the
## 15 x 9 board, and the direction/action alphabet.
##
## Integer arithmetic only: no float literal, no division operator and no
## square root appears anywhere in this file, and `tests/test_procgen_sim.nim`
## greps for all three (design note §Sim module -> Determinism).

type
  Tile* = enum
    ## Design note §The game -> The board. The ordinal IS the wire value.
    tEmpty = 0        ## `.`  passable
    tWall = 1         ## `#`  bedrock, never passable, `miner` cannot dig it
    tDirt = 2         ## `:`  only `miner`, by digging
    tBoulder = 3      ## `O`  only `miner`, by pushing
    tGem = 4          ## `*`  passable, collects
    tPellet = 5       ## `o`  passable, collects
    tExitLocked = 6   ## `+`  not passable
    tExitOpen = 7     ## `E`  passable, finishes the level
    tPlatform = 8     ## `=`  not passable, stood on, in `climber`
    tLadder = 9       ## `H`  passable, climbable with U/D
    tSpike = 10       ## `^`  passable, and lethal

  Dir* = enum
    ## The wire order of the replay's action byte: 0=L, 1=R, 2=U, 3=D, with
    ## 4 = X (the archetype special) and 5 = `.` (wait).
    dL = 0
    dR = 1
    dU = 2
    dD = 3

  Cell* = object
    x*, y*: int

  Grid* = object
    ## A whole level. Fixed 15 x 9 for every archetype and every variant, so
    ## BOARD_ASPECT is the constant 15/9 and `relayout()` never re-fits
    ## mid-replay (design note §Viewer -> Legible at 360 px).
    cells*: array[135, Tile]

const
  BoardW* = 15
  BoardH* = 9
  BoardCells* = BoardW * BoardH
  CellPx* = 32
  DirOrder* = [dL, dR, dU, dD]

  ActionL* = 0'u8
  ActionR* = 1'u8
  ActionU* = 2'u8
  ActionD* = 3'u8
  ActionX* = 4'u8
  ActionWait* = 5'u8
  ActionLevelBoundary* = 255'u8
    ## The one non-symbol byte in the action log: it closes a level and opens
    ## the next one, so the wasm viewer can walk the whole gauntlet from the
    ## bytes alone.

  ActionAlphabet* = "LRUDX."
    ## EXACTLY six symbols. Case-insensitive on the wire, uppercased on parse.

proc cell*(x, y: int): Cell = Cell(x: x, y: y)

proc `==`*(a, b: Cell): bool = a.x == b.x and a.y == b.y

proc inBounds*(c: Cell): bool =
  c.x >= 0 and c.y >= 0 and c.x < BoardW and c.y < BoardH

proc cellIndex*(c: Cell): int =
  ## Row-major. Callers must have checked `inBounds` first.
  c.y * BoardW + c.x

proc cellAt*(index: int): Cell =
  cell(index mod BoardW, index div BoardW)

proc at*(g: Grid, c: Cell): Tile =
  if not c.inBounds(): tWall else: g.cells[c.cellIndex()]

proc setTile*(g: var Grid, c: Cell, t: Tile) =
  if c.inBounds():
    g.cells[c.cellIndex()] = t

proc delta*(d: Dir): Cell =
  ## x grows RIGHT and y grows DOWN, so `U` is y minus one.
  case d
  of dL: cell(-1, 0)
  of dR: cell(1, 0)
  of dU: cell(0, -1)
  of dD: cell(0, 1)

proc step*(c: Cell, d: Dir): Cell =
  let s = d.delta()
  cell(c.x + s.x, c.y + s.y)

proc glyph*(t: Tile): char =
  ## The ASCII glyph the observation draws this tile as. ONE table, read by
  ## the observation builder, the renderer fixture and the tests.
  case t
  of tEmpty: '.'
  of tWall: '#'
  of tDirt: ':'
  of tBoulder: 'O'
  of tGem: '*'
  of tPellet: 'o'
  of tExitLocked: '+'
  of tExitOpen: 'E'
  of tPlatform: '='
  of tLadder: 'H'
  of tSpike: '^'

proc solid*(t: Tile): bool =
  ## Nothing stands in a solid cell and nothing falls through one.
  t in {tWall, tPlatform, tDirt, tBoulder, tExitLocked}

proc collectible*(t: Tile): bool = t == tGem or t == tPellet

proc dirSymbol*(d: Dir): char =
  case d
  of dL: 'L'
  of dR: 'R'
  of dU: 'U'
  of dD: 'D'

proc parseDir*(ch: char): tuple[ok: bool, dir: Dir] =
  case ch
  of 'L', 'l': (true, dL)
  of 'R', 'r': (true, dR)
  of 'U', 'u': (true, dU)
  of 'D', 'd': (true, dD)
  else: (false, dR)

proc actionByte*(ch: char): uint8 =
  ## The replay's one byte per sim frame. Anything outside the alphabet is a
  ## wait, which is what the validator repairs it to anyway.
  case ch
  of 'L': ActionL
  of 'R': ActionR
  of 'U': ActionU
  of 'D': ActionD
  of 'X': ActionX
  else: ActionWait

proc actionSymbol*(value: uint8): char =
  case value
  of ActionL: 'L'
  of ActionR: 'R'
  of ActionU: 'U'
  of ActionD: 'D'
  of ActionX: 'X'
  else: '.'

proc emptyGrid*(): Grid =
  ## Every cell `Empty`, with the outer ring `Wall` — the invariant every
  ## generator starts from and `tests/test_procgen_sim.nim` asserts.
  for index in 0 ..< BoardCells:
    let c = cellAt(index)
    result.cells[index] =
      if c.x == 0 or c.y == 0 or c.x == BoardW - 1 or c.y == BoardH - 1: tWall
      else: tEmpty

proc gridRows*(g: Grid): seq[string] =
  ## The nine 15-character rows of the observation's `map[]`, top row first.
  for y in 0 ..< BoardH:
    var row = newString(BoardW)
    for x in 0 ..< BoardW:
      row[x] = g.at(cell(x, y)).glyph()
    result.add(row)
