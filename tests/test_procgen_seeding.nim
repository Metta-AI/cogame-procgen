## Seeding: the published table, the held-out draw, the disjointness and the
## gauntlet plan (design note §The game -> Seen and unseen, numbered test 16).

import procgen/[baselines, engine, levels, seeds, sim, sim_config, sim_types]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

# 16. TrainSeeds ------------------------------------------------------------
block:
  check allTrainSeeds().len == 128, "16: 128 published training seeds"
  for kind in LevelKind.low .. LevelKind.high:
    let seeds = trainSeeds(kind)
    check seeds.len == 32, "16: 32 seeds per archetype"
    for s in seeds:
      check s < 5000, "16: every training seed is below 5000"
      check isTrainSeed(s), "16: isTrainSeed recognises the published table"
  check trainSeeds(lkMaze)[0] == 1001 and trainSeeds(lkMaze)[31] == 1032,
    "16: maze publishes 1001..1032"
  check trainSeeds(lkChaser)[0] == 2001, "16: chaser publishes 2001..2032"
  check trainSeeds(lkClimber)[0] == 3001, "16: climber publishes 3001..3032"
  check trainSeeds(lkMiner)[0] == 4001, "16: miner publishes 4001..4032"
  check TestSeedLow == 100000 and TestSeedHigh == 2147483646,
    "16: the held-out range is [100000, 2147483646]"

# the plan is a pure function of the episode seed ---------------------------
block:
  for seed in [1, 42, 909, 1734029581]:
    let a = drawGauntletPlan(seed, 8)
    let b = drawGauntletPlan(seed, 8)
    check a.len == 8, "16: an eight-level plan has eight entries"
    var identical = true
    for i in 0 ..< a.len:
      if a[i].kind != b[i].kind or a[i].split != b[i].split or
          a[i].seed != b[i].seed:
        identical = false
    check identical, "16: the gauntlet plan is a pure function of the seed"
    ## levelCount 8 yields exactly one seen and one unseen level of EACH
    ## archetype -- the paired comparison the split score rests on.
    for kind in LevelKind.low .. LevelKind.high:
      var seen = 0
      var unseen = 0
      for planned in a:
        if planned.kind != kind: continue
        if planned.split == spSeen: inc seen else: inc unseen
      check seen == 1 and unseen == 1,
        "16: eight levels is one seen and one unseen of each archetype"
    ## Seen seeds come from the published table; unseen seeds come from the
    ## held-out range. DISJOINT BY CONSTRUCTION.
    for planned in a:
      if planned.split == spSeen:
        check isTrainSeed(planned.seed),
          "16: a seen level uses a PUBLISHED seed"
      else:
        check planned.seed >= TestSeedLow and planned.seed <= TestSeedHigh,
          "16: an unseen level uses a HELD-OUT seed"
        check not isTrainSeed(planned.seed),
          "16: the two seed sets are disjoint"

# levelCount 4 gives each archetype once, two of each split ------------------
block:
  for seed in [3, 77, 9001]:
    let plan = drawGauntletPlan(seed, 4)
    check plan.len == 4, "16: a four-level plan has four entries"
    var kinds: array[4, int]
    var seen = 0
    for planned in plan:
      inc kinds[ord(planned.kind)]
      if planned.split == spSeen: inc seen
    for count in kinds:
      check count == 1, "16: four levels is each archetype exactly once"
    check seen == 2, "16: four levels is two seen and two unseen"

# levelCount outside {4, 8} is REJECTED by sim_config ------------------------
block:
  check legalLevelCount(4) and legalLevelCount(8), "16: 4 and 8 are legal"
  check not legalLevelCount(6), "16: 6 is not"
  var config = defaultGameConfig()
  var raised = false
  try:
    config.update("""{"levelCount": 6}""")
  except ProcgenError:
    raised = true
  check raised, "16: sim_config REJECTS a levelCount outside {4, 8}"

# nothing a seat does can shift a seed or a split ---------------------------
block:
  ## The plan is drawn in `newEpisode`, before any seat connects. Two episodes
  ## on the same seed played by DIFFERENT baselines draw the same plan.
  var config = defaultGameConfig()
  config.seed = 5150
  config.turnSpacingMs = 0
  let a = runScriptedEpisode(config, blPathfinder)
  let b = runScriptedEpisode(config, blScavenger)
  check a.episode.plan.len == b.episode.plan.len,
    "16: both episodes drew a plan of the same length"
  for i in 0 ..< a.episode.plan.len:
    check a.episode.plan[i].kind == b.episode.plan[i].kind and
      a.episode.plan[i].seed == b.episode.plan[i].seed and
      a.episode.plan[i].split == b.episode.plan[i].split,
      "16: seat behaviour cannot shift a seed, a split or the play order"
  ## The two streams are separated: `setupRng` picks which training seeds are
  ## used and shuffles the play order, `testRng` draws the held-out seeds and
  ## nothing else.
  check TestStreamXor == 0x7E57, "16: testRng is seeded seed xor 0x7E57"

if failures > 0:
  quit("test_procgen_seeding: " & $failures & " failures", 1)
echo "test_procgen_seeding: ok"
