## The manifest's own pins (design note §Tests, numbered blocks 36-38). The
## PLATFORM's reading of the same file is asserted by `ci.yml`'s
## "Validate the manifest under the installed coworld CLI" step, which runs
## the same two functions `coworld build` calls.

import std/[json, os, strutils]
import procgen/[levels, seeds, sim, sim_types]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

const Path = "coworld_manifest_template.json"
if not fileExists(Path):
  quit("test_procgen_manifest: " & Path & " is missing", 1)
let m = parseJson(readFile(Path))

# 36. the manifest pins ------------------------------------------------------
block:
  check m.hasKey("$schema"), "36: $schema is present"
  check m{"tags"}.len >= 3, "36: at least three top-level tags"
  check m.hasKey("episode_timeout_minutes"),
    "36: episode_timeout_minutes is TOP LEVEL"
  check not m{"game"}.hasKey("episode_timeout_minutes"),
    "36: and not under game"
  check not m{"game"}.hasKey("tags"),
    "36: game.tags must NOT exist (the validator forbids it)"
  check m{"game"}{"description"}.getStr().len > 0,
    "36: game.description is present (the validator requires it)"
  check m{"game"}{"name"}.getStr() == "procgen",
    "36: game.name is the slug the secret namespace uses"
  check m{"game"}{"owner"}.getStr().len > 0, "36: game.owner is present"
  check m{"game"}{"runnable"}{"type"}.getStr() == "game",
    "36: game.runnable.type is `game`"
  check m{"game"}{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
    "secret://coworld/procgen/anthropic_api_key",
    "36: the game pod is the one the coworld secret is injected into"
  check m{"game"}{"replay_viewer"}{"bundle"}.getStr() ==
    "static-replay-viewer",
    "36: the replay viewer is the STATIC BUNDLE, never a pod"
  check not m.hasKey("version"), "36: no top-level version"
  check not m{"game"}.hasKey("display_name"), "36: no game.display_name"

  ## num_agents lives INSIDE every variant's game_config and inside the
  ## certification fixture -- never at a variant's top level.
  check m{"variants"}.len == 3, "36: three variants ship"
  for variant in m{"variants"}:
    let id = variant{"id"}.getStr()
    check not variant.hasKey("num_agents"),
      id & ": num_agents is NOT at the variant's top level"
    check variant{"game_config"}{"num_agents"}.getInt() == 1,
      id & ": num_agents is 1 inside game_config"
    check variant{"description"}.getStr().len > 0, id & ": it has a description"
    check not variant{"game_config"}.hasKey("tokens"),
      id & ": no literal tokens in a game_config"
    check not variant{"game_config"}.hasKey("slots"),
      id & ": no slots anywhere -- there is one seat and there are no teams"
    let levelCount = variant{"game_config"}{"levelCount"}.getInt()
    check legalLevelCount(levelCount), id & ": levelCount is 4 or 8"
    check levelCount * variant{"game_config"}{"turnsPerLevel"}.getInt() <= 80,
      id & ": levelCount x turnsPerLevel <= 80 decision turns"
    check variant{"game_config"}{"wallClockBudgetSeconds"}.getInt() <= 660,
      id & ": the wall-clock budget is inside the engine's own stop"
  check m{"certification"}{"game_config"}{"num_agents"}.getInt() == 1,
    "36: num_agents is 1 in the certification fixture too"
  check not m{"certification"}{"game_config"}.hasKey("tokens"),
    "36: and the fixture carries no literal tokens"

  ## Exactly ONE bundled player, and it is seated in the fixture: every
  ## declared player must occupy a certification slot (the raid 0.1.2 scar),
  ## and a one-seat fixture has exactly one slot.
  check m{"player"}.len == 1, "36: exactly one bundled player"
  check m{"player"}[0]{"id"}.getStr() == "pathfinder",
    "36: and it is pathfinder"
  check m{"certification"}{"players"}.len == 1,
    "36: the fixture seats exactly one player"
  check m{"certification"}{"players"}[0]{"player_id"}.getStr() ==
    m{"player"}[0]{"id"}.getStr(),
    "36: and that player is the declared one"
  check m{"certification"}{"game_config"}{"players"}.len == 1,
    "36: len(certification.game_config.players) == num_agents == 1"
  check m{"player"}[0]{"resources"}{"limits"}{"cpu"}.getStr() == "1",
    "36: player[].resources.limits.cpu is at least 1"

  ## Every ARRAY property in config_schema carries minItems/maxItems.
  for name, prop in m{"game"}{"config_schema"}{"properties"}:
    if prop{"type"}.getStr() == "array":
      check prop.hasKey("minItems") and prop.hasKey("maxItems"),
        "36: config_schema." & name & " needs minItems and maxItems"
  check m{"game"}{"config_schema"}{"additionalProperties"}.getBool() == false,
    "36: config_schema is closed"

  ## ...and BECAUSE it is closed, every key `sim_config.update` reads must be
  ## declared in it, or a game_config that sets that key is rejected by the
  ## platform validator before the episode starts. The key list is read out of
  ## the parser itself rather than copied here, so a new knob cannot be added
  ## on one side only (the review's F20: `model` and `maxOutputTokens` were
  ## parsed and undeclared).
  let parser = readFile("src/procgen/sim_config.nim")
  var parsed: seq[string]
  for getter in ["node.getIntOr(", "node.getStrOr(", "node.getBoolOr("]:
    var at = 0
    while true:
      let found = parser.find(getter, at)
      if found < 0:
        break
      at = found + getter.len
      var i = at
      while i < parser.len and parser[i] in {' ', '\n', '\r', '\t'}:
        inc i
      if i < parser.len and parser[i] == '"':
        var key = ""
        inc i
        while i < parser.len and parser[i] != '"':
          key.add(parser[i])
          inc i
        if key.len > 0 and key notin parsed:
          parsed.add(key)
  check parsed.len >= 20,
    "36: the config_schema cross-check really read the parser (" &
      $parsed.len & " keys)"
  for key in parsed:
    check m{"game"}{"config_schema"}{"properties"}.hasKey(key),
      "36: sim_config parses `" & key & "` but config_schema does not " &
        "declare it, and the schema is CLOSED"
  ## The two keys the runner injects are read structurally, not through the
  ## getters, so they are named here.
  for key in ["tokens", "players"]:
    check m{"game"}{"config_schema"}{"properties"}.hasKey(key),
      "36: config_schema declares " & key
  var required: seq[string]
  for entry in m{"game"}{"config_schema"}{"required"}:
    required.add(entry.getStr())
  check "tokens" in required and "players" in required,
    "36: config_schema still REQUIRES tokens (the runner injects them)"

  ## Both protocols, as objects.
  for key in ["player", "global"]:
    let node = m{"game"}{"protocols"}{key}
    check node.kind == JObject, "36: game.protocols." & key & " is an object"
    check node{"type"}.getStr() == "uri" and node{"value"}.getStr().len > 0,
      "36: with a type and a value (never a bare string)"

  ## The docs: a readme and four pages, every value non-empty text, including
  ## the PUBLISHED TRAINING SEEDS page -- a product requirement, because the
  ## seen half of the score only means something if the seeds really are
  ## public.
  check m{"game"}{"docs"}{"readme"}{"type"}.getStr() == "text",
    "36: game.docs.readme is a {type, value} object"
  check m{"game"}{"docs"}{"readme"}{"value"}.getStr().len > 200,
    "36: and it carries the README body"
  check m{"game"}{"docs"}{"pages"}.len == 4, "36: four docs pages"
  var pageIds: seq[string]
  for page in m{"game"}{"docs"}{"pages"}:
    pageIds.add(page{"id"}.getStr())
    check page{"title"}.getStr().len > 0, "36: every page has a title"
    check page{"content"}{"type"}.getStr() == "text" and
      page{"content"}{"value"}.getStr().len > 200,
      "36: every page inlines its text"
  check "training-seeds.md" in pageIds,
    "36: the published training-seed page ships"
  ## ...and it really carries the 128 seeds.
  for page in m{"game"}{"docs"}{"pages"}:
    if page{"id"}.getStr() != "training-seeds.md":
      continue
    let text = page{"content"}{"value"}.getStr()
    for kind in LevelKind.low .. LevelKind.high:
      for seed in trainSeeds(kind):
        check $seed in text,
          "36: the training-seed page publishes " & $seed

  ## The closed results schema.
  let results = m{"game"}{"results_schema"}
  check results{"additionalProperties"}.getBool() == false,
    "36: results_schema is closed"
  var reasons: seq[string]
  for entry in results{"properties"}{"reason"}{"enum"}:
    reasons.add(entry.getStr())
  check reasons == @["complete", "deadline", "fault"],
    "36: results.reason is the closed three"
  var rules: seq[string]
  for entry in results{"properties"}{"endRule"}{"enum"}:
    rules.add(entry.getStr())
  check rules == @["gauntlet_complete", "wall_clock", "sim_fault",
                   "host_error"],
    "36: results.endRule is the closed four"
  var outcomes: seq[string]
  for entry in results{"properties"}{"levelOutcome"}{"items"}{"enum"}:
    outcomes.add(entry.getStr())
  check outcomes == @["cleared", "died", "timeup", "unplayed"],
    "36: results.levelOutcome items are the closed four"

# 37. the image placeholder is the compose service name ----------------------
block:
  check m{"game"}{"runnable"}{"image"}.getStr() == "{{PROCGEN_IMAGE}}",
    "37: the image placeholder is derived from the compose service name"
  for player in m{"player"}:
    check player{"image"}.getStr() == "{{PROCGEN_IMAGE}}",
      "37: the bundled player runs the same image"
  if fileExists("compose.yaml"):
    let compose = readFile("compose.yaml")
    check "  procgen:" in compose, "37: the compose service is named procgen"
    check "image: coworld-procgen:latest" in compose,
      "37: and its image is coworld-procgen:latest"
    check "platform: linux/amd64" in compose, "37: platform: linux/amd64"
    check "network: host" in compose, "37: build.network: host"

# 38. the wall-clock arithmetic holds ----------------------------------------
block:
  for variant in m{"variants"}:
    let
      id = variant{"id"}.getStr()
      config = variant{"game_config"}
      turnBudgetMs = config{"turnBudgetMs"}.getInt()
      turnBudgetSeconds = (turnBudgetMs + 999) div 1000
      ## What bounds the episode is the BUDGET GUARD, not turns x turnBudget:
      ## the last turn that may call the LLM starts by
      ## `wallClockBudgetSeconds - 2 x turnBudgetSeconds` and takes at most one
      ## spacing plus one turn budget; every later turn is integer work. So a
      ## slow provider costs TURNS, never wall clock.
      lastLlmTurnStart = config{"wallClockBudgetSeconds"}.getInt() -
        2 * turnBudgetSeconds
      slowestTurnSeconds =
        (config{"turnSpacingMs"}.getInt() + turnBudgetMs + 999) div 1000
      settledBy = lastLlmTurnStart + slowestTurnSeconds + 50
    check settledBy <= 720,
      id & ": the budget guard settles the episode by " & $settledBy &
      " s, inside the 720 s (the 60% of episodeTimeoutSeconds this game " &
      "plays inside)"
    check config{"attempt1Ms"}.getInt() mod 1000 == 0 and
      config{"retryMs"}.getInt() mod 1000 == 0,
      id & ": the deadlines are whole seconds (CURLOPT_TIMEOUT granularity)"
    check config{"turnBudgetMs"}.getInt() >=
      config{"attempt1Ms"}.getInt() + config{"retryMs"}.getInt(),
      id & ": the turn budget covers attempt 1 AND the retry"
    ## And the shipped config really constructs.
    var built = defaultGameConfig()
    built.update($config)
    check built.levelCount == config{"levelCount"}.getInt(),
      id & ": the shipped game_config constructs a GameConfig"
    check built.numAgents == Seats, id & ": with one seat"

if failures > 0:
  quit("test_procgen_manifest: " & $failures & " failures", 1)
echo "test_procgen_manifest: ok"
