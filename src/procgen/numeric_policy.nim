## Player-side adapter from a frozen numeric policy to a Procgen plan.

import std/[json, os]
import curly
import numeric_bridge
import tiles

proc chooseNumericPlan*(request: JsonNode, session: string): string =
  let view = request["observation"]
  let endpoint = getEnv("PLAYER_NUMERIC_URL")
  doAssert endpoint.len > 0
  var mask = newJArray()
  for _ in 0 ..< view["frames_per_turn"].getInt() * ActionAlphabet.len:
    mask.add(%true)
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  let key = getEnv("PLAYER_NUMERIC_KEY")
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{"session": session, "seat": request["seat"],
    "decision_id": request["turn"], "values": values(view),
    "action_mask": mask}
  let response = newCurly().post(endpoint, headers, $body,
    max(1, (request["deadline_ms"].getInt() - 1000) div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "numeric policy HTTP " & $response.code)
  let actions = parseJson(response.body)["actions"]
  if actions.len != view["frames_per_turn"].getInt():
    raise newException(ValueError, "numeric policy returned the wrong plan size")
  for action in actions:
    let index = action.getInt()
    if index notin 0 ..< ActionAlphabet.len:
      raise newException(ValueError, "numeric policy returned an illegal symbol")
    result.add(ActionAlphabet[index])
