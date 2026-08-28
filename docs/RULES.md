# Procgen — rules

**This is a reimplementation in the spirit of Procgen, not a port of it.** OpenAI Procgen is
a C++ engine (`gym3` / `libenv`, 64×64 RGB framebuffers) that cannot be embedded in a Nim
coworld image and cannot be compiled to this repo's wasm replay viewer. What this repo
builds is an original suite of procedurally generated minigame archetypes, written in Nim,
graded on levels nobody has ever seen. Every claim it makes about upstream Procgen lives in
`src/procgen/upstream.nim` with its citation beside it, and every divergence is listed in
§Divergences below.

One cog is dropped into eight small levels in a row. Each level is built from scratch by a
generator from a number nobody tells it. It gets ten decisions per level, and each decision
is up to six moves it commits to in advance. Half the levels come from a seed table
published in this repo, so a good prompt may have studied them; the other half were drawn
out of two billion possibilities the moment the episode started. **The score is what it does
on the ones nobody has seen.**

## The board

Every level, in every archetype, is a **15 × 9 tile grid**, `cellPx = 32`, with the outer
ring always `Wall`. Coordinates are `[x, y]`, **x growing right, y growing down**; `[0,0]`
is the top-left. `L` = x−1, `R` = x+1, `U` = y−1, `D` = y+1.

| Value | Name | ASCII | Passable? |
|---|---|---|---|
| 0 | `Empty` | `.` | yes |
| 1 | `Wall` | `#` | never (bedrock; `miner` cannot dig it) |
| 2 | `Dirt` | `:` | only in `miner`, by digging |
| 3 | `Boulder` | `O` | only in `miner`, by pushing |
| 4 | `Gem` | `*` | yes (collects) |
| 5 | `Pellet` | `o` | yes (collects) |
| 6 | `ExitLocked` | `+` | no |
| 7 | `ExitOpen` | `E` | yes (finishes the level) |
| 8 | `Platform` | `=` | no (stood on, in `climber`) |
| 9 | `Ladder` | `H` | yes (climbable with `U`/`D`) |
| 10 | `Spike` | `^` | yes, and lethal |

The cog is `@` in the observation's ASCII grid; a hunter is `X`.

## The action alphabet

**Exactly six symbols: `L R U D X .`** — left, right, up, down, the archetype's special, and
wait. Case-insensitive on the wire, uppercased on parse. `X` is the only symbol whose
meaning changes:

| Archetype | `X` means |
|---|---|
| `maze` | nothing — treated as `.` |
| `chaser` | **dash**: move two tiles in `last_dir` if both are passable, then a 4-frame cooldown |
| `climber` | **jump**: set `jumpFuel = 2`; while it lasts the cog rises one tile per frame instead of falling |
| `miner` | **dig**: convert the `Dirt` tile in `last_dir` to `Empty` without moving |

## Why a turn is a plan

Procgen runs at 15 frames per second and the agent acts on every frame. An LLM cannot. One
decision turn is **one `moves` string of up to six symbols**, executed one symbol per sim
frame, in order. 8 levels × 10 turns = **80 LLM calls** and up to **480 sim frames** per
episode.

Committing blind for six frames would be suicide in `chaser` and `miner`, so the plan is
**interruptible**. The danger interrupt fires at the end of a frame when:

* `chaser`: any hunter is within Chebyshev distance 1 of the cog;
* `miner`: a boulder marked `falling` is in the cog's column, at most 3 tiles above it, with
  only `Empty` between;
* `climber`: the cog is in free fall with `fallDepth >= 2`;
* any archetype: the cog stands adjacent to a `Spike` it was not adjacent to at plan time.

The rest of the plan is discarded, `planInterrupts` counts it, and the seat is asked again
immediately. `maze` never interrupts, so a `maze` plan always runs all six frames.

## The four archetypes

| | `maze` | `chaser` | `climber` | `miner` |
|---|---|---|---|---|
| Shape | perfect maze on the 7 × 4 odd lattice, `braidCount` dead ends knocked out | open room with 1 × 1 pillars | three walkable tiers over a pit, ladders and jumpable gaps | interior filled with `Dirt`, bedrock veins, boulders |
| Collectibles | 4 `Gem` on the lattice cells farthest from the start | 8 `Pellet` | 4 `Gem` across the tiers | 4 `Gem` behind dirt |
| Hazards | none | 2 hunters (3 on `hard`) | `Spike` tiles, lethal falls, the pit | falling boulders |
| Gravity | no | no | **yes**, on the cog | **yes**, on boulders and gems |
| `X` | wait | dash | jump | dig |
| Death causes | — | `caught` | `fell`, `spiked` | `crushed` |

**The exit is locked until every collectible on the level is taken.** Then it opens.
Reaching an open exit clears the level.

Every generator is seed-deterministic and validated: `generateLevel(kind, seed, difficulty)`
is a pure function, ends with the archetype's validator (all collectibles and the exit
reachable, the start never adjacent to a hunter spawn, `climber`'s every tier reachable from
the tier below within jump range), and redraws up to 40 times before falling back to a
committed hand-authored level.

## Seen and unseen

* **The published half.** `src/procgen/seeds.nim` holds 32 seeds per archetype, 128 in
  total, printed in [`TRAINING_SEEDS.md`](TRAINING_SEEDS.md). Anyone may study them.
* **The held-out half.** `testRng`, seeded `seed xor 0x7E57`, draws each unseen level's seed
  uniformly from `[100000, 2147483646]` — disjoint from the training seeds by construction.
  `seed` is randomised per episode, so an unseen level did not exist when the prompt was
  written.
