## The procgen player container: scripted, prompt, or external policy.
##
## Prompt decisions run inside the game. External policies receive the seat
## view and return a plan over the ordinary player socket.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      pathfinder | scavenger               -> this seat is scripted
##   PLAYER_NUMERIC_URL   a frozen Fabric action endpoint
##   PLAYER_JEV           1 to choose through System One
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `pathfinder`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy <procgen-image> --name my-procgen \
##     --run /bin/procgen-player --secret-env PLAYER_PROMPT="<strategy>"

import std/[json, monotimes, options, os, random, strutils, times, unicode]
import whisky
import procgen/numeric_policy
import procgen/jev_policy

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24
  ReconnectAttempts = 6
  MaxPromptRunes = 4000

proc truncateRunes(text: string, limit: int): string =
  if limit <= 0: return ""
  if text.runeLen <= limit: return text
  text.runeSubStr(0, limit)

proc registrationBlob(prompt, scripted, policy: string,
                      external: bool): string =
  ## The one registration message. `scripted` is JSON null when the seat is an
  ## LLM seat, so the server can tell "no baseline named" from "pathfinder named
  ## explicitly".
  var node = %*{
    "type": "register",
    "prompt": prompt.truncateRunes(MaxPromptRunes),
    "policy": policy
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  if external:
    node["mode"] = %"external"
  $node

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    numeric = getEnv("PLAYER_NUMERIC_URL").strip().len > 0
    jev = getEnv("PLAYER_JEV") == "1"
    external = numeric or jev
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif numeric: "numeric"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "pathfinder"
  echo "procgen player: kind=",
    (if external: "external" elif prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "pathfinder"),
    " label=", label
  if external and (prompt.len > 0 or scripted.len > 0) or numeric and jev:
    quit("Choose exactly one player policy mode", 1)
  randomize()
  let session = "procgen:" & $getCurrentProcessId() & ":" &
    $getTime().toUnix() & ":" & $rand(high(int))
  var lastJevStart: MonoTime
  var jevStarted = false

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The episode runner starts the players at the same
    ## instant as the game, so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "procgen player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("procgen player: game never accepted a connection", 1)
  echo "procgen player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame
  # or a truncated read (only a timeout returns none), and the game's own
  # quit(0) can outrun the flushed final frame. A naive player exits 1 on that
  # race and fails certification intermittently (the raid 0.1.3 scar). Exiting
  # 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE: a seat whose slot is not the next
  # open one may register before it has an index (the paintball round-3 scar).
  var reconnects = 0
  var done = false
  while not done:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label, external), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if "\"final\"" in received.get.data:
          done = true
          break
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label, external), BinaryMessage)
        if external and received.get().kind == TextMessage:
          let request = parseJson(received.get().data)
          if request{"type"}.getStr() == "decision":
            if jev:
              if jevStarted:
                let since = (getMonoTime() - lastJevStart).inMilliseconds.int
                if since < 2500: sleep(2500 - since)
              lastJevStart = getMonoTime()
              jevStarted = true
            let moves = if jev: chooseJevPlan(request)
              else: chooseNumericPlan(request, session)
            socket.send($( %*{"type": "plan", "turn": request["turn"],
              "moves": moves}), TextMessage)
    except CatchableError as error:
      echo "procgen player: socket closed (", error.msg, ")"
    if done:
      break
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "procgen player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "procgen player: game is no longer listening, exiting cleanly"
      break
    echo "procgen player: reconnected, re-registering"
  quit(0)
