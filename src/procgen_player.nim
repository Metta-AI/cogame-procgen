## The procgen player container: a policy is just a prompt.
##
## This process is DELIBERATELY thin. It connects to its seat, sends ONE chat
## message carrying its registration, and then only receives. Every decision
## happens inside the GAME server, because that is the only container the
## platform injects the `anthropic_api_key` coworld secret into.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      pathfinder | scavenger               -> this seat is scripted
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `pathfinder`. To field your own policy, reuse this
## image and set PLAYER_PROMPT:
##
##   coworld upload-policy <procgen-image> --name my-procgen \
##     --run /bin/procgen-player --secret-env PLAYER_PROMPT="<strategy>"

import std/[json, options, os, strutils, unicode]
import whisky

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

proc registrationBlob(prompt, scripted, policy: string): string =
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
  $node

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "pathfinder"
  echo "procgen player: kind=",
    (if prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "pathfinder"),
    " label=", label

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
      socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
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
          socket.send(registrationBlob(prompt, scripted, label), BinaryMessage)
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