* **The plan is drawn before the seat connects**, so nothing a policy does can shift a seed
  or a split.
* The seat is **never told** which levels are seen and which are unseen, nor any level's
  seed. The spectator is told both.

## Scoring

Per level `i`, an integer return in milli-points, `0 … 1000`:

```
collectMilli[i]  = (700 * collected[i]) div collectTotal[i]                      # 0 .. 700
approachMilli[i] = (200 * max(0, startDist[i] - bestDist[i])) div startDist[i]   # 0 .. 200
finishMilli[i]   = 100 if finished[i] else 0                                     # 0 or 100
returnMilli[i]   = collectMilli[i] + approachMilli[i] + finishMilli[i]           # 0 .. 1000
```

Then, over the gauntlet:

```
unseenMilli = mean(returnMilli[i] for i where split[i] == "unseen")
seenMilli   = mean(returnMilli[i] for i where split[i] == "seen")
gapMilli    = seenMilli - unseenMilli          # reported, NEVER scored
scores[0]   = unseenMilli / 1000.0             # 0.000 .. 1.000, higher better
win[0]      = every unseen level ended `cleared`
```

`unseenMilli` is the arithmetic mean over **all** unseen levels, including the ones the cog
died on and the ones a deadline left `unplayed`. There is no drop-worst, no best-of and no
retry. `seenMilli` is deliberately **not** scored: the moment the seen half pays, memorising
128 published levels becomes worth doing, which is the exact failure this coworld exists to
avoid.

## End conditions

`results.reason` is a closed enum — `complete | deadline | fault` — and `results.endRule` is
`gauntlet_complete | wall_clock | sim_fault | host_error`. A cog that dies on level 1 still
plays levels 2 through 8: the score is an N-level mean and a missing level is a hole, not a
zero. A budget guard switches the seat to the `pathfinder` baseline from
`elapsed + 2 × turnBudget > wallClockBudgetSeconds`, so even the worst case settles
`complete`.

## Integrity

* The unseen seeds are drawn per episode from 2.1 × 10⁹ per archetype, through a stream the
  policy cannot observe or influence. There is no fixed hidden set that can leak.
  (The reading NOT taken: "test seeds held by the server" could also mean a fixed hidden
  list. A fixed list would need a secret store, a leak policy and a rotation schedule, and
  it would be strictly weaker — a leak would be unrecoverable, whereas a fresh draw cannot
  leak.)
* The score is an N-level average, never a best-of.
* The replay records one action byte and one `gameHash` per sim frame; the wasm viewer
  **re-generates every level from its seed** and re-simulates, and `#mmwarn` fires on the
  first divergent frame. Levels are never stored as tiles.

## Divergences

From upstream Procgen (each also in `src/procgen/upstream.nim`, asserted by
`tests/test_procgen_upstream.nim`):

1. **Not a port.** No Procgen C++ code, no `gym3`, no `libenv`, no upstream asset. The
   archetypes are named after Procgen games because they are in the same spirit; the rules
   are written here.
2. **Symbolic observation, not pixels.** The fleet's policies are an LLM prompt policy and a
   scripted baseline, not a convnet.
3. **Six action symbols, not fifteen.** Diagonals are a corner-cutting rules problem that
   adds a rule and no decision, and the two spare specials are unused by every archetype
   here.
4. **A decision is a plan of up to six primitive frames**, not one frame.
5. **A fresh per-episode test seed, not a fixed held-out set.**

From this repo's own design note:

6. **`climber` has three walkable tiers, not four.** The note describes "four platform rows
   (y ∈ {7,5,3,1}) over a pit". Four tiers in nine rows leaves no HEADROOM, and without a
   tile of headroom the two-tile jump can never lift the cog off its own floor — the
   archetype's whole special would be a no-op. The shipped geometry is three walkable tiers
   at y ∈ {7, 4, 1}, each carried by a band beneath it (the bottom wall row, y=5 and y=2)
   and each with a tile of empty headroom above it, so `X` is a real move: jump, then carry
   the horizontal moves across the gap. The four gems are spread over the three tiers.
7. **The LLM deadlines are wider than the note's**, because the hosted provider is slower than
   the note assumed. The note pins `attempt1Ms 5000 / retryMs 2000 / turnBudgetMs 7500` on the
   claim that "5 s covers the hosted single-call p90 with margin"; measured on the hosted
   ladder on 2026-08-28 every Bedrock call answered `ok / 200` but at **p50 ≈ 1.9-2.0 s and
   p90 5.6-7.5 s (max 9.2 s)**, so first attempts were cut at 5 s, the retry got only 2 s —
   less than the attempt that had just timed out — and the seat fell back to `pathfinder` on
   up to 7 turns an episode. The shipped values are `attempt1Ms 10000 / retryMs 5000 /
   turnBudgetMs 16000`; `turnSpacingMs` and `wallClockBudgetSeconds` are unchanged. The 720 s
   bound is unchanged too, and is enforced by the budget guard above rather than by
   `turns × turnBudget`: the episode settles early with FEWER turns, so a slow provider costs
   turns, never wall clock.
8. **The reply is a prefill plus a completion.** Every request prefills the assistant turn with
   `{`, and `src/procgen/llm.nim` puts that character back before the reply is parsed, so what
   the seat "said" is one byte this repo wrote followed by the model's own text. Measured: once
   divergence 7's wider deadlines let long generations finish, haiku occasionally spent all 900
   output tokens on preamble and was cut off before it ever wrote a brace (hosted round 7,
   2026-08-28). `maxOutputTokens` stays **900** — the prefill removes that move instead of
   paying for it, and shortens every reply.
