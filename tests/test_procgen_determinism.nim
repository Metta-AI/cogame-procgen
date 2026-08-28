## Determinism: re-simulate from the replay's seed, level kinds, level seeds
## and recorded action bytes ALONE, on a fresh sim, and get the same episode
## frame for frame (design note §Tests, numbered test 18).

import procgen/[baselines, engine, levels, replay_runtime, replays, sim, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

proc cfg(seed: int, levelCount = 8, difficulty = "standard"): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.levelCount = levelCount
  result.difficulty = difficulty
  result.turnSpacingMs = 0

# 18. record then re-derive --------------------------------------------------
block:
  for seed in [42, 907, 1234567]:
    let played = runScriptedEpisode(cfg(seed), blPathfinder)
    var rt = loadReplay(encodeReplay(played.replay))
    check rt.mismatchFrame < 0,
      "18: the re-derived hash chain matches at EVERY frame (seed " &
        $seed & ", first divergence " & $rt.mismatchFrame & ")"
    check rt.episode.plan.len == played.episode.plan.len,
      "18: the plan comes back off the bytes"
    for i in 0 ..< rt.episode.plan.len:
      check rt.episode.plan[i].kind == played.episode.plan[i].kind and
        rt.episode.plan[i].seed == played.episode.plan[i].seed and
        rt.episode.plan[i].split == played.episode.plan[i].split,
        "18: every level kind, seed and split re-derives"
      check rt.episode.returns[i] == played.episode.returns[i],
        "18: every level's return re-derives"
      check rt.episode.outcomes[i] == played.episode.outcomes[i],
        "18: every level's outcome re-derives"
    check rt.episode.unseenMilli() == played.episode.unseenMilli(),
      "18: the unseen mean re-derives"
    ## The final frame's whole level state is identical.
    let last = rt.snapshots[^1]
    check last.cog == played.episode.level.cog,
      "18: the final cog position re-derives"
    check last.collected == played.episode.level.collected,
      "18: the final collected count re-derives"
    var identical = true
    for index in 0 ..< BoardCells:
      if last.grid.cells[index] != played.episode.level.grid.cells[index]:
        identical = false
    check identical, "18: the final grid re-derives, tile for tile"

# the grids are RE-GENERATED, never stored -----------------------------------
block:
  let played = runScriptedEpisode(cfg(31337, 4), blScavenger)
  let bytes = encodeReplay(played.replay)
  ## One byte per sim frame plus the level boundaries, and nothing that could
  ## be a 135-tile grid: the replay is far smaller than the levels it renders.
  check bytes.len < 200000,
    "18: the replay carries inputs, not grids (" & $bytes.len & " bytes)"
  var rt = loadReplay(bytes)
  check rt.snapshots.len > 1, "18: the pre-scan re-generated the levels"
  var anyTile = false
  for index in 0 ..< BoardCells:
    if rt.snapshots[0].grid.cells[index] != tEmpty:
      anyTile = true
  check anyTile, "18: the re-generated first level is a real level"

if failures > 0:
  quit("test_procgen_determinism: " & $failures & " failures", 1)
echo "test_procgen_determinism: ok"
