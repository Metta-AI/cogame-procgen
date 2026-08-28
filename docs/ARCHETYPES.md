# The four archetypes

One 15 × 9 integer tile sim, one action alphabet, one scoring formula, one renderer. Each
archetype contributes exactly **one generator and one physics hook** — that is the whole
budget, and it is why there are four and not sixteen.

They are the four *decision* shapes the Procgen suite is built out of: search a topology,
evade a pursuer, commit to a jump you cannot take back, and reshape the terrain you are
standing in.

## `maze` — search a topology

A perfect maze carved by an iterative backtracker on the interior's **7 × 4 odd lattice**
(lattice cell `(i, j)` is tile `(1 + 2i, 1 + 2j)`), with `braidCount` dead ends knocked out
to make loops. Four gems sit on the lattice cells farthest from the start and the locked
exit on the farthest of all, so every level is a real traverse.

* Physics hook: **none**. No gravity, no hazards, nothing that moves but the cog.
* `X` is a wait. A `maze` plan therefore always runs all six frames — the danger interrupt
  can never fire.
* `braidCount`: easy 8, standard 4, hard 1. Fewer braids means fewer shortcuts and longer
  routes.

## `chaser` — evade a pursuer

An open room with `pillarCount` scattered 1 × 1 pillars, eight pellets, a locked exit and
`hunterCount` hunters.

* Physics hook: each hunter takes **one step along a shortest path to the cog**, ties broken
  in the fixed order `L, R, U, D` — **except** on frames where `frame mod 3 == 0`, where
  hunters do not move. The cog is therefore strictly faster: three cog steps per two hunter
  steps.
* `X` is a **dash**: two tiles in `last_dir` when both are passable, then a four-frame
  cooldown during which `X` is a wait.
* A hunter sharing the cog's cell kills it, cause `caught`.
* `pillarCount` / `hunterCount`: easy 6/1, standard 10/2, hard 14/3.

## `climber` — commit to a jump

Three walkable tiers at `y ∈ {7, 4, 1}`, each carried by a band of `Platform` beneath it
(the bottom wall row, `y = 5` and `y = 2`) and each with a tile of empty headroom above it.
Ladders join the tiers; the lower band carries one or two gaps of at most two tiles, which
are both the pit and the reason the jump exists.

* Physics hook: **gravity on the cog**. With `jumpFuel > 0` the cog rises one tile per frame
  if the cell above is not solid; otherwise, unsupported, it falls one tile per frame and
  `fallDepth` grows. Landing resets `fallDepth`; `fallDepth > fallLethal` (4) kills, cause
  `fell`.
* `X` is a **jump**: `jumpFuel = 2`. Horizontal moves are legal in mid-air, which is what
  carries the cog across a gap — face the way you are going, `X`, then the horizontal moves.
* `U` / `D` move only on a `Ladder` (the cog is on one, or the target is one).
* A `Spike` kills, cause `spiked`. `spikeCount`: easy 1, standard 3, hard 5.

## `miner` — reshape the terrain

The interior filled with `Dirt`, `bedrockPct` of it replaced by bedrock veins, four gems
buried in it, `boulderCount` boulders resting on something, and the locked exit in the far
corner.

* Physics hook: the **falling scan**, in the fixed order bottom row to top row, left to
  right — any `Boulder` or `Gem` with `Empty` directly below it moves down one tile and is
  marked `falling`; a marked entity that can no longer fall is unmarked. One tile per entity
  per frame.
* `X` **digs** the `Dirt` tile in `last_dir` without moving. A `Dirt` target is dug and
  entered in the same frame by a plain direction; a `Boulder` target is **pushed** one tile
  when the move is horizontal and the cell beyond is `Empty`, otherwise the move is blocked.
* A **falling** boulder entering the cog's cell kills it, cause `crushed`. A boulder resting
  on the cog does not.
* `boulderCount` / `bedrockPct`: easy 3/6 %, standard 6/10 %, hard 9/14 %.

## What is deferred, and why

Twelve of Procgen's sixteen games are out of scope for v1, and each needs an engine this
repo does not have: `starpilot` and `plunder` are scrolling shooters with projectiles and
continuous motion; `bigfish` is a size-ordered ecology; `bossfight` is a boss state machine
with phases; `caveflyer` and `fruitbot` need continuous flight; `heist` needs a key/lock
graph on top of the maze. Four archetypes on one tile sim is what v1 can build and prove;
adding a fifth engine is a second design note, not a switch.
