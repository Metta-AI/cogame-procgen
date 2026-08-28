## The game server entrypoint: /bin/procgen.
##
## Reads the Coworld contract out of the environment, seeds the episode
## (randomly unless the config pins a seed, so the HELD-OUT half of the
## gauntlet is never pre-computable by a prompt), and runs one episode to a
## settled result.

import std/[json, os, strutils, sysrand]
import procgen/[runtime, sim, server]

const LegacyFixedSeed = 1
  ## The compiled-in default. A config carrying it -- or no seed at all --
  ## gets a fresh random seed. This matters more here than in most coworlds:
  ## `testRng` is seeded `seed xor 0x7E57`, so a pinned seed would make the
  ## unseen levels reproducible and the whole generalisation measurement
  ## worthless.

proc seedPinned(configJson: string): bool =
  if configJson.strip().len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(ProcgenError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.strip().len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let rt = readRuntimeConfig()
  var config = defaultGameConfig()
  if seedPinned(rt.config):
    config.update(rt.config)
  else:
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(rt.config))
    echo "procgen: seed not pinned; randomized"
  echo "procgen config: host=", rt.host, " port=", rt.port,
    " seed=", config.seed, " levelCount=", config.levelCount,
    " turnsPerLevel=", config.turnsPerLevel,
    " framesPerTurn=", config.framesPerTurn,
    " difficulty=", config.difficulty,
    " num_agents=", config.numAgents,
    " turnSpacingMs=", config.turnSpacingMs,
    " wallClockBudgetSeconds=", config.wallClockBudgetSeconds

  if rt.replayMode:
    runLocalReplay(rt.host, rt.port, rt.replay)
  else:
    runEpisode(rt.host, rt.port, config, rt)
  quit(0)
