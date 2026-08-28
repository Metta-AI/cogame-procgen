## The three name spaces (design note §The game -> Seat, alias, and the second
## hidden name space; numbered test 17).
##
## 1. The seat's REAL policy name never reaches an observation or a prompt.
## 2. No level SEED reaches an observation or a prompt.
## 3. Neither of the strings "seen" / "unseen" reaches an observation or a
##    prompt -- the split is a spectator fact.
##
## All three DO appear in `results`, in the replay config and in the DOM
## scorebug, which is the point of the split.

import std/[json, strutils]
import procgen/[baselines, decide, engine, llm, replays, sim]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

const RealName = "daveey-1"

proc episodeWithName(): Episode =
  var config = defaultGameConfig()
  config.seed = 8123
  config.turnSpacingMs = 0
  config.playerNames = @[RealName]
  result = newEpisode(config)
  discard result.beginLevel()

# 17. the observation --------------------------------------------------------
block:
  var episode = episodeWithName()
  for turn in 0 ..< 6:
    let view = episode.seatViewJson()
    check RealName notin view,
      "17: the seat's real policy name never reaches the observation"
    check "seen" notin view,
      "17: neither `seen` nor `unseen` reaches the observation"
    check "COG-alpha" in view or "\"alive\"" in view,
      "17: the observation is the one the seat reads"
    for planned in episode.plan:
      check $planned.seed notin view,
        "17: no level seed reaches the observation (" & $planned.seed & ")"
    ## The prompt is the system prompt plus the operator block plus the view;
    ## none of the three may carry any of it.
    let prompt = userMessage("take the nearest gem first", view)
    check RealName notin prompt, "17: the real name never reaches the prompt"
    check "unseen" notin prompt, "17: the split never reaches the prompt"
    let plan = scriptedFor(DecisionEngine(), episode)
    discard episode.applyPlan(if plan.moves.len > 0: plan.moves else: ".")
    if episode.levelDone():
      discard episode.endLevel()
      if episode.gauntletDone():
        break
      discard episode.beginLevel()

# the system prompt itself carries neither -----------------------------------
block:
  check RealName notin SystemPrompt, "17: the system prompt has no real name"
  check "unseen" notin SystemPrompt,
    "17: the system prompt never says which half is which"
  check "you are not told which four" in SystemPrompt,
    "17: the system prompt DOES tell the seat that it cannot tell them apart"

# ...and the spectator side carries all three --------------------------------
block:
  var config = defaultGameConfig()
  config.seed = 8123
  config.turnSpacingMs = 0
  config.playerNames = @[RealName]
  let played = runScriptedEpisode(config, blPathfinder)
  let results = played.episode.procgenResultsJson()
  check RealName in results, "17: results.names carries the REAL policy name"
  check "\"unseen\"" in results, "17: results.levelSplit carries the split"
  check $played.episode.plan[0].seed in results,
    "17: results.levelSeeds carries every seed"
  let configJson = replayConfigJson(played.episode)
  check RealName in configJson,
    "17: the replay's config carries the real name (spectator side)"
  check "levelSeeds" in configJson and "levelSplit" in configJson,
    "17: the replay's config carries the seeds and the splits"
  ## The `register` record is REDACTED: the label and the kind, never the
  ## prompt.
  var promptSeen = false
  for record in played.replay.chats:
    if "\"k\":\"register\"" in record and "PLAYER_PROMPT" in record:
      promptSeen = true
  check not promptSeen, "17: the register record never carries the prompt"

# the directive record's `view` is the observation, so it is clean too -------
block:
  var config = defaultGameConfig()
  config.seed = 3141
  config.turnSpacingMs = 0
  config.playerNames = @[RealName]
  let played = runScriptedEpisode(config, blPathfinder)
  for record in played.replay.chats:
    if "\"k\":\"directive\"" notin record:
      continue
    let node = parseJson(record)
    check node{"alias"}.getStr() == "COG-alpha",
      "17: a directive record names the ALIAS, never the policy"
    check RealName notin record,
      "17: a directive record never carries the real name"
    ## The clause the note names: the record's `view` is the observation, so
    ## it is checked as its own field and not only as a substring of the
    ## record.
    check node.hasKey("view"),
      "17: a directive record carries the observation it answered"
    let view = node{"view"}.getStr()
    check RealName notin view, "17: no real player name in directive.view"
    check "seen" notin view, "17: and no split in directive.view"
    for planned in played.episode.plan:
      check $planned.seed notin view,
        "17: and no level seed (" & $planned.seed & ")"

if failures > 0:
  quit("test_procgen_identity_privacy: " & $failures & " failures", 1)
echo "test_procgen_identity_privacy: ok"
