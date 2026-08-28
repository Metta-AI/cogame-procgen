## One bounded shortest-path search over <= 135 tiles, and the one place a
## path is turned back into action symbols.
##
## Five callers: the level lifecycle's `startDist`/`bestDist` progress
## measure, the observation builder, both scripted baselines, the generator
## validators and the viewer pre-scan. ONE implementation means no consumer
## can disagree with the rules (the escrow 2026-08-23 lesson).
##
## Integer arithmetic only: no float literal, no division operator and no
## square root appears in this file (design note §Sim module -> Determinism).

import tiles

type
  TileCost* = array[Tile, int]
    ## The cost of ENTERING a cell holding this tile. `-1` is impassable.
    ## `miner`'s `digCost` is a baseline tunable and rides in here, which is
    ## why the search is a small integer Dijkstra rather than a plain BFS.

const Unreachable* = 9999

proc verticalLegal*(g: Grid, fromCell, toCell: Cell,
                    ladderOnlyVertical: bool): bool =
  ## `climber`'s one movement rule, in the search as well as in the resolver:
  ## a vertical step needs a `Ladder` under the cog or in the target.
  if not ladderOnlyVertical or fromCell.x != toCell.x:
    return true
  g.at(fromCell) == tLadder or g.at(toCell) == tLadder

proc uniformCost(cost: TileCost): bool =
  ## True when every passable tile costs exactly one, which is every table but
  ## `miner`'s routing table. The search then has a plain FIFO BFS fast path —
  ## same answers, an order of magnitude less work, and `stepFrame` runs this
  ## once per frame.
  for t in Tile.low .. Tile.high:
    if cost[t] > 1:
      return false
  true

proc distField*(g: Grid, cost: TileCost, src: Cell,
                blocked: seq[bool] = @[],
                ladderOnlyVertical = false): seq[int] =
  ## The cost of the cheapest walk from `src` to every cell, or `Unreachable`.
  ## A FIFO BFS when every step costs one; otherwise an O(cells^2) Dijkstra
  ## over 135 nodes. Same arithmetic native and in wasm either way.
  result = newSeq[int](BoardCells)
  for i in 0 ..< BoardCells:
    result[i] = Unreachable
  if not src.inBounds():
    return
  result[src.cellIndex()] = 0
  if uniformCost(cost):
    var queue = newSeqOfCap[Cell](BoardCells)
    var head = 0
    queue.add(src)
    while head < queue.len:
      let here = queue[head]
      inc head
      let base = result[here.cellIndex()]
      for d in DirOrder:
        let nextCell = here.step(d)
        if not nextCell.inBounds():
          continue
        let index = nextCell.cellIndex()
        if blocked.len == BoardCells and blocked[index]:
          continue
        if not g.verticalLegal(here, nextCell, ladderOnlyVertical):
          continue
        if cost[g.cells[index]] < 0 or result[index] <= base + 1:
          continue
        result[index] = base + 1
        queue.add(nextCell)
    return
  var done = newSeq[bool](BoardCells)
  while true:
    var
      best = -1
      bestCost = Unreachable
    for i in 0 ..< BoardCells:
      if not done[i] and result[i] < bestCost:
        best = i
        bestCost = result[i]
    if best < 0:
      break
    done[best] = true
    let here = cellAt(best)
    for d in DirOrder:
      let nextCell = here.step(d)
      if not nextCell.inBounds():
        continue
      let index = nextCell.cellIndex()
      if blocked.len == BoardCells and blocked[index]:
        continue
      if not g.verticalLegal(here, nextCell, ladderOnlyVertical):
        continue
      let stepCost = cost[g.cells[index]]
      if stepCost < 0:
        continue
      let candidate = bestCost + stepCost
      if candidate < result[index]:
        result[index] = candidate

proc distTo*(field: seq[int], target: Cell): int =
  if not target.inBounds() or field.len != BoardCells:
    return Unreachable
  field[target.cellIndex()]

proc pathFrom*(g: Grid, cost: TileCost, field: seq[int], src, dst: Cell,
               blocked: seq[bool] = @[],
               ladderOnlyVertical = false): seq[Cell] =
  ## The cells of one cheapest walk `src -> dst`, `dst` last, `src` excluded.
  ## Walks the distance field downhill with ties broken in the FIXED wire
  ## order L, R, U, D, so two callers always take the same route.
  if field.len != BoardCells or not dst.inBounds():
    return @[]
  if field[dst.cellIndex()] >= Unreachable:
    return @[]
  var
    reversed: seq[Cell] = @[]
    here = dst
    guard = 0
  while not (here == src) and guard < BoardCells * 2:
    inc guard
    reversed.add(here)
    var
      bestCell = here
      bestCost = field[here.cellIndex()]
      found = false
    for d in DirOrder:
      let prev = here.step(d)
      if not prev.inBounds():
        continue
      let index = prev.cellIndex()
      if blocked.len == BoardCells and blocked[index]:
        continue
      if not g.verticalLegal(prev, here, ladderOnlyVertical):
        continue
      let enter = cost[g.cells[here.cellIndex()]]
      if enter < 0:
        continue
      if field[index] < Unreachable and field[index] + enter == bestCost:
        bestCell = prev
        found = true
        break
    if not found:
      return @[]
    here = bestCell
  if guard >= BoardCells * 2:
    return @[]
  for i in countdown(reversed.len - 1, 0):
    result.add(reversed[i])

proc symbolsFor*(src: Cell, path: seq[Cell], limit: int): string =
  ## The action symbols that walk `path`, capped at `limit` frames. The SAME
  ## proc `applyAction` inverts, so a baseline can never propose a step the
  ## resolver reads differently.
  var here = src
  for c in path:
    if result.len >= limit:
      break
    var matched = false
    for d in DirOrder:
      if here.step(d) == c:
        result.add(d.dirSymbol())
        matched = true
        break
    if not matched:
      break
    here = c
