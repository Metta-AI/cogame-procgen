## The published training seeds, the held-out draw, and the gauntlet plan.
##
## Design note §The game -> Seen and unseen. `TrainSeeds` is PUBLISHED — it is
## printed in `docs/TRAINING_SEEDS.md`, inlined into `game.docs.pages`, and
## anyone may generate, study, solve and hard-code those 128 levels. They earn
## nothing, because they are not scored.
##
## The held-out half is drawn per episode from `[TestSeedLow, TestSeedHigh]`
## through `testRng`, a stream seeded `seed xor 0x7E57` that the policy can
## neither observe nor influence. Every training seed is < 5000, so the two
## sets are DISJOINT BY CONSTRUCTION.

import levels, sim_state

const
  TrainSeedsPerKind* = 32
  TrainSeedBase*: array[4, int] = [1000, 2000, 3000, 4000]
    ## maze 1001..1032, chaser 2001..2032, climber 3001..3032,
    ## miner 4001..4032 — the literal ranges the docs publish.
  TestSeedLow* = 100000
  TestSeedHigh* = 2147483646
  LegalLevelCounts* = [4, 8]

type
  Split* = enum
    spSeen = "seen"
    spUnseen = "unseen"

  PlannedLevel* = object
    kind*: LevelKind
    split*: Split
    seed*: int

proc trainSeeds*(kind: LevelKind): seq[int] =
  ## The 32 published seeds of one archetype.
  for i in 1 .. TrainSeedsPerKind:
    result.add(TrainSeedBase[ord(kind)] + i)

proc allTrainSeeds*(): seq[int] =
  for kind in LevelKind.low .. LevelKind.high:
    result.add(trainSeeds(kind))

proc isTrainSeed*(seed: int): bool =
  for kind in LevelKind.low .. LevelKind.high:
    let base = TrainSeedBase[ord(kind)]
    if seed > base and seed <= base + TrainSeedsPerKind:
      return true
  false

proc drawGauntletPlan*(seed, levelCount: int): seq[PlannedLevel] =
  ## The whole gauntlet, drawn BEFORE the first turn and before any seat
  ## connects, so nothing a policy does can shift a seed or a split.
  ##
  ##   setupRng = rng(seed)             play order + which training seeds
  ##   testRng  = rng(seed xor 0x7E57)  the held-out seeds and nothing else
  ##
  ## `levelCount = 8` gives one seen and one unseen level of EACH archetype —
  ## a paired comparison on the same four generators. `levelCount = 4` gives
  ## each archetype once, with `setupRng` picking which two are seen.
  var
    setupRng = initRng(seed)
    testRng = initRng(seed xor TestStreamXor)
    plan: seq[PlannedLevel] = @[]
  if levelCount >= 8:
    for kind in LevelKind.low .. LevelKind.high:
      let seeds = trainSeeds(kind)
      plan.add(PlannedLevel(kind: kind, split: spSeen,
        seed: seeds[setupRng.rand(seeds.len)]))
      plan.add(PlannedLevel(kind: kind, split: spUnseen,
        seed: testRng.between(TestSeedLow, TestSeedHigh)))
  else:
    var order = @[0, 1, 2, 3]
    setupRng.shuffle(order)
    ## The first two archetypes of the shuffled order are the SEEN half.
    var seenOf: array[4, bool]
    seenOf[order[0]] = true
    seenOf[order[1]] = true
    for kind in LevelKind.low .. LevelKind.high:
      if seenOf[ord(kind)]:
        let seeds = trainSeeds(kind)
        plan.add(PlannedLevel(kind: kind, split: spSeen,
          seed: seeds[setupRng.rand(seeds.len)]))
      else:
        plan.add(PlannedLevel(kind: kind, split: spUnseen,
          seed: testRng.between(TestSeedLow, TestSeedHigh)))
  setupRng.shuffle(plan)          ## PLAY ORDER only; never the split
  plan

proc legalLevelCount*(levelCount: int): bool =
  levelCount == 4 or levelCount == 8
