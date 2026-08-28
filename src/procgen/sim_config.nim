## Parsing the runtime `game_config` into a `GameConfig`.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_config.nim`. Every key here is a
## declared property of `coworld_manifest_template.json`'s `config_schema` —
## `tests/test_procgen_manifest.nim` block 36 reads the key list out of THIS
## file and cross-checks it, because that schema is closed and an undeclared
## key is a game_config the platform validator rejects;
## unknown keys are ignored rather than fatal, and out-of-range values are
## clamped rather than rejected, because a config that fails to parse is an
## episode that never starts.
##
## Two values are REJECTED rather than clamped, because both would silently
## change what a deadline means:
##
## * `attempt1Ms` / `retryMs` below one second or not a whole number of
##   seconds — curly hands the deadline to CURLOPT_TIMEOUT, whose granularity
##   is whole seconds (the starter's 0.1.2 scar);
## * a `levelCount` outside {4, 8} — the gauntlet plan is a paired
##   seen/unseen comparison and only those two counts produce one.

import std/[json, strutils]
import seeds, sim_types

proc getIntOr(node: JsonNode, key: string, fallback: int): int =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JInt: int(value.getBiggestInt())
  of JFloat: int(value.getFloat())
  of JString:
    try: parseInt(value.getStr().strip()) except CatchableError: fallback
  else: fallback

proc getBoolOr(node: JsonNode, key: string, fallback: bool): bool =
  let value = node{key}
  if value.isNil:
    return fallback
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  of JString: value.getStr().strip().toLowerAscii() in ["1", "true", "yes"]
  else: fallback

proc getStrOr(node: JsonNode, key, fallback: string): string =
  let value = node{key}
  if value.isNil or value.kind != JString: fallback else: value.getStr()

proc update*(config: var GameConfig, raw: string) =
  ## Applies one `game_config` document.
  if raw.strip().len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError as error:
    raise newException(ProcgenError, "game config is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(ProcgenError, "game config is not a JSON object")

  config.seed = node.getIntOr("seed", config.seed)
  config.levelCount = node.getIntOr("levelCount", config.levelCount)
  config.turnsPerLevel = clamp(
    node.getIntOr("turnsPerLevel", config.turnsPerLevel), 4, 20)
  config.framesPerTurn = clamp(
    node.getIntOr("framesPerTurn", config.framesPerTurn), 1, MaxFramesPerTurn)
  config.difficulty = normalizedDifficulty(
    node.getStrOr("difficulty", config.difficulty))
  config.interruptOnDanger = node.getBoolOr(
    "interruptOnDanger", config.interruptOnDanger)
  config.fallLethal = clamp(node.getIntOr("fallLethal", config.fallLethal), 2, 8)
  config.renderFramesPerStep = clamp(
    node.getIntOr("renderFramesPerStep", config.renderFramesPerStep), 1, 12)
  config.sayFrames = clamp(node.getIntOr("sayFrames", config.sayFrames), 0, 48)
  config.numAgents = clamp(node.getIntOr("num_agents", config.numAgents), 1, Seats)
  config.minPlayers = clamp(
    node.getIntOr("minPlayers", config.minPlayers), 1, Seats)
  config.fastMode = node.getBoolOr("fastMode", config.fastMode)
  config.showPlayerLabels = node.getBoolOr(
    "showPlayerLabels", config.showPlayerLabels)
  config.attempt1Ms = node.getIntOr("attempt1Ms", config.attempt1Ms)
  config.retryMs = node.getIntOr("retryMs", config.retryMs)
  config.turnBudgetMs = node.getIntOr("turnBudgetMs", config.turnBudgetMs)
  config.turnSpacingMs = max(0,
    node.getIntOr("turnSpacingMs", config.turnSpacingMs))
  config.wallClockBudgetSeconds = max(1, node.getIntOr(
    "wallClockBudgetSeconds", config.wallClockBudgetSeconds))
  config.lobbyJoinTimeoutSeconds = max(1, node.getIntOr(
    "lobbyJoinTimeoutSeconds", config.lobbyJoinTimeoutSeconds))
  config.gameOverFrames = max(0, node.getIntOr(
    "gameOverFrames", config.gameOverFrames))
  config.model = node.getStrOr("model", config.model)
  config.maxOutputTokens = max(1, node.getIntOr(
    "maxOutputTokens", config.maxOutputTokens))

  if not legalLevelCount(config.levelCount):
    raise newException(ProcgenError,
      "levelCount must be 4 or 8 (got " & $config.levelCount & "): the " &
      "gauntlet plan is a PAIRED seen/unseen comparison over the four " &
      "archetypes, and only those two counts produce one.")
  if config.attempt1Ms < 1000 or config.retryMs < 1000 or
      config.attempt1Ms mod 1000 != 0 or config.retryMs mod 1000 != 0:
    raise newException(ProcgenError,
      "attempt1Ms and retryMs must be a WHOLE number of seconds and at " &
      "least 1000 ms (got " & $config.attempt1Ms & " and " &
      $config.retryMs & "): curly hands the deadline to CURLOPT_TIMEOUT, " &
      "whose granularity is whole seconds, so anything else is not the " &
      "deadline it claims to be.")
  if config.turnBudgetMs < config.attempt1Ms + config.retryMs:
    ## The per-turn budget is a cap on the CALLS: attempt 1, the single retry
    ## and slack. A budget that cannot hold both attempts would pre-empt the
    ## retry the design's D3 makes unconditional, so it is repaired rather
    ## than silently under-running.
    config.turnBudgetMs = config.attempt1Ms + config.retryMs

  config.playerNames = @[]
  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    for entry in players:
      if entry.kind == JObject:
        config.playerNames.add(entry.getStrOr("name", ""))
      elif entry.kind == JString:
        config.playerNames.add(entry.getStr())
  config.tokens = @[]
  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    for entry in tokens:
      if entry.kind == JString:
        config.tokens.add(entry.getStr())
