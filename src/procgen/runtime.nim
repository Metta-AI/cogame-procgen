## The Coworld runtime contract, in one module.
##
## `coworld-ctf` gets this from `bitworld/runtime`; this fork carries its own
## copy because the rest of bitworld (the sprite protocol, the windowed
## client, the pixel fonts) is a continuous-2-D rendering stack this grid game
## does not use. The CONTRACT is unchanged:
##
##   in   COGAME_CONFIG_URI          the episode's game_config
##   out  COGAME_RESULTS_URI         the results document
##   out  COGAME_SAVE_REPLAY_URI     the replay bytes
##   out  COGAME_PLAYER_FAILURE_URI  one closed-schema failure payload
##   out  COGAME_EVENTS_URI          the tier-2 JSON-lines analysis stream
##        COGAME_LOAD_REPLAY_URI     local developer replay mode only
##        COGAME_HOST / COGAME_PORT  (HOST / PORT also accepted)
##
## Every wait here is bounded: a URI fetch gets one bounded attempt and a
## failure is logged, never raised into the episode loop.

import std/[os, strutils, uri]
import curly

type
  RuntimeConfig* = object
    host*: string
    port*: int
    config*: string
    resultsUri*: string
    replayUri*: string
    failureUri*: string
    eventsUri*: string
    loadReplayUri*: string
    replayMode*: bool
    replay*: string

const FetchTimeoutSeconds* = 20
  ## Every artifact fetch and PUT is bounded by this and by nothing else; the
  ## pod-budget arithmetic in `server.nim` is written against it.

proc localPath(uriText: string): string =
  ## `file:///coworld/config.json` -> `/coworld/config.json`.
  let parsed = parseUri(uriText)
  if parsed.scheme == "file":
    result = parsed.path
    if result.len == 0:
      result = uriText[len("file://") .. ^1]
  else:
    result = uriText

proc readCogameUri*(uriText, label: string): string =
  ## Reads one contract URI. `file://` and a bare path are read from disk;
  ## `http(s)://` is fetched once with a bounded timeout.
  if uriText.len == 0:
    return ""
  if uriText.startsWith("http://") or uriText.startsWith("https://"):
    let curl = newCurly()
    try:
      var headers: HttpHeaders
      let response = curl.get(uriText, headers, FetchTimeoutSeconds)
      if response.code < 200 or response.code >= 300:
        raise newException(IOError,
          label & ": HTTP " & $response.code)
      return response.body
    finally:
      curl.close()
  readFile(localPath(uriText))

proc writeCogameUri*(uriText, label, body: string) =
  ## Writes one artifact. A failure is logged, never raised: an episode that
  ## finished must still exit 0.
  if uriText.len == 0:
    return
  try:
    if uriText.startsWith("http://") or uriText.startsWith("https://"):
      let curl = newCurly()
      try:
        var headers: HttpHeaders
        headers["content-type"] = "application/json"
        discard curl.put(uriText, headers, body, FetchTimeoutSeconds)
      finally:
        curl.close()
    else:
      let path = localPath(uriText)
      createDir(path.parentDir())
      writeFile(path, body)
  except CatchableError as error:
    echo "procgen: failed to write ", label, ": ", error.msg

proc readRuntimeConfig*(): RuntimeConfig =
  result.host = getEnv("COGAME_HOST", getEnv("HOST", "0.0.0.0"))
  let portText = getEnv("COGAME_PORT", getEnv("PORT", "8080")).strip()
  result.port = try: parseInt(portText) except CatchableError: 8080
  result.resultsUri = getEnv("COGAME_RESULTS_URI").strip()
  result.replayUri = getEnv("COGAME_SAVE_REPLAY_URI").strip()
  result.failureUri = getEnv("COGAME_PLAYER_FAILURE_URI").strip()
  result.eventsUri = getEnv("COGAME_EVENTS_URI").strip()
  result.loadReplayUri = getEnv("COGAME_LOAD_REPLAY_URI").strip()
  let configUri = getEnv("COGAME_CONFIG_URI").strip()
  if configUri.len > 0:
    try:
      result.config = readCogameUri(configUri, "COGAME_CONFIG_URI")
    except CatchableError as error:
      echo "procgen: failed to read COGAME_CONFIG_URI: ", error.msg
  if result.loadReplayUri.len > 0:
    try:
      result.replay = readCogameUri(result.loadReplayUri,
        "COGAME_LOAD_REPLAY_URI")
      result.replayMode = result.replay.len > 0
    except CatchableError as error:
      echo "procgen: failed to read COGAME_LOAD_REPLAY_URI: ", error.msg
