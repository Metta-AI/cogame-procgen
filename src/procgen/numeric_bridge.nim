## Headless decision bridge over Procgen's visible seat view and plan resolver.

import std/[hashes, json]
import sim

when isMainModule:
  import std/os
  import baselines, directives

const TileSymbols = "#:O*o+E=H^.@X"

var
  episode: Episode
  decisionId: int
  variant = "gauntlet"

proc values*(view: JsonNode): JsonNode =
  result = newJArray()
  for kind in ["maze", "chaser", "climber", "miner"]:
    result.add(%(if view["level"]["kind"].getStr() == kind: 1 else: 0))
  for difficulty in ["easy", "standard", "hard"]:
    result.add(%(if view["level"]["difficulty"].getStr() == difficulty: 1 else: 0))
  for field in ["index", "of"]: result.add(view["level"][field])
  for field in ["turn", "turns_left_this_level", "frame", "frames_per_turn",
                "collected", "collect_total", "exit_distance"]:
    result.add(view[field])
  result.add(%(if view["exit_open"].getBool(): 1 else: 0))
  for coordinate in view["you"]["at"]: result.add(coordinate)
  for coordinate in view["exit_at"]: result.add(coordinate)
  for field in ["jump_fuel", "fall_depth", "dash_cooldown"]:
    result.add(view["you"][field])
  for symbol in ActionAlphabet:
    result.add(%(if view["you"]["last_dir"].getStr() == $symbol: 1 else: 0))
  for action in view["actions"]:
    result.add(%(if action["legal"].getBool(): 1 else: 0))
    result.add(%(if action["kills"].getBool(): 1 else: 0))
  for index in 0 ..< 8:
    result.add(%(if index < view["levels_done"].len:
      view["levels_done"][index]["return"].getInt() else: -1))
  for row in view["map"]:
    for tile in row.getStr():
      for symbol in TileSymbols:
        result.add(%(if tile == symbol: 1 else: 0))

proc actionHeads*(framesPerTurn: int): JsonNode =
  result = newJArray()
  for index in 0 ..< framesPerTurn:
    var choices = newJArray()
    for symbol in ActionAlphabet: choices.add(%($symbol))
    result.add(%*{"name": "step_" & $index, "choices": choices})

proc currentDecision(): JsonNode =
  let view = parseJson(episode.seatViewJson())
  var properties = newJObject()
  var required = newJArray()
  for index in 0 ..< episode.config.framesPerTurn:
    let name = "step_" & $index
    properties[name] = %*{"type": "string", "enum":
      ["L", "R", "U", "D", "X", "."]}
    required.add(%name)
  %*{"kind": "decision", "game": "procgen",
    "decision_id": decisionId, "seat": 0, "engine_seat": 0,
    "turn": episode.turnsUsed, "semantic_view": view, "inbox": [],
    "messages": [{"role": "user", "content": $view}],
    "speech_messages": [], "action_schema": {"type": "object",
      "properties": properties, "required": required},
    "typed_question": newJNull()}

proc reset(request: JsonNode): JsonNode =
  doAssert request["players"].getInt() == Seats
  var config = defaultGameConfig()
  config.seed = int(hash(request["seed"].getStr()) and hash(high(int)))
  case variant
  of "gauntlet": discard
  of "sprint":
    config.levelCount = 4
    config.turnsPerLevel = 14
  of "hardpool": config.difficulty = "hard"
  else: raise newException(ValueError, "unknown Procgen variant")
  episode = newEpisode(config)
  discard episode.beginLevel()
  decisionId = 0
  currentDecision()

proc step(request: JsonNode): JsonNode =
  if request["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(request["response"].getStr())
  var moves = ""
  for index in 0 ..< episode.config.framesPerTurn:
    let symbol = action["step_" & $index].getStr()
    doAssert symbol.len == 1 and symbol[0] in ActionAlphabet
    moves.add(symbol)
  discard episode.applyPlan(moves)
  if episode.levelDone():
    discard episode.endLevel()
    if not episode.gauntletDone(): discard episode.beginLevel()
  inc decisionId
  if episode.gauntletDone():
    episode.settle(rsComplete, erGauntletComplete)
    let score = episode.score()
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": {"0": score},
        "utilities": {"0": 2 * score - 1}}}
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

when isMainModule:
  doAssert paramCount() in 0 .. 1
  if paramCount() == 1: variant = paramStr(1)
  doAssert variant in ["gauntlet", "sprint", "hardpool"]
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request)
      of "encode": %*{"decision_id": decisionId,
        "values": values(parseJson(episode.seatViewJson())),
        "action_heads": actionHeads(episode.config.framesPerTurn)}
      of "teacher":
        let plan = scriptedPlan(episode.level, blPathfinder,
          episode.config.framesPerTurn, episode.config.fallLethal)
        var action = newJObject()
        for index in 0 ..< episode.config.framesPerTurn:
          action["step_" & $index] = %(if index < plan.moves.len:
            $plan.moves[index] else: ".")
        %*{"response": $action}
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
